# FreeWispr — Architecture Guide

## Overview

FreeWispr is a privacy-first, local dictation app for macOS. It runs as a menu bar utility using push-to-talk: hold a hotkey to record, release to transcribe, text appears wherever your cursor is. All processing happens on-device via whisper.cpp with Core ML acceleration.

## Data Flow

```
User holds hotkey (Ctrl+Option or Globe)
        ↓
HotkeyManager detects key via CGEvent tap
        ↓
AppState.startRecording() → captures frontmost app, shows recording indicator
  Apple engine: beginSession() + chunk sink; Whisper: prewarm() context
        ↓
AudioRecorder captures mic → converts to 16kHz PCM float32
  Apple engine: each chunk streamed to AppleSpeechTranscriber while held
        ↓
User releases hotkey → mic stays open for a 0.25s release tail
        ↓
AudioRecorder emits [Float] samples
        ↓
Validation: reject < 0.3s; AudioPreprocessor.analyze (speech/noise/clipping)
        ↓
Apple (macOS 26+, default): finish() → text + min confidence (~0.16s after release)
Whisper: reject if no speech → high-pass + loudness normalize → whisper.cpp (30s timeout)
        ↓
Terminal frontmost + utterance starts with a known command → TerminalCommandFormatter
  ("cd dot dot" → "cd ..") and AI Cleanup is skipped
        ↓
TextCorrector.correct(text) → optional AI Cleanup (5s timeout, macOS 26+;
  Apple path only when min confidence < 0.7, Whisper path always)
        ↓
TextInjector.injectText(text) → clipboard + Cmd+V paste
        ↓
Previous clipboard restored after 0.5s; "Mic is clipping" hint if input clipped
```

## Directory Structure

```
FreeWispr/
├── Package.swift                    # SPM manifest (SwiftWhisper dependency)
├── FreeWispr.entitlements          # Audio input + unsigned memory
├── Sources/FreeWispr/
│   ├── FreeWisprApp.swift          # @main entry, MenuBarExtra UI
│   ├── AppState.swift              # Central orchestrator
│   ├── HotkeyManager.swift         # Global hotkey via CGEvent tap
│   ├── AudioRecorder.swift         # AVAudioEngine capture + resampling
│   ├── WhisperTranscriber.swift    # SwiftWhisper inference wrapper
│   ├── AppleSpeechTranscriber.swift # Streaming SpeechTranscriber (macOS 26+)
│   ├── AudioPreprocessor.swift     # Speech analysis + loudness normalization
│   ├── TextInjector.swift          # Clipboard + keyboard simulation
│   ├── ModelManager.swift          # Model download/storage lifecycle
│   ├── TextCorrector.swift         # On-device LLM correction (macOS 26+)
│   ├── TerminalCommandFormatter.swift # Spoken shell commands → typed form (terminals only)
│   ├── RecordingIndicator.swift    # Floating red dot while recording
│   ├── UpdateChecker.swift         # GitHub release update checker
│   ├── BundleExtension.swift       # Resource bundle resolution
│   ├── Info.plist                  # Bundle metadata (LSUIElement=true)
│   └── Resources/                  # App icon, menu bar icons
└── Tests/FreeWisprTests/

scripts/
└── build-and-notarize.sh           # Build → sign → notarize → DMG

.github/
├── workflows/release.yml           # CI/CD on version tags
└── ISSUE_TEMPLATE/                 # Bug report + feature request
```

## Core Components

### AppState.swift — Orchestrator
Central `@MainActor` state machine. Owns all managers, coordinates the full lifecycle:
- `setup()` — check permissions, pick engine (Apple `prepare()`, falling back to Whisper on failure), download/load Whisper only if it is active, start hotkey
- `startRecording()` — refuses unless the active engine is ready and nothing is recording/transcribing/switching; captures frontmost app context, starts the engine's session (Apple `beginSession` + chunk sink, or Whisper `prewarm`), starts mic, shows recording indicator
- `stopAndTranscribe()` — stops mic (after the release tail); `transcribeAndInject` validates audio (min duration, speech via `AudioPreprocessor.analyze`), finishes the Apple session or runs Whisper on preprocessed audio, then optionally corrects via LLM. A mic interruption cancels the Apple session and discards the audio
- `switchEngine(to:)` — Apple (prepare, then unload Whisper) or Whisper size (download first, keeping previous functional, then unload and reload). Choice persists in UserDefaults `transcriptionEngine`; defaults to Apple when supported

### HotkeyManager.swift — Global Hotkey
Uses `CGEvent.tapCreate()` to listen for modifier key changes system-wide. Detects Globe key (`maskSecondaryFn`) or Ctrl+Option combo. Requires Accessibility permission. Fires `onHotkeyDown` / `onHotkeyUp` callbacks.

### AudioRecorder.swift — Audio Capture
A main-actor recorder opens a fresh default-microphone engine for every recording via the native `MicrophoneCapture` target. It rejects a busy microphone, validates the live format, installs a tap without forcing a cached format, and retries startup once. Native engine operations catch Objective-C exceptions and release taps/observers on teardown. Configuration changes arrive on the main queue, are matched to the current session, and discard interrupted audio while resetting the UI. `AudioCaptureBuffer` owns each attempt's samples/converter and serializes conversion/finalization on a dedicated queue; it supplies each input buffer only once and converts delivered formats to 16kHz mono float32. Tests inject engines and a native exception fixture without opening the microphone. `releaseTail` (0.25s in the app) keeps capturing after release so the last word isn't cut; a configuration change during the tail delivers what was captured, a new start during the tail delivers the pending recording first, and each recording is delivered once. `onChunk` is captured per recording and forwards converted chunks on the buffer queue until `finish()`.

### WhisperTranscriber.swift — Inference
Thin wrapper around SwiftWhisper with a guard against overlapping inference. State is lock-guarded so model loads run off the main thread. Loads GGML model with greedy decoding, English language preset, single-segment mode for speed. Transcription is async — returns joined segment text. 30-second timeout cancels inference via whisper.cpp abort callback. Periodically reloads model (every 50 transcriptions) to reclaim whisper.cpp KV cache memory. Frees the context after 10 min idle; `prewarm()` (hotkey-down) reloads in the background and `transcribe` reloads lazily.

### AppleSpeechTranscriber.swift — Streaming Inference (macOS 26+)
Wraps `SpeechAnalyzer`/`SpeechTranscriber` (en-US). `prepare()` installs assets; `beginSession()` / thread-safe `append()` stream 16kHz chunks while the key is held, so only `finish()` remains after release. Returns text plus min/average confidence (from final results only). A second, preview-only analyzer (volatile + fast results, ~1-2 s to first word) runs alongside the final one; it is separate because fastResults lowers accuracy and modules sharing an analyzer share one config. The per-session `onPartial` callback gets finalized text plus the latest in-progress words, and is never invoked after `finish()`/`cancel()`. Benchmarked 7.2% WER vs 9.9% for Whisper base. Default engine when `isSupported()`.

### AudioPreprocessor.swift — Audio Analysis
`analyze()` reports speech RMS, noise floor, clipped fraction, and speech range (`hasSpeech`). `prepareForBatch()` applies a 90 Hz high-pass and loudness normalization for Whisper. Silence trimming exists but is off: it hurt WER.

### ModelManager.swift — Model Lifecycle
Downloads GGML weights + Core ML encoder from Hugging Face. Stores in `~/Library/Application Support/FreeWispr/models/`. Tracks download progress (70% GGML, 30% Core ML). Core ML encoder is downloaded as `.zip` and extracted via `/usr/bin/unzip`. Validates GGML files after download (magic byte check) and auto-deletes corrupt files.

Model sizes: tiny (~75MB), base (~142MB, default), small (~466MB), medium (~1.5GB).

### TextCorrector.swift — LLM Correction (macOS 26+)
On-device text correction via Apple Intelligence FoundationModels framework. Fixes punctuation, capitalization, and homophones in Whisper output. 5-second timeout races LLM against raw transcription. App-aware context adjusts instructions for code editors (preserve camelCase/snake_case), browsers, and messaging apps. Includes refusal detection to fall back gracefully.

### TerminalCommandFormatter.swift — Terminal Command Mode
Pure Swift. When the target app is a known terminal and the utterance starts with a known shell command (cd, git, ls, ...), converts spoken symbols ("dot", "slash", "dash dash", "pipe", ...) to characters and bypasses AI Cleanup. Returns nil for anything else, leaving the text untouched. Utterances starting with a symbol word ("dot slash build") are not treated as commands.

### RecordingIndicator.swift — Visual Feedback
Floating 12px red dot at top-center of screen using `NSPanel` at status-window level. Pulse animation respects `accessibilityDisplayShouldReduceMotion`. Visible on all Spaces, ignores mouse events. Screen-change notifications reposition the panel after external-monitor changes; observers and panels are cleaned up on teardown. `updatePreview(_:)` (Apple engine only) shows a dark HUD-style caption (13pt white, max 420pt wide, 2 lines, head-truncated so the newest words show) beside the dot; empty text hides it. The panel stays non-activating so the paste target keeps focus.

### UpdateChecker.swift — Auto-Update
Checks GitHub Releases API for newer versions. Verifies DMG code signature via `SecStaticCode` before installation. Falls back to opening the release page when running unsigned (dev builds).

### TextInjector.swift — Universal Paste
Saves current clipboard, sets transcribed text, simulates Cmd+V via `CGEvent`, then restores previous clipboard after 0.5s (checking `changeCount` to avoid clobbering user activity). Works in any app including terminals.

### BundleExtension.swift — Resource Resolution
SPM's generated `Bundle.module` looks at the `.app` root, but signed bundles need resources in `Contents/Resources/`. `Bundle.appResources` checks the correct path first, then the executable-adjacent path, falling back to `Bundle.main` for safe degradation.

## Threading Model

- **Main thread (`@MainActor`):** All UI state updates, AppState methods
- **Audio thread:** AVAudioEngine tap callback → buffer append via `bufferQueue`; chunks are forwarded from that queue to `AppleSpeechTranscriber.append` (thread-safe)
- **Background:** Model downloads (URLSession), whisper inference (async/await)
- **CGEvent callback:** Hotkey detection, dispatches to main via `DispatchQueue.main.async`

## Build & Release

### Local
```bash
SIGNING_IDENTITY="Developer ID Application: ..." \
NOTARIZE_PROFILE="FreeWispr-notarize" \
  ./scripts/build-and-notarize.sh <version>
```

Stages: `swift build` → assemble `.app` → codesign → notarize → staple → create DMG

### CI/CD
Push a version tag (`v*`) to trigger `.github/workflows/release.yml`. Requires these GitHub secrets:
- `CERTIFICATE_P12` — base64 .p12 signing cert
- `CERTIFICATE_PASSWORD`
- `APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD`

The workflow installs the cert in a temp keychain, builds, signs, notarizes, creates DMG, and publishes a GitHub Release.

## Permissions

| Permission | Why | Triggered by |
|---|---|---|
| Accessibility | CGEvent tap for global hotkey | `AXIsProcessTrustedWithOptions` on setup |
| Microphone | Audio capture | System prompt on first `AVAudioEngine.start()` |

## Entitlements
- `com.apple.security.cs.allow-unsigned-executable-memory` — JIT for whisper.cpp
- `com.apple.security.device.audio-input` — microphone access

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Terminal command mode only when utterance starts with a known command | Prose to terminal AI tools stays untouched |
| Menu bar app (`LSUIElement`) | Always available, no dock clutter |
| Push-to-talk | Precise control, low latency, familiar UX |
| Clipboard + Cmd+V | Universal — works in every app including terminals |
| Fresh engine per recording | Avoids stale device formats after Teams or USB/dock route changes |
| Engine start/stop per recording | Mic indicator only shows while dictating |
| Greedy + single segment | Fastest inference for short dictation clips |
| Live preview bubble, paste on release | Typing live into the target app would need backspace revisions, fragile in terminals/Electron |
| Core ML encoder | Apple Neural Engine acceleration on Apple Silicon |
| 30s inference timeout | Prevent hung whisper.cpp from blocking the app |
| 5s LLM correction timeout | Correction is nice-to-have; raw transcription is the core value |
| Download before unload | Failed model downloads keep previous model functional |
| GGML magic byte validation | Detect corrupt downloads before loading into whisper.cpp |
| Loudness normalization (not peak) | Judges speech frames, so one loud click doesn't leave quiet speech unboosted |
| No silence trimming | Benchmarked: trimming hurt WER |
| Apple speech default on macOS 26+ | Lower WER (7.2% vs 9.9%) and no model download; Whisper remains for older macOS / user choice |
| Stream during hold | Apple finalizes ~0.16s after release instead of batch-processing the clip |
| 0.25s release tail | People release the key before finishing the last word |
| LLM cleanup gated at min confidence 0.7 (Apple path) | Same accuracy gain as always-on, skips ~32% of ~0.86s LLM calls |

## gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

Available skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`.

### Setup (one-time per developer)
```bash
git clone https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup
```
