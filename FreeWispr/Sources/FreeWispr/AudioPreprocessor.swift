import Foundation

/// Result of a speech/noise analysis pass over 16 kHz mono samples.
struct AudioAnalysis {
    let speechRMSdB: Float        // RMS of speech frames, dBFS
    let noiseFloordB: Float       // 10th-percentile frame energy, dBFS
    let clippedFraction: Double   // fraction of RAW input samples with |x| >= 0.99
    let speechRange: Range<Int>?  // first to last speech frame, in samples (nil = no speech)
    var hasSpeech: Bool { speechRange != nil }
}

/// Pure-DSP cleanup applied before transcription. Judges loudness from speech
/// frames rather than the peak, because a plosive or hotkey click can set the peak.
enum AudioPreprocessor {
    static let sampleRate = 16000
    private static let frameSize = 320            // 20 ms
    private static let speechMarginDB: Float = 10 // above the noise floor
    private static let absoluteFloorDB: Float = -65   // only guards digital silence; the relative margin does the real work
    private static let minRunFrames = 3           // drops isolated clicks/pops (< 60 ms)
    private static let minSpeechFrames = 5        // >= 100 ms of speech overall
    private static let limiterKnee: Float = 0.9
    private static let limiterCeiling: Float = 0.98   // strictly below full scale

    /// Stateful 4th-order Butterworth high-pass (two cascaded biquads). Also removes DC and rumble.
    /// A single 2nd-order section at 80 Hz only attenuates 50 Hz mains hum by ~9 dB; the cascade
    /// at 90 Hz gets past 20 dB while leaving speech (>150 Hz) untouched. State carries across
    /// calls, so it can be fed streaming chunks.
    struct HighPassFilter {
        private struct Biquad {
            var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
            var z1: Float = 0, z2: Float = 0

            init(cutoffHz: Float, sampleRate: Float, q: Float) {
                let w0 = 2 * Float.pi * cutoffHz / sampleRate
                let alpha = sin(w0) / (2 * q)
                let a0 = 1 + alpha, c = cos(w0)
                b0 = (1 + c) / 2 / a0
                b1 = -(1 + c) / a0
                b2 = b0
                a1 = -2 * c / a0
                a2 = (1 - alpha) / a0
            }

            mutating func process(_ x: Float) -> Float {   // transposed direct form II
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                return y
            }
        }

        private var sections: [Biquad]

        init(cutoffHz: Float = 90, sampleRate: Float = 16000) {
            // Butterworth 4th-order section Qs: 1 / (2 cos(k*pi/8)) for k = 1, 3
            sections = [0.54119610, 1.3065630].map { Biquad(cutoffHz: cutoffHz, sampleRate: sampleRate, q: $0) }
        }

        mutating func process(_ chunk: [Float]) -> [Float] {
            var out = chunk
            for i in 0..<out.count {
                var y = out[i]
                for s in 0..<sections.count { y = sections[s].process(y) }
                out[i] = y
            }
            return out
        }
    }

    static func analyze(_ samples: [Float]) -> AudioAnalysis {
        let clipped = clippedFraction(samples)
        let frameCount = samples.count / frameSize
        guard frameCount > 0 else {
            return AudioAnalysis(speechRMSdB: -120, noiseFloordB: -120, clippedFraction: clipped, speechRange: nil)
        }

        var meanSquares = [Float](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            var sum: Float = 0
            for i in (f * frameSize)..<((f + 1) * frameSize) { sum += samples[i] * samples[i] }
            meanSquares[f] = sum / Float(frameSize)
        }
        let dB = meanSquares.map { 10 * log10($0 + 1e-10) }
        let noise = dB.sorted()[frameCount / 10]
        let threshold = max(noise + speechMarginDB, absoluteFloorDB)

        // Keep only runs of loud frames long enough to be speech.
        var isSpeech = [Bool](repeating: false, count: frameCount)
        var runStart = 0
        for f in 0...frameCount {
            if f < frameCount, dB[f] > threshold { continue }
            if f - runStart >= minRunFrames { for k in runStart..<f { isSpeech[k] = true } }
            runStart = f + 1
        }
        let speech = (0..<frameCount).filter { isSpeech[$0] }
        guard speech.count >= minSpeechFrames, let first = speech.first, let last = speech.last else {
            return AudioAnalysis(speechRMSdB: -120, noiseFloordB: noise, clippedFraction: clipped, speechRange: nil)
        }
        let meanSq = speech.reduce(Float(0)) { $0 + meanSquares[$1] } / Float(speech.count)
        return AudioAnalysis(speechRMSdB: 10 * log10(meanSq + 1e-10), noiseFloordB: noise, clippedFraction: clipped,
                             speechRange: (first * frameSize)..<((last + 1) * frameSize))
    }

    static func trimSilence(_ samples: [Float], analysis: AudioAnalysis, padding: TimeInterval = 0.15) -> [Float] {
        guard let range = analysis.speechRange else { return samples }
        let pad = Int(padding * Double(sampleRate))
        let start = max(0, range.lowerBound - pad)
        let end = min(samples.count, range.upperBound + pad)
        return start < end ? Array(samples[start..<end]) : samples
    }

    /// Scales so speech RMS hits the target, then soft-limits above the knee so output stays below 1.0.
    static func normalizeLoudness(_ samples: [Float], analysis: AudioAnalysis,
                                  targetRMSdB: Float = -20, maxGainDB: Float = 30) -> [Float] {
        guard analysis.hasSpeech else { return samples }
        let gainDB = min(max(targetRMSdB - analysis.speechRMSdB, -maxGainDB), maxGainDB)
        let gain = pow(10, gainDB / 20)
        let knee = limiterKnee, headroom = limiterCeiling - knee
        return samples.map { x in
            let y = x * gain
            let a = abs(y)
            guard a > knee else { return y }
            return (y < 0 ? -1 : 1) * (knee + headroom * tanh((a - knee) / headroom))
        }
    }

    /// HPF -> analyze -> (optional trim) -> normalize. Clipping is measured on the raw input,
    /// since filtering and gain change what "clipped" means. With no speech, returns the filtered audio unchanged.
    /// Trimming is off by default: on the 50-clip benchmark it raised SpeechTranscriber WER (7.2% -> 9.4%),
    /// presumably because it cuts soft onsets/tails and the recognizer likes surrounding silence.
    static func prepareForBatch(_ samples: [Float], trim: Bool = false) -> (samples: [Float], analysis: AudioAnalysis) {
        var hpf = HighPassFilter()
        let filtered = hpf.process(samples)
        let a = analyze(filtered)
        let analysis = AudioAnalysis(speechRMSdB: a.speechRMSdB, noiseFloordB: a.noiseFloordB,
                                     clippedFraction: clippedFraction(samples), speechRange: a.speechRange)
        guard analysis.hasSpeech else { return (filtered, analysis) }
        let body = trim ? trimSilence(filtered, analysis: analysis) : filtered
        return (normalizeLoudness(body, analysis: analysis), analysis)
    }

    private static func clippedFraction(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.lazy.filter { abs($0) >= 0.99 }.count) / Double(samples.count)
    }
}
