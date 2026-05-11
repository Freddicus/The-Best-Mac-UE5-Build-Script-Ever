> This script and its docs were built with help from LLMs (started in ChatGPT, now Claude). Stitching UAT, Xcode archiving, codesigning, and notarization into something that actually works reliably took a lot of dead ends and genuine frustration — this stuff doesn't have a clean end-to-end tutorial anywhere. Sharing it here because once it finally worked, it felt wrong not to.

# The Best Mac Unreal Build Script Ever™

A bash script that runs the full macOS Developer ID distribution pipeline for UE5 projects: UAT build → Xcode archive → sign → notarize → staple.

Drop it in your project root and run it.

## Requirements

- macOS with Xcode and Command Line Tools installed
- Unreal Engine 5.x
- Apple Developer account — Team ID + Developer ID Application certificate in Keychain
- For notarization: a stored `notarytool` credential (`xcrun notarytool store-credentials`)

## Quick start

1. Copy `ship.sh` into your project root (the directory containing your `.uproject`).
2. Copy `.env.example` to `.env` next to the script and set at minimum:

```bash
DEVELOPMENT_TEAM="ABCDE12345"
SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"
NOTARY_PROFILE="MyNotaryProfile"   # only if notarizing
```

3. Run it:

```bash
chmod +x ship.sh
./ship.sh
```

The script prompts for build type (Shipping / Development) and whether to notarize. Set `BUILD_TYPE` and `NOTARIZE` in `.env` to skip prompts (required for CI).

Run `./ship.sh --help` for all CLI flags, or `./ship.sh --print-config` to validate your configuration without building.

### Targeting iOS too

The iOS pipeline is opt-in. To run it alongside Mac:

```bash
./ship.sh --ios
```

Or to skip Mac and build only iOS (no `SIGN_IDENTITY` required):

```bash
./ship.sh --ios-only
```

For App Store Connect upload, copy `iOS-ExportOptions.plist.example` to `iOS-ExportOptions.plist`, set `IOS_ASC_API_KEY_ID/ISSUER/KEY_PATH` in `.env`, and pass `--ios-upload-ipa`. See [docs/configuration.md](docs/configuration.md#ios-pipeline-opt-in) for the full iOS section.

## Pipeline

When you run `./ship.sh`, this is the execution order:

1. **Pre-flight** — validates signing identity, notary profile, UAT paths, and required tools before touching anything. iOS-only (`--ios-only`) skips the Mac signing identity check.
2. **Version stamp** *(if `VERSION_MODE` is set)* — writes `version.txt` into `Content/BuildInfo/` so UAT bundles it automatically.
3. **Canonical UE seeds** — defensively places stock engine files at their canonical UE locations if missing: `Build/Apple/Resources/Interface/LaunchScreen.storyboardc` and `Build/Mac/Resources/Info.Template.plist`. Mirrors a non-`AppIcon`-named `*.appiconset` (if any) inside `Build/{Platform}/Resources/Assets.xcassets/` to `AppIcon.appiconset` so `actool` finds it (UE's xcconfig hardcodes `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`). When `USE_UE_PACKAGE_VERSION_COUNTER=1` (Path A, opt-in), also seeds `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` and `Build/Mac/<Project>.PackageVersionCounter`.
4. **Canonical ini ensures** — writes `MARKETING_VERSION` (shared across Mac and iOS) and `APP_CATEGORY` (when set) to their canonical `Config/DefaultEngine.ini` sections. `ENABLE_GAME_MODE` (when set) updates the seeded `Info.Template.plist` via `PlistBuddy`. See [versioning.md](docs/versioning.md#infoplist-values-via-canonical-ue-overrides).
5. **GenerateProjectFiles** *(if `USE_XCODE_EXPORT=1`)* — single regen produces both `<Project> (Mac).xcworkspace` and `<Project> (iOS).xcworkspace`. Disable with `--no-regen-project-files`.

**Mac pipeline** *(skipped when `IOS_ONLY=1`)*:

6. **Mac UAT BuildCookRun** — `-targetplatform=Mac`, output to `Saved/Packages/Mac/`.
7. **Mac Xcode archive + export** — `xcodebuild archive` with `CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION` build-setting override (Apple-documented mechanism, takes precedence over xcconfig — no PlistBuddy fixups needed). Then `xcodebuild -exportArchive` produces signed `.app`.
8. **Mac component signing** — signs nested `.dylib`/`.so`/`.framework` individually, then the outer `.app`. Never uses `--deep`.
9. **Steam staging** *(if `ENABLE_STEAM=1`)* — copies `libsteam_api.dylib` next to the executable and signs it.
10. **ZIP / DMG** — packages the signed `.app` for distribution.
11. **Notarization + stapling** — `xcrun notarytool` submits ZIP and DMG, waits, then `xcrun stapler` attaches tickets.

**iOS pipeline** *(only when `ENABLE_IOS=1` or `--ios-only`)*:

12. **iOS UAT BuildCookRun** — `-targetplatform=IOS`, output to `Saved/Packages/IOS/`.
13. **iOS Xcode archive + export** — `xcodebuild archive -destination 'generic/platform=iOS' -allowProvisioningUpdates` with the same `CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION` (shared bump across platforms). Then `xcodebuild -exportArchive` with the iOS `ExportOptions.plist` → `.ipa`. iOS doesn't need per-component codesign or notarization — `xcodebuild` handles iOS App Store signing in one pass via automatic provisioning.
14. **App Store Connect** *(optional)* — `xcrun altool --validate-app` and/or `--upload-app` (TestFlight / App Store review). **Note:** `altool` ≠ `notarytool` — different tools, different services. See [configuration.md](docs/configuration.md#ios-app-store-connect-upload-xcrun-altool--not-notarytool).

**CFBundleVersion** is auto-bumped from `CFBUNDLE_VERSION` in `.env` (default Path B; one bump per `ship.sh` run, shared across both archives). `--set-cfbundle-version N` sets a new baseline. `USE_UE_PACKAGE_VERSION_COUNTER=1` opts into Path A (UE's canonical mechanism). See [versioning.md](docs/versioning.md#cfbundleversion-auto-bump-by-default-opt-in-for-ue-canonical).

Full build log: `Saved/Logs/build_YYYY-MM-DD_HH-MM-SS.log`. Mac artifacts land in `Saved/Packages/Mac/` (`--build-dir` overrides); iOS artifacts in `Saved/Packages/IOS/`. `Build/{Platform}/` is reserved for committed source-controlled inputs (icons, launch storyboard, entitlements) — see [output.md](docs/output.md#build-vs-saved--what-goes-where).

## Docs

- [Configuration reference](docs/configuration.md) — all `.env` variables, CLI flags, workspace and scheme setup
- [Versioning](docs/versioning.md) — `VERSION_MODE`, bump flags, xcconfig and Info.plist stamping
- [Output and packaging](docs/output.md) — DMG, ZIP, icon seeding, artifact paths
- [Steam support](docs/steam.md) — dylib staging, entitlements, `steam_appid.txt`
- [Troubleshooting](docs/troubleshooting.md) — common failures and how to fix them
- [Gotchas](docs/gotchas.md) — things macOS signing and notarization will bite you with

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The only CI check is `shellcheck ship.sh` — run it before opening a PR.
