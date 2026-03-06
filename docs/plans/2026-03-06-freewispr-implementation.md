# FreeWispr Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS menu bar app that replaces Apple Dictation with local whisper.cpp-powered speech-to-text.

**Architecture:** SwiftUI menu bar app embedding whisper.cpp via the SwiftWhisper SPM wrapper. Global hotkey triggers audio recording, silence detection stops it, whisper.cpp transcribes the audio, and the result is injected into the focused app via Accessibility APIs.

**Tech Stack:** Swift, SwiftUI, SwiftWhisper (whisper.cpp SPM wrapper), AVAudioEngine, CGEvent, AXUIElement

---

### Task 1: Create Xcode Project and Add Dependencies

**Files:**
- Create: Xcode project `FreeWispr` (macOS App, SwiftUI lifecycle)
- Modify: `FreeWispr.xcodeproj` or `Package.swift`
- Create: `FreeWispr/Info.plist`

**Step 1: Create the Xcode project**

Create a new macOS app project via command line using Swift Package Manager structure:

```bash
mkdir -p FreeWispr/Sources/FreeWispr
mkdir -p FreeWispr/Tests/FreeWisprTests
```

Create `FreeWispr/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeWispr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "FreeWispr",
            dependencies: ["SwiftWhisper"],
            path: "Sources/FreeWispr"
        ),
        .testTarget(
            name: "FreeWisprTests",
            dependencies: ["FreeWispr"],
            path: "Tests/FreeWisprTests"
        ),
    ]
)
```

**Step 2: Create minimal app entry point**

Create `FreeWispr/Sources/FreeWispr/FreeWisprApp.swift`:

```swift
import SwiftUI

@main
struct FreeWisprApp: App {
    var body: some Scene {
        MenuBarExtra("FreeWispr", systemImage: "mic") {
            Text("FreeWispr is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

**Step 3: Create Info.plist**

Create `FreeWispr/Sources/FreeWispr/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>FreeWispr needs microphone access to transcribe your speech.</string>
</dict>
</plist>
```

**Step 4: Verify it builds and resolves dependencies**

```bash
cd FreeWispr && swift build
```

Expected: Build succeeds, SwiftWhisper dependency resolves.

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: scaffold FreeWispr project with SwiftWhisper dependency"
```

---

### Task 2: Implement ModelManager (Download and Manage Whisper Models)

**Files:**
- Create: `Sources/FreeWispr/ModelManager.swift`
- Test: `Tests/FreeWisprTests/ModelManagerTests.swift`

**Step 1: Write the failing test**

Create `Tests/FreeWisprTests/ModelManagerTests.swift`:

```swift
import XCTest
@testable import FreeWispr

final class ModelManagerTests: XCTestCase {

    func testModelURLGeneration() {
        let manager = ModelManager()
        let url = manager.downloadURL(for: .base)
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        )
    }

    func testModelLocalPath() {
        let manager = ModelManager()
        let path = manager.localModelPath(for: .base)
        XCTAssertTrue(path.path.contains("FreeWispr"))
        XCTAssertTrue(path.path.hasSuffix("ggml-base.bin"))
    }

    func testAllModelSizes() {
        let manager = ModelManager()
        for size in ModelSize.allCases {
            let url = manager.downloadURL(for: size)
            XCTAssertTrue(url.absoluteString.contains("ggml-\(size.rawValue).bin"))
        }
    }
}
```

**Step 2: Run test to verify it fails**

```bash
cd FreeWispr && swift test --filter ModelManagerTests
```

Expected: FAIL — `ModelManager` and `ModelSize` not defined.

**Step 3: Implement ModelManager**

Create `Sources/FreeWispr/ModelManager.swift`:

```swift
import Foundation

enum ModelSize: String, CaseIterable, Identifiable {
    case tiny, base, small, medium

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~142 MB"
        case .small: return "~466 MB"
        case .medium: return "~1.5 GB"
        }
    }
}

@MainActor
class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var currentModel: ModelSize = .base

    private let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FreeWispr/models")
    }

    func downloadURL(for model: ModelSize) -> URL {
        URL(string: "\(baseURL)/ggml-\(model.rawValue).bin")!
    }

    func localModelPath(for model: ModelSize) -> URL {
        modelsDirectory.appendingPathComponent("ggml-\(model.rawValue).bin")
    }

    func isModelDownloaded(_ model: ModelSize) -> Bool {
        FileManager.default.fileExists(atPath: localModelPath(for: model).path)
    }

    func downloadModel(_ model: ModelSize) async throws {
        let destination = localModelPath(for: model)

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        // Skip if already downloaded
        if isModelDownloaded(model) { return }

        isDownloading = true
        downloadProgress = 0

        defer { isDownloading = false }

        let url = downloadURL(for: model)
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        let totalBytes = response.expectedContentLength
        var data = Data()
        if totalBytes > 0 {
            data.reserveCapacity(Int(totalBytes))
        }

        var bytesReceived: Int64 = 0
        for try await byte in asyncBytes {
            data.append(byte)
            bytesReceived += 1
            if totalBytes > 0 && bytesReceived % 1_000_000 == 0 {
                downloadProgress = Double(bytesReceived) / Double(totalBytes)
            }
        }

        try data.write(to: destination)
        downloadProgress = 1.0
    }

    func deleteModel(_ model: ModelSize) throws {
        let path = localModelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd FreeWispr && swift test --filter ModelManagerTests
```

Expected: All 3 tests PASS.

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add ModelManager for downloading and managing whisper models"
```

---

### Task 3: Implement WhisperTranscriber

**Files:**
- Create: `Sources/FreeWispr/WhisperTranscriber.swift`
- Test: `Tests/FreeWisprTests/WhisperTranscriberTests.swift`

**Step 1: Write the failing test**

Create `Tests/FreeWisprTests/WhisperTranscriberTests.swift`:

```swift
import XCTest
@testable import FreeWispr

final class WhisperTranscriberTests: XCTestCase {

    func testTranscriberInitialState() {
        let transcriber = WhisperTranscriber()
        XCTAssertFalse(transcriber.isModelLoaded)
        XCTAssertFalse(transcriber.isTranscribing)
    }

    func testTranscribeSilence() async throws {
        // Create 1 second of silence at 16kHz
        let silence = [Float](repeating: 0.0, count: 16000)
        let transcriber = WhisperTranscriber()

        // Without a model loaded, should throw
        do {
            _ = try await transcriber.transcribe(audioSamples: silence)
            XCTFail("Should have thrown — no model loaded")
        } catch {
            // Expected
        }
    }
}
```

**Step 2: Run test to verify it fails**

```bash
cd FreeWispr && swift test --filter WhisperTranscriberTests
```

Expected: FAIL — `WhisperTranscriber` not defined.

**Step 3: Implement WhisperTranscriber**

Create `Sources/FreeWispr/WhisperTranscriber.swift`:

```swift
import Foundation
import SwiftWhisper

enum TranscriberError: Error {
    case modelNotLoaded
    case transcriptionFailed(String)
}

class WhisperTranscriber: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isTranscribing = false

    private var whisper: Whisper?

    func loadModel(at path: URL) throws {
        whisper = Whisper(fromFileURL: path)
        isModelLoaded = true
    }

    func unloadModel() {
        whisper = nil
        isModelLoaded = false
    }

    func transcribe(audioSamples: [Float], language: String? = nil) async throws -> String {
        guard let whisper = whisper else {
            throw TranscriberError.modelNotLoaded
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let segments = try await whisper.transcribe(audioFrames: audioSamples)
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd FreeWispr && swift test --filter WhisperTranscriberTests
```

Expected: Both tests PASS.

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add WhisperTranscriber wrapping SwiftWhisper"
```

---

### Task 4: Implement AudioRecorder with Silence Detection

**Files:**
- Create: `Sources/FreeWispr/AudioRecorder.swift`
- Test: Manual verification (AVAudioEngine requires hardware microphone)

**Step 1: Implement AudioRecorder**

Create `Sources/FreeWispr/AudioRecorder.swift`:

```swift
import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0

    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []

    var silenceThreshold: Float = 0.01
    var silenceTimeout: TimeInterval = 1.5
    private var lastSpeechTime = Date()

    var onRecordingComplete: (([Float]) -> Void)?

    private lazy var whisperFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    func startRecording() throws {
        audioBuffer.removeAll()
        isRecording = true
        lastSpeechTime = Date()

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: whisperFormat) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot create audio format converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (16000.0 / hardwareFormat.sampleRate)
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.whisperFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, let channelData = converted.floatChannelData else { return }

            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))
            let rms = Self.calculateRMS(samples)

            DispatchQueue.main.async {
                self.audioBuffer.append(contentsOf: samples)
                self.audioLevel = rms

                if rms > self.silenceThreshold {
                    self.lastSpeechTime = Date()
                } else if Date().timeIntervalSince(self.lastSpeechTime) > self.silenceTimeout {
                    self.stopRecording()
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let finalBuffer = audioBuffer
        audioBuffer.removeAll()
        onRecordingComplete?(finalBuffer)
    }

    static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }
}
```

**Step 2: Add a unit test for RMS calculation**

Create `Tests/FreeWisprTests/AudioRecorderTests.swift`:

```swift
import XCTest
@testable import FreeWispr

final class AudioRecorderTests: XCTestCase {

    func testRMSSilence() {
        let silence = [Float](repeating: 0.0, count: 100)
        XCTAssertEqual(AudioRecorder.calculateRMS(silence), 0.0)
    }

    func testRMSNonZero() {
        let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
        let rms = AudioRecorder.calculateRMS(samples)
        XCTAssertEqual(rms, 1.0, accuracy: 0.001)
    }

    func testRMSEmpty() {
        XCTAssertEqual(AudioRecorder.calculateRMS([]), 0.0)
    }
}
```

**Step 3: Run tests**

```bash
cd FreeWispr && swift test --filter AudioRecorderTests
```

Expected: All 3 tests PASS.

**Step 4: Commit**

```bash
git add -A && git commit -m "feat: add AudioRecorder with silence detection and 16kHz conversion"
```

---

### Task 5: Implement HotkeyManager

**Files:**
- Create: `Sources/FreeWispr/HotkeyManager.swift`
- Test: Manual verification (CGEvent taps require Accessibility permission)

**Step 1: Implement HotkeyManager**

Create `Sources/FreeWispr/HotkeyManager.swift`:

```swift
import Cocoa
import CoreGraphics
import ApplicationServices

class HotkeyManager: ObservableObject {
    @Published var isListening = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var hotkeyKeyCode: CGKeyCode = 49  // Space
    var hotkeyModifiers: CGEventFlags = .maskAlternate  // Option

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isListening = false
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    if keyCode == manager.hotkeyKeyCode && flags.contains(manager.hotkeyModifiers) {
        if type == .keyDown {
            DispatchQueue.main.async { manager.onHotkeyDown?() }
            return nil
        } else if type == .keyUp {
            DispatchQueue.main.async { manager.onHotkeyUp?() }
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}
```

**Step 2: Commit**

```bash
git add -A && git commit -m "feat: add HotkeyManager with global CGEvent tap"
```

---

### Task 6: Implement TextInjector

**Files:**
- Create: `Sources/FreeWispr/TextInjector.swift`
- Test: Manual verification (Accessibility APIs require permission)

**Step 1: Implement TextInjector**

Create `Sources/FreeWispr/TextInjector.swift`:

```swift
import AppKit
import ApplicationServices

class TextInjector {

    func injectText(_ text: String) {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            injectViaKeyboard(text)
            return
        }

        let axElement = element as! AXUIElement

        // Try inserting at cursor via selected text attribute
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )

        if setResult != .success {
            injectViaKeyboard(text)
        }
    }

    private func injectViaKeyboard(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
```

**Step 2: Commit**

```bash
git add -A && git commit -m "feat: add TextInjector with AXUIElement and keyboard fallback"
```

---

### Task 7: Implement AppState and Wire Everything Together

**Files:**
- Create: `Sources/FreeWispr/AppState.swift`
- Modify: `Sources/FreeWispr/FreeWisprApp.swift`

**Step 1: Create AppState**

Create `Sources/FreeWispr/AppState.swift`:

```swift
import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready"
    @Published var selectedModel: ModelSize = .base

    let hotkeyManager = HotkeyManager()
    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let textInjector = TextInjector()
    let modelManager = ModelManager()

    func setup() async {
        // Check accessibility permission
        if !HotkeyManager.checkAccessibilityPermission() {
            statusMessage = "Needs Accessibility permission"
        }

        // Download default model if needed
        if !modelManager.isModelDownloaded(selectedModel) {
            statusMessage = "Downloading \(selectedModel.displayName) model..."
            do {
                try await modelManager.downloadModel(selectedModel)
            } catch {
                statusMessage = "Model download failed: \(error.localizedDescription)"
                return
            }
        }

        // Load model
        do {
            let modelPath = modelManager.localModelPath(for: selectedModel)
            try transcriber.loadModel(at: modelPath)
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model: \(error.localizedDescription)"
            return
        }

        // Set up hotkey
        hotkeyManager.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
        _ = hotkeyManager.start()

        // Set up audio completion handler
        audioRecorder.onRecordingComplete = { [weak self] samples in
            Task { @MainActor in
                await self?.transcribeAndInject(samples)
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            audioRecorder.stopRecording()
        } else {
            do {
                try audioRecorder.startRecording()
                isRecording = true
                statusMessage = "Listening..."
            } catch {
                statusMessage = "Mic error: \(error.localizedDescription)"
            }
        }
    }

    private func transcribeAndInject(_ samples: [Float]) async {
        isRecording = false
        guard !samples.isEmpty else {
            statusMessage = "Ready"
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."

        do {
            let text = try await transcriber.transcribe(audioSamples: samples)
            if !text.isEmpty {
                textInjector.injectText(text)
            }
            statusMessage = "Ready"
        } catch {
            statusMessage = "Transcription failed"
        }

        isTranscribing = false
    }

    func switchModel(to model: ModelSize) async {
        selectedModel = model
        transcriber.unloadModel()

        if !modelManager.isModelDownloaded(model) {
            statusMessage = "Downloading \(model.displayName)..."
            do {
                try await modelManager.downloadModel(model)
            } catch {
                statusMessage = "Download failed"
                return
            }
        }

        do {
            try transcriber.loadModel(at: modelManager.localModelPath(for: model))
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model"
        }
    }
}
```

**Step 2: Update FreeWisprApp.swift with full menu bar UI**

Replace `Sources/FreeWispr/FreeWisprApp.swift`:

```swift
import SwiftUI

@main
struct FreeWisprApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "mic.fill" :
                    appState.isTranscribing ? "text.bubble" : "mic")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                Circle()
                    .fill(appState.isRecording ? Color.red :
                            appState.isTranscribing ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(appState.statusMessage)
                    .font(.headline)
            }

            Divider()

            // Hotkey display
            HStack {
                Text("Hotkey:")
                Spacer()
                Text("⌥ Space")
                    .foregroundColor(.secondary)
            }

            // Model selector
            HStack {
                Text("Model:")
                Spacer()
                Picker("", selection: $appState.selectedModel) {
                    ForEach(ModelSize.allCases) { size in
                        Text("\(size.displayName) (\(size.sizeDescription))").tag(size)
                    }
                }
                .frame(width: 160)
                .onChange(of: appState.selectedModel) { _, newValue in
                    Task { await appState.switchModel(to: newValue) }
                }
            }

            if appState.modelManager.isDownloading {
                ProgressView(value: appState.modelManager.downloadProgress)
                    .progressViewStyle(.linear)
            }

            Divider()

            Button("Quit FreeWispr") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
        .frame(width: 280)
        .task {
            await appState.setup()
        }
    }
}
```

**Step 3: Build and verify**

```bash
cd FreeWispr && swift build
```

Expected: Build succeeds.

**Step 4: Commit**

```bash
git add -A && git commit -m "feat: wire up AppState and complete menu bar UI"
```

---

### Task 8: Manual Integration Test

**Step 1: Run the app**

```bash
cd FreeWispr && swift run
```

**Step 2: Verify checklist**

- [ ] Menu bar icon appears (mic icon)
- [ ] App prompts for Accessibility permission on first launch
- [ ] App downloads base model on first launch (check progress bar)
- [ ] Press Option+Space — icon changes to mic.fill, status shows "Listening..."
- [ ] Speak, then stop — after 1.5s silence, status shows "Transcribing..."
- [ ] Transcribed text appears in the focused text field
- [ ] Status returns to "Ready"
- [ ] Model picker works — can switch between tiny/base/small/medium
- [ ] Quit button works

**Step 3: Fix any issues found during manual testing**

**Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix: address issues from integration testing"
```

---

### Task 9: Polish and Final Commit

**Step 1: Add app icon placeholder and finalize Info.plist**

Ensure the `Info.plist` includes all required keys and the app builds cleanly.

**Step 2: Final build verification**

```bash
cd FreeWispr && swift build -c release
```

Expected: Release build succeeds.

**Step 3: Commit**

```bash
git add -A && git commit -m "chore: finalize project for release build"
```
