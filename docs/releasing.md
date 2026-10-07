# Releasing FreeWispr

Stable releases are created automatically when a version tag is pushed. The workflow builds an arm64 macOS app, signs it with Apple Developer ID, notarizes the app and DMG, validates both, and publishes a GitHub Release.

## Prepare and test

1. Set `VERSION`, both version fields in `FreeWispr/Sources/FreeWispr/Info.plist`, and the changelog to the new version. For this release, use **1.3.2**.
2. Confirm the PR unit-test check passes. PR #14 passed 53 tests before the release-readiness additions.
3. Build a signed testing release from GitHub: **Actions → Tip Release → Run workflow**, select `codex/microphone-crash-v1.3.2`, and run it. This publishes a prerelease and replaces previous tip prereleases.
4. Download its DMG and verify installation, microphone/Accessibility permissions, first-launch model downloads, dictation, Teams microphone handoff, dock disconnect/reconnect, and the displayed version on the target Mac. When another app uses the default microphone, FreeWispr intentionally shows a busy message.
5. Merge PR #14 into `main` after verification. The latest stable release is currently v1.3.1.

## Publish v1.3.2

After merging, run these commands from a repository checkout. Tagging `origin/main` avoids including uncommitted local edits:

```sh
git fetch origin
git tag -a v1.3.2 origin/main -m "FreeWispr v1.3.2"
git push origin v1.3.2
```

Pushing the tag starts the **Release** workflow and publishes publicly after its checks succeed. Wait for all steps in [GitHub Actions](https://github.com/ygivenx/freeWispr/actions/workflows/release.yml) to pass. Do not manually create a competing GitHub Release for that tag: the workflow creates it.

The workflow requires the configured secrets `CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APP_SPECIFIC_PASSWORD`. Presence of a secret does not establish that the credential is still valid; signing/notarization in the testing release verifies it.

## Verify distribution

- The [latest release page](https://github.com/ygivenx/freeWispr/releases/latest) should show v1.3.2 and `FreeWispr-1.3.2.dmg`.
- Download that actual DMG, install it, and confirm the app reports 1.3.2. The prebuilt package supports Apple Silicon, macOS 14+.
- On an existing installation, relaunch FreeWispr and check that it offers the new release. The current updater checks on launch and downloads a DMG for manual installation; periodic/seamless updates are separate PR #11.
- All model sizes fetch their model and Core ML encoder from Hugging Face. Check first-launch downloads on a fresh installation; successful URL checks alone do not verify installation.
- For public download buttons, use the stable **release page** URL above. A version-specific DMG link stays on that old version until edited. `/releases/latest/download/FreeWispr-1.3.2.dmg` will stop working once the latest release no longer contains that filename.

## Gumroad and other storefronts

No Gumroad API integration, credential, or repository webhook was found during the October 6, 2026 audit. An external automation may exist outside this repository and must be checked separately.

If Gumroad delivers an uploaded DMG, update the existing product's **Content** with the exact notarized `FreeWispr-1.3.2.dmg` from GitHub. If it delivers a download link, inspect whether it points to the stable GitHub release page or an old version-specific file. Verify both a new customer's delivery and an existing customer's library download with [Gumroad's test-purchase feature](https://gumroad.com/help/article/62-testing-a-purchase). Software version numbers do not require creating a new Gumroad pricing tier.

Check the listing's version, macOS/Apple Silicon requirements, installation instructions, price, receipt link, and delivered file. Publishing on GitHub does not prove that a storefront's uploaded file has changed. Send customer notifications only when explicitly requested.

## Audit results: October 6, 2026

- PR #14's original code check: 53 unit tests passed; debug and optimized arm64 builds passed.
- v1.3.1 DMG download SHA-256 matched GitHub's recorded digest.
- The app's signature validated and Gatekeeper accepted it as **Notarized Developer ID**. Its public signing certificate expires February 1, 2027; the CI secret may contain a different certificate.
- The v1.3.1 DMG signature validated, but Gatekeeper rejected the DMG itself as **Unnotarized Developer ID**. Release workflows now notarize/staple/assess the DMG before publication; a newly packaged artifact must still prove this path succeeds.
- All eight tiny/base/small/medium model and Core ML encoder URLs returned HTTP 200 using HEAD requests. Files were not downloaded in full.
- Gumroad product URL, delivered content, and customer flow remain unverified until the product/account is identified.
