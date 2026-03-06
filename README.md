# FreeWispr

A free, local, privacy-first alternative to Apple Dictation for macOS. Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for on-device speech-to-text — no cloud, no network calls, no subscriptions.

## How It Works

1. Hold **Ctrl+Option** (or **Globe key**) to record
2. Release to transcribe
3. Text is pasted into whatever app you're focused on

That's it. All processing happens locally on your Mac.

## Features

- **Push-to-talk** dictation into any app (terminals, editors, chat apps, browsers)
- **Core ML acceleration** on Apple Silicon for fast inference
- **User-configurable model sizes** — tiny (~75 MB), base (~142 MB), small (~466 MB), medium (~1.5 GB)
- **Menu bar app** — lives in your menu bar, no dock icon
- **Auto-downloads models** on first launch from Hugging Face

## Requirements

- macOS 14+
- Apple Silicon or Intel Mac
- Accessibility permission (for global hotkey)
- Microphone permission

## Build & Run

```bash
cd FreeWispr
swift build
swift run
```

On first launch, FreeWispr will:
1. Prompt for Accessibility permission (System Settings > Privacy > Accessibility)
2. Download the base whisper model + Core ML encoder (~180 MB total)
3. Appear as a mic icon in your menu bar

## Usage

- **Hold Ctrl+Option** or **Globe key** — starts recording
- **Release** — stops recording and transcribes
- Click the menu bar icon to change model size or quit

## Tech Stack

- Swift / SwiftUI
- [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (whisper.cpp SPM wrapper)
- AVAudioEngine for audio capture
- CGEvent for global hotkey
- NSPasteboard for universal text injection via Cmd+V

## License

MIT
