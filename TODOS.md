# TODOs

## P2: Test Audio Corpus for WER Measurement
**What:** Collect 10-20 real dictation samples (various accents, mic types, ambient noise levels) to measure Word Error Rate before/after changes.
**Why:** The v1.3 design doc targets "5%+ WER reduction from audio preprocessing alone" but there's no baseline measurement to validate against. Without a corpus, quality improvements are qualitative guesses.
**Context:** Audio preprocessing (normalization, VAD-based silence trimming) is shipping in v1.3. The os_signpost instrumentation provides latency measurement, but transcription accuracy has no equivalent measurement tool. Samples should cover: quiet room + built-in mic, noisy room + external mic, Bluetooth headset, and mixed sentence lengths (5s to 30s).
**Effort:** M (human: ~2 days for recording + labeling / CC: N/A — requires physical hardware and real speech)
**Priority:** P2 — post-v1.3, pre-v1.4
**Depends on:** v1.3 audio preprocessing must ship first to have a meaningful "after" measurement.
