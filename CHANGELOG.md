# Changelog

All notable changes to FreeWispr will be documented in this file.

## [1.3.2] - 2026-10-05

### Fixed
- Recover safely from USB/dock microphone changes and native audio-engine exceptions; discard interrupted recordings and reset the recording indicator.
- Open a fresh audio engine for each recording and retry failed starts once without retaining stale microphone formats or samples.
- Detect when another application is using the default microphone and show a recoverable busy message.
- Keep recorder and transcription state on the main actor; prevent overlapping inference and model switching during recording/transcription.
- Keep the recording indicator visible when a dock or external screen disconnects.
- Remove audio configuration observers and hotkey event taps during teardown; ignore delayed notifications from previous recordings.
- Start setup from the app lifecycle so menu label updates cannot cancel initialization.
- Supply each audio buffer to the sample-rate converter only once.
- Notarize and verify the distributable DMG in stable and tip release workflows; run unit tests before packaging.
- Match release tags to VERSION and Info.plist, and run local Gatekeeper checks after notarization.
- Correct downloadable-build requirements to Apple Silicon and add a release/distribution checklist.
- Update VERSION and both bundle version fields to 1.3.2 (the source plist previously still reported 1.2.1).

## [1.3.1] - 2026-03-25

### Fixed
- Handle Teams audio configuration changes on the main queue and stop interrupted recordings cleanly.

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
