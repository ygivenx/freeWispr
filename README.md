<p align="center">
  <img src="assets/logo.jpg" alt="FreeWispr" width="200">
</p>

<h1 align="center">FreeWispr</h1>

<p align="center">
  Free, local, privacy-first dictation for macOS — powered by <a href="https://github.com/ggerganov/whisper.cpp">whisper.cpp</a>
</p>

<p align="center">
  <a href="https://github.com/ygivenx/freeWispr/releases/latest"><img src="https://img.shields.io/github/v/release/ygivenx/freeWispr?style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-optimized-orange?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
</p>

---

<!--
## Demo

<p align="center">
  <img src="assets/demo.gif" alt="FreeWispr demo" width="600">
</p>

To record a demo GIF:
1. Open QuickTime Player > File > New Screen Recording
2. Record a short clip showing hold-to-dictate in action
3. Convert to GIF: `ffmpeg -i demo.mov -vf "fps=15,scale=600:-1" assets/demo.gif`
4. Uncomment this section
-->

## Why FreeWispr?

| | **FreeWispr** | **Wispr Flow** | **Apple Dictation** |
|---|---|---|---|
| **Price** | Free & open source | $8/month | Free |
| **Privacy** | 100% local, no network | Cloud-based | Cloud-based |
| **Works in** | Any app (terminals, editors, browsers) | Most apps | Limited app support |
| **Models** | Configurable (tiny → medium) | Proprietary | Fixed |
| **Latency** | Real-time on Apple Silicon | Network dependent | Network dependent |
| **Open source** | Yes | No | No |

## Download

**[Download the latest release](https://github.com/ygivenx/freeWispr/releases/latest)** — grab the `.dmg`, drag to Applications, done.

> Requires macOS 14+ on Apple Silicon or Intel.

<!--
### Homebrew (coming soon)

```bash
brew install --cask freewispr
```
-->

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

## Build from Source

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

## Contributing

Contributions are welcome! Please see the [issue tracker](https://github.com/ygivenx/freeWispr/issues) for open issues, or open a new one to discuss your idea.

## License

MIT
