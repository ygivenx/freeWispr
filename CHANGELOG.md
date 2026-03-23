# Changelog

All notable changes to FreeWispr will be documented in this file.

## [1.3.0] - 2026-03-22

### Added
- Floating red recording indicator dot at top-center of screen with pulse animation (respects Reduce Motion)
- Color-coded status dots in menu bar: red (recording/error), orange (warning), blue (processing), green (ready)
- VoiceOver announcements for errors and warnings
- On-device LLM text correction via Apple Intelligence with 5-second timeout (macOS 26+)
- App-aware correction context — adjusts behavior for code editors, browsers, and messaging apps
- LLM refusal detection to fall back gracefully to raw transcription
- 30-second timeout on Whisper inference with clean cancellation via whisper.cpp abort callback
- Audio validation: reject recordings shorter than 0.3s or below silence threshold
- Peak normalization to consistent amplitude for quiet recordings
- GGML model file validation after download (magic byte check, auto-delete corrupt files)
- DMG update signature verification via SecStaticCode before installation
- Audio hardware configuration change detection (Bluetooth headset, mic switch) with automatic engine rebuild
- Thread-safe recording flag via dedicated DispatchQueue

### Changed
- Model switching now downloads before unloading the previous model, keeping dictation functional during failed downloads
- Build script improved with resource bundle existence check, DMG notarization, and Gatekeeper verification
- BundleExtension uses safer fallback chain instead of crashing on missing resource bundle
- Error messages are now temporary (auto-revert to "Ready" after 2s) with descriptive user-facing text

### Fixed
- Data race in audio tap callback by reading capture flag under bufferQueue
- Empty transcription errors replaced with specific user guidance messages
