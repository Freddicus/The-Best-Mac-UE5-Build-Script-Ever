# Pipeline

When you run `./ship.sh`, this is the execution order.

## Shared setup (always runs)

1. **Pre-flight** — validates signing identity, notary profile, UAT paths, and required tools before touching anything. iOS-only (`--ios-only`) skips the Mac signing identity check.
2. **Version stamp** *(if `VERSION_MODE` is set)* — writes `version.txt` into `Content/BuildInfo/` so UAT bundles it automatically.
3. **Canonical UE seeds** — defensively places stock engine files at their canonical UE locations if missing: `Build/Apple/Resources/Interface/LaunchScreen.storyboardc` and `Build/Mac/Resources/Info.Template.plist`. Mirrors a non-`AppIcon`-named `*.appiconset` (if any) inside `Build/{Platform}/Resources/Assets.xcassets/` to `AppIcon.appiconset` so `actool` finds it (UE's xcconfig hardcodes `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`). When `USE_UE_PACKAGE_VERSION_COUNTER=1` (Path A, opt-in), also seeds `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` and `Build/Mac/<Project>.PackageVersionCounter`.
4. **Canonical ini ensures** — writes `MARKETING_VERSION` (shared across Mac and iOS) and `APP_CATEGORY` (when set) to their canonical `Config/DefaultEngine.ini` sections. `ENABLE_GAME_MODE` (when set) updates the seeded `Info.Template.plist` via `PlistBuddy`. See [versioning.md](versioning.md#infoplist-values-via-canonical-ue-overrides).
5. **GenerateProjectFiles** *(if `USE_XCODE_EXPORT=1`)* — single regen produces both `<Project> (Mac).xcworkspace` and `<Project> (iOS).xcworkspace`. Disable with `--no-regen-project-files`.

## Mac pipeline — `MAC_DISTRIBUTION=developer-id` *(default; skipped when `MAC_DISTRIBUTION=off`)*

6. **Mac UAT BuildCookRun** — `-targetplatform=Mac`, output to `BuildArtifacts/Mac/`.
7. **Mac Xcode archive + export** — `xcodebuild archive` with `CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION` build-setting override (Apple-documented mechanism, takes precedence over xcconfig — no PlistBuddy fixups needed). Then `xcodebuild -exportArchive` produces signed `.app`.
8. **Mac component signing** — signs nested `.dylib`/`.so`/`.framework` individually, then the outer `.app`. Never uses `--deep`.
9. **Steam staging** *(if `ENABLE_STEAM=1`)* — copies `libsteam_api.dylib` next to the executable and signs it.
10. **ZIP / DMG** — packages the signed `.app` for distribution.
11. **Notarization + stapling** — `xcrun notarytool` submits ZIP and DMG, waits, then `xcrun stapler` attaches tickets.

## Mac pipeline — `MAC_DISTRIBUTION=app-store` *(Mac App Store)*

6. **Mac UAT BuildCookRun** — `-targetplatform=Mac`.
7. **Mac Xcode archive + export** — `xcodebuild archive -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic` then `xcodebuild -exportArchive` with a MAS export plist (`method=app-store-connect`). Produces a signed `.pkg` (productbuild installer), not a `.app`.
8. **App Store Connect** *(optional)* — `xcrun altool --validate-app -t macos` and/or `--upload-app -t macos`. No notarize+staple, no ZIP, no DMG — App Store review is the equivalent gate.

## iOS pipeline *(only when `IOS_DISTRIBUTION=app-store`, e.g. `--ios` or `--ios-only`)*

12. **iOS UAT BuildCookRun** — `-targetplatform=IOS`, output to `BuildArtifacts/IOS/`.
13. **iOS Xcode archive + export** — `xcodebuild archive -destination 'generic/platform=iOS' -allowProvisioningUpdates` with the same `CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION` (shared bump across platforms). Then `xcodebuild -exportArchive` with the iOS `ExportOptions.plist` → `.ipa`. iOS doesn't need per-component codesign or notarization — `xcodebuild` handles iOS App Store signing in one pass via automatic provisioning.
14. **App Store Connect** *(optional)* — `xcrun altool --validate-app` and/or `--upload-app` (TestFlight / App Store review). **Note:** `altool` ≠ `notarytool` — different tools, different services. See [configuration.md](configuration.md#ios-app-store-connect-upload-xcrun-altool--not-notarytool).

## Notes

**CFBundleVersion** is auto-bumped from `CFBUNDLE_VERSION` in `.env` (default Path B; one bump per `ship.sh` run, shared across both archives). `--set-cfbundle-version N` sets a new baseline. `USE_UE_PACKAGE_VERSION_COUNTER=1` opts into Path A (UE's canonical mechanism). See [versioning.md](versioning.md#cfbundleversion-auto-bump-by-default-opt-in-for-ue-canonical).

Full build log: `Saved/Logs/build_YYYY-MM-DD_HH-MM-SS.log`. Mac artifacts land in `BuildArtifacts/Mac/` by default (`--build-dir` overrides; relative or absolute paths accepted); iOS artifacts in `BuildArtifacts/IOS/`. `Build/{Platform}/` is reserved for committed source-controlled inputs (icons, launch storyboard, entitlements) — see [output.md](output.md#build-vs-saved--what-goes-where).
