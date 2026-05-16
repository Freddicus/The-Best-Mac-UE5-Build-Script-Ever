# Output and packaging

## `Build/` vs `Saved/` — what goes where

This is the most common source of confusion when wiring up an Unreal project for distribution. Despite the name, `Build/{Platform}/` is **not** for build output.

- **`Build/{Platform}/` is for committed source-controlled *inputs*.** App icons, custom launch storyboards, `Info.plist` fragments, entitlements, signing config, `PakBlacklist*.txt`. The folder name is a UE3-era misnomer; treat it as "platform-source-inputs/". UBT does write a small set of intermediates here (`UBTGenerated/`, `FileOpenOrder/`, `*.PackageVersionCounter`); those are managed by the engine and stay gitignored.
- **`Saved/` is for derived artifacts** — UE's documented dumping ground. It is gitignored by default. This script writes logs to `Saved/Logs/`; all other build outputs (packaged `.app`, `.xcarchive`, `.zip`, `.dmg`) land in `BuildArtifacts/` by default — outside `Saved/` so concurrent UAT runs for other platforms writing to `Saved/Packages/` don't collide. The artifact root is fully configurable via `BUILD_DIR_REL` / `--build-dir`.

`ship.sh` writes a few specific files under `Build/` — all of them at their *canonical* UE locations, so UE's regular machinery picks them up at `GenerateProjectFiles` / `xcodebuild` time. The first two are seeded by default; the last two are seeded only when you opt into Path A for `CFBundleVersion`:

| Path | Default? | Why the script seeds it | Commit it? | Disable with |
|---|---|---|---|---|
| `Build/Apple/Resources/Interface/LaunchScreen.storyboardc` | yes | Stops Mac from trying to compile a consumer-supplied iOS `.storyboard` source. See [gotchas](gotchas.md#adding-a-custom-ios-launchscreenstoryboard-breaks-the-mac-build). | yes | `--no-seed-apple-launchscreen-compat` |
| `Build/Mac/Resources/Info.Template.plist` | yes | Canonical home for static `Info.plist` keys like `LSSupportsGameMode`. UE's `BaseEngine.ini` already configures `TemplateMacPlist=` to point here. | yes | `--no-seed-mac-info-template-plist` |
| `Build/IOS/Resources/<Project>.entitlements` | only when `ENABLE_GAME_CENTER=1` and `IOS_DISTRIBUTION=app-store` | Holds `com.apple.developer.game-center`; ship.sh passes its path as `CODE_SIGN_ENTITLEMENTS=<path>` to the iOS `xcodebuild archive`. UBT's `Intermediate/IOS/<Target>.entitlements` is silently ignored under automatic signing, so the committed file is the reliable path. | yes | disable `ENABLE_GAME_CENTER` |
| `Build/Mac/Resources/<Project>.entitlements` | always when `MAC_DISTRIBUTION=app-store`; with Game Center keys when `ENABLE_GAME_CENTER=1` | Canonical entitlements file for MAS. Always enforces `com.apple.security.app-sandbox=true` (App Store rejects uploads without it, and overriding `CODE_SIGN_ENTITLEMENTS` shadows UE's `ShippingSpecificMacEntitlements` path where sandbox normally lives). With Game Center enabled also holds `com.apple.developer.game-center=true` and `com.apple.security.network.client=true` (Game Center cannot reach Apple's servers from inside the sandbox without it). Pre-existing custom keys in the file are preserved (PlistBuddy `Add`/`Set` is per-key). | yes | not applicable — sandbox is mandatory for MAS |
| `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` | only when `USE_UE_PACKAGE_VERSION_COUNTER=1` | Strips the engine's `Build.version` Changelist from `CFBundleVersion`. Sanctioned override at `AppleToolChain.cs:394-397`. See [versioning.md](versioning.md#path-a--ue-canonical-opt-in-advanced). | yes | `--no-use-ue-package-version-counter` (turns off Path A entirely) |
| `Build/Mac/<Project>.PackageVersionCounter` | only when `USE_UE_PACKAGE_VERSION_COUNTER=1` | UE's canonical `CFBundleVersion` source. UE rewrites this every build. **Gitignored per UE convention** (`Build/{Platform}/*.PackageVersionCounter` is in the "UBT writes here itself" category alongside `UBTGenerated/` and `FileOpenOrder/`). | no | `--no-use-ue-package-version-counter` |

All are seeded only when missing — once present, the script never overwrites them. By default (`USE_UE_PACKAGE_VERSION_COUNTER=0`), `CFBundleVersion` is auto-bumped via `CFBUNDLE_VERSION` in `.env` and the post-export `PlistBuddy` rewrite — no Path A files needed. See [versioning.md](versioning.md#cfbundleversion-auto-bump-by-default-opt-in-for-ue-canonical) for the full story.

## Artifact paths

Mac build outputs land in `BuildArtifacts/Mac/` by default (configurable via `BUILD_DIR_REL` / `--build-dir`); iOS outputs land alongside in `BuildArtifacts/IOS/`. Logs go to `Saved/Logs/`. Filenames are derived from `SHORT_NAME` and `LONG_NAME` (both default to your project name).

**Mac — `MAC_DISTRIBUTION=developer-id`** *(default)*:

| Artifact | Path |
|---|---|
| UAT-packaged app (BuildCookRun `-archive`) | `BuildArtifacts/Mac/${LONG_NAME}-Mac-Shipping.app` |
| Xcode archive | `BuildArtifacts/Mac/${SHORT_NAME}.xcarchive` |
| Exported app | `BuildArtifacts/Mac/${SHORT_NAME}-export/*.app` |
| ZIP | `BuildArtifacts/Mac/${LONG_NAME}.zip` |
| DMG | `BuildArtifacts/Mac/${LONG_NAME}.dmg` |

**Mac — `MAC_DISTRIBUTION=app-store`** *(no ZIP, no DMG, no notarize — App Store review is the equivalent gate)*:

| Artifact | Path |
|---|---|
| UAT-packaged app | `BuildArtifacts/Mac/${LONG_NAME}-Mac-Shipping.app` |
| Xcode archive | `BuildArtifacts/Mac/${SHORT_NAME}-mas.xcarchive` |
| Exported installer | `BuildArtifacts/Mac/${SHORT_NAME}-mas-export/*.pkg` |

The `.pkg` (not a `.app`) is what `xcodebuild -exportArchive` produces with `method=app-store-connect` on macOS — it's the productbuild output that `xcrun altool --upload-app -t macos` expects. `pkgutil --check-signature` is the right verification command, **not** `codesign --verify` (that only applies to unwrapped `.app` bundles). The `-mas` suffix on archive / export paths means MAS and Developer ID runs don't clobber each other when alternated for testing.

**iOS** *(only when `IOS_DISTRIBUTION=app-store`, e.g. `--ios` or `--ios-only`)*:

| Artifact | Path |
|---|---|
| UAT-packaged app | `BuildArtifacts/IOS/${LONG_NAME}-IOS-Shipping.app` |
| Xcode archive | `BuildArtifacts/IOS/${SHORT_NAME}-iOS.xcarchive` |
| IPA | `BuildArtifacts/IOS/${SHORT_NAME}-iOS-export/*.ipa` |

**Logs:** `Saved/Logs/build_YYYY-MM-DD_HH-MM-SS.log`

The build log captures all stdout/stderr from UAT, `xcodebuild`, `codesign`, `notarytool`, and `altool`. The terminal only shows human-readable status lines.

### How `BUILD_DIR_REL` and `UAT_ARCHIVE_DIR` relate

UAT BuildCookRun's `-archivedirectory=<path>` is appended with `/<TargetPlatform>/` by UAT itself. The script computes its UAT archive directory as `dirname BUILD_DIR`, so UAT's automatic `/Mac/` suffix lands inside `BUILD_DIR` alongside the script-side artifacts. With the default `BUILD_DIR_REL=BuildArtifacts/Mac`, that puts UAT's `-archive` output at `BuildArtifacts/Mac/<App>-Mac-Shipping.app/`.

If you override `BUILD_DIR_REL` to a path that doesn't end with `/Mac`, UAT will still append `/Mac` and the script's app-discovery (`find_first_app_under "$BUILD_DIR"`) won't find it. Keep the trailing `/Mac` segment, or override only the parent (e.g. `BUILD_DIR_REL=Output/Mac`).

The standard UE-side flag map:

| UAT flag | Default | What it controls |
|---|---|---|
| `-stagingdirectory=<path>` | `Saved/StagedBuilds` | Pre-package staging layout (`Saved/StagedBuilds/<Platform>/`). Not overridden by this script. |
| `-archivedirectory=<path>` | (unset) | Final output dir for `-archive`. UAT appends `/<Platform>/`. |

## ZIP

A ZIP is created automatically when `NOTARIZE=yes` (required as the submission artifact). To create a ZIP without notarizing:

```bash
ENABLE_ZIP="1"
```

## DMG

Disabled by default.

```bash
ENABLE_DMG="1"
```

Optional overrides:

```bash
DMG_NAME="MyGame.dmg"
DMG_VOLUME_NAME="MyGame"
DMG_OUTPUT_DIR="BuildArtifacts/Mac"   # default: same as BUILD_DIR_REL
```

When `NOTARIZE=yes`, the DMG is also notarized and stapled.

### FANCY_DMG

`FANCY_DMG=1` enables a drag-to-install Finder layout (app icon + Applications folder symlink, custom window size and icon positions). It's experimental — Finder layout persistence can be inconsistent across machines and Finder states.

Additional requirements for `FANCY_DMG=1`:
- A GUI session (won't work headless)
- Finder Automation permission for your terminal app

Keep `FANCY_DMG=0` (the default) for CI or when you just need a working DMG.

## App icons

UE auto-discovers asset catalogs at `$(Project)/Build/<Platform>/Resources/Assets.xcassets/` at `GenerateProjectFiles` time (verified at `XcodeProject.cs:1731-1742` via `UnrealData.ProjectOrEnginePath()`). Maintain your `.xcassets` directly there:

```
Build/Mac/Resources/Assets.xcassets/
  Contents.json
  AppIcon.appiconset/        ← required name (UE's xcconfig hardcodes ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon)
    Contents.json
    icon_*.png

Build/IOS/Resources/Assets.xcassets/
  Contents.json
  AppIcon.appiconset/
    ...
```

Commit those directories. UE picks them up; `actool` uses them at build time.

### Non-AppIcon-named appiconsets

If your appiconset is named something other than `AppIcon` (e.g. `MyAppIcon.appiconset`), UE's xcconfig still tells `actool` to look for `AppIcon`. The script defensively mirrors a non-`AppIcon` set to `AppIcon.appiconset` alongside the original, so `actool` finds it where it expects:

```bash
MACOS_APPICON_SET_NAME="MyAppIcon"   # explicit; otherwise auto-detects the first appiconset
IOS_APPICON_SET_NAME="MyAppIcon"
```

CLI: `--macos-appicon-set-name NAME`, `--ios-appicon-set-name NAME`.

The mirror is idempotent (no-op when `AppIcon.appiconset` already exists). When the catalog has no usable appiconset, UE falls back to the engine's default icon at build time.

### Engine fallback

If `Build/Mac/Resources/Assets.xcassets/` doesn't exist in your project, UE falls back to `Engine/Build/Mac/Resources/Assets.xcassets/` (and analogously for iOS) — the stock engine icon. To use your own, create the project-level catalog and add an `AppIcon.appiconset` to it.
