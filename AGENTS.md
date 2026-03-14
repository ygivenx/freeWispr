# Repository Guidelines

## Project Structure & Module Organization
FreeWispr is a Swift Package Manager workspace under `FreeWispr/`. `Sources/FreeWispr` hosts the app core (audio capture, Whisper bindings, pasteboard injection), while `Sources/FreeWisprEntry` contains the minimal executable wrapper and lifecycle glue. Tests live in `Tests/FreeWisprTests` for unit coverage and `Tests/BenchmarkTests` for latency measurements. Assets for docs, screenshots, and menu bar icons live under `assets/` and `docs/`, and automation or release utilities are in `scripts/`.

## Build, Test, and Development Commands
Run `cd FreeWispr && swift build` for debug builds or `swift build -c release` before packaging. `swift run FreeWispr` launches the menu bar app locally (requires macOS 14+). Execute `swift test` for the full test matrix; add `--filter BenchmarkTests/LatencyTests` when iterating on performance. Use `scripts/build-and-notarize.sh <version>` when creating signed DMGs; it assumes Developer ID credentials are configured in your keychain.

## Coding Style & Naming Conventions
Stick to the Swift API Design Guidelines: UpperCamelCase for types, lowerCamelCase for functions, and 4-space indentation. Keep stateful types `final class` unless inheritance is required, and annotate concurrency expectations (`@MainActor`, `Task`). Prefer dependency injection so components in `FreeWisprCore` stay testable. Resources copied through `Resources/` should follow descriptive kebab-case filenames (e.g., `menu-icon-dark.pdf`). Run `swift format --in-place` if you have it installed; otherwise match the surrounding style manually.

## Testing Guidelines
All new logic in `FreeWisprCore` needs an accompanying XCTest with descriptive names like `testHotkeyManagerDebouncesInput`. Integration behavior affecting audio loops should include a benchmark guardrail in `BenchmarkTests`, using `measure {}` blocks to catch regressions on Apple Silicon. When touching audio or pasteboard behavior, capture expected outputs via fakes in `Tests/Fixtures`. Use `swift test --enable-code-coverage` before submitting and confirm no tests rely on actual microphone hardware.

## Commit & Pull Request Guidelines
Follow the existing Conventional Commits flavor (`fix: …`, `feat: …`, `chore: …`). Keep the subject under 72 characters and describe user-facing outcomes in the body. Pull requests must include: a summary of the change, reproduction/verification steps, screenshots or screen recordings for UI changes, and links to the relevant GitHub issue. Mention any permissions or entitlements touched (microphone, accessibility) so reviewers can double-check provisioning.

## Security & Configuration Tips
Keep signing assets (`certs/` contents, Apple notarization credentials) out of commits; the scripts read them via environment variables such as `APPLE_ID` and `APP_SPECIFIC_PASSWORD`. When debugging Accessibility prompts, reset permissions via `tccutil reset Accessibility FreeWispr` and re-run `swift run FreeWispr` to trigger system dialogs.
