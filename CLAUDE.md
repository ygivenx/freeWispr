# FreeWispr — Architecture Guide

## Overview

FreeWispr is a privacy-first, local dictation app for macOS. It runs as a menu bar utility using push-to-talk: hold a hotkey to record, release to transcribe, text appears wherever your cursor is. All processing happens on-device via whisper.cpp with Core ML acceleration.

## Data Flow

```
User holds hotkey (Ctrl+Option or Globe)
        ↓
HotkeyManager detects key via CGEvent tap
        ↓
AppState.startRecording()
        ↓
AudioRecorder captures mic → converts to 16kHz PCM float32
        ↓
User releases hotkey
        ↓
AudioRecorder.stopRecording() → emits [Float] samples
        ↓
WhisperTranscriber.transcribe(samples) → runs whisper.cpp inference
        ↓
TextInjector.injectText(text) → clipboard + Cmd+V paste
        ↓
Previous clipboard restored after 0.5s
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
│   ├── TextInjector.swift          # Clipboard + keyboard simulation
│   ├── ModelManager.swift          # Model download/storage lifecycle
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
- `setup()` — check permissions, download model, load model, start hotkey, prepare audio
- `startRecording()` / `stopAndTranscribe()` — hotkey callbacks
- `switchModel(to:)` — unload, download if needed, reload

### HotkeyManager.swift — Global Hotkey
Uses `CGEvent.tapCreate()` to listen for modifier key changes system-wide. Detects Globe key (`maskSecondaryFn`) or Ctrl+Option combo. Requires Accessibility permission. Fires `onHotkeyDown` / `onHotkeyUp` callbacks.

### AudioRecorder.swift — Audio Capture
Captures from default mic via `AVAudioEngine`. Converts hardware format (44.1kHz stereo) to whisper format (16kHz mono float32) using `AVAudioConverter`. The audio tap is installed once during `prepareEngine()` to avoid repeated TCC permission checks. Engine starts/stops per recording so the mic indicator only shows while dictating. Buffer accumulation is thread-safe via a dedicated `DispatchQueue`.

### WhisperTranscriber.swift — Inference
Thin wrapper around SwiftWhisper. Loads GGML model with greedy decoding, English language preset, single-segment mode for speed. Transcription is async — returns joined segment text.

### ModelManager.swift — Model Lifecycle
Downloads GGML weights + Core ML encoder from Hugging Face. Stores in `~/Library/Application Support/FreeWispr/models/`. Tracks download progress (70% GGML, 30% Core ML). Core ML encoder is downloaded as `.zip` and extracted via `/usr/bin/unzip`.

Model sizes: tiny (~75MB), base (~142MB, default), small (~466MB), medium (~1.5GB).

### TextInjector.swift — Universal Paste
Saves current clipboard, sets transcribed text, simulates Cmd+V via `CGEvent`, then restores previous clipboard after 0.5s (checking `changeCount` to avoid clobbering user activity). Works in any app including terminals.

### BundleExtension.swift — Resource Resolution
SPM's generated `Bundle.module` looks at the `.app` root, but signed bundles need resources in `Contents/Resources/`. `Bundle.appResources` checks the correct path first, falling back to `Bundle.module` for dev builds.

## Threading Model

- **Main thread (`@MainActor`):** All UI state updates, AppState methods
- **Audio thread:** AVAudioEngine tap callback → buffer append via `bufferQueue`
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
| Menu bar app (`LSUIElement`) | Always available, no dock clutter |
| Push-to-talk | Precise control, low latency, familiar UX |
| Clipboard + Cmd+V | Universal — works in every app including terminals |
| One-time audio tap install | Avoids repeated AudioConverter creation and TCC checks |
| Engine start/stop per recording | Mic indicator only shows while dictating |
| Greedy + single segment | Fastest inference for short dictation clips |
| Core ML encoder | Apple Neural Engine acceleration on Apple Silicon |

## gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

Available skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`.

### Setup (one-time per developer)
```bash
git clone https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup
```
