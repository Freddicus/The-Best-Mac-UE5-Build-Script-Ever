# Output and packaging

## `Build/` vs `Saved/` — what goes where

This is the most common source of confusion when wiring up an Unreal project for distribution. Despite the name, `Build/{Platform}/` is **not** for build output.

- **`Build/{Platform}/` is for committed source-controlled *inputs*.** App icons, custom launch storyboards, `Info.plist` fragments, entitlements, signing config, `PakBlacklist*.txt`. The folder name is a UE3-era misnomer; treat it as "platform-source-inputs/". UBT does write a small set of intermediates here (`UBTGenerated/`, `FileOpenOrder/`, `*.PackageVersionCounter`); those are managed by the engine and stay gitignored.
- **`Saved/` is for derived artifacts** — UE's documented dumping ground. It is gitignored by default and is where this script writes everything: cooked content, staged builds, packaged `.app`/`.zip`/`.dmg`, and logs.

`ship.sh` will not touch `Build/{Platform}/`. If you want a custom launch screen or app icon override, put it in `Build/Mac/Resources/` (or `Build/IOS/Resources/`) and commit it — it stays under your control.

## Artifact paths

All build output goes under `Saved/` (configurable via `BUILD_DIR_REL` / `--build-dir`). Filenames are derived from `SHORT_NAME` and `LONG_NAME` (both default to your project name).

| Artifact | Path |
|---|---|
| UAT-packaged app (BuildCookRun `-archive`) | `Saved/Packages/Mac/${LONG_NAME}-Mac-Shipping.app` |
| Xcode archive | `Saved/Packages/Mac/${SHORT_NAME}.xcarchive` |
| Exported app | `Saved/Packages/Mac/${SHORT_NAME}-export/*.app` |
| ZIP | `Saved/Packages/Mac/${LONG_NAME}.zip` |
| DMG | `Saved/Packages/Mac/${LONG_NAME}.dmg` |
| Build log | `Saved/Logs/build_YYYY-MM-DD_HH-MM-SS.log` |

The build log captures all stdout/stderr from UAT, `xcodebuild`, `codesign`, and `notarytool`. The terminal only shows human-readable status lines.

### How `BUILD_DIR_REL` and `UAT_ARCHIVE_DIR` relate

UAT BuildCookRun's `-archivedirectory=<path>` is appended with `/<TargetPlatform>/` by UAT itself. The script computes its UAT archive directory as `dirname BUILD_DIR`, so UAT's automatic `/Mac/` suffix lands inside `BUILD_DIR` alongside the script-side artifacts. With the default `BUILD_DIR_REL=Saved/Packages/Mac`, that puts UAT's `-archive` output at `Saved/Packages/Mac/<App>-Mac-Shipping.app/`.

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
DMG_OUTPUT_DIR="Saved/Packages/Mac"   # default: same as BUILD_DIR_REL
```

When `NOTARIZE=yes`, the DMG is also notarized and stapled.

### FANCY_DMG

`FANCY_DMG=1` enables a drag-to-install Finder layout (app icon + Applications folder symlink, custom window size and icon positions). It's experimental — Finder layout persistence can be inconsistent across machines and Finder states.

Additional requirements for `FANCY_DMG=1`:
- A GUI session (won't work headless)
- Finder Automation permission for your terminal app

Keep `FANCY_DMG=0` (the default) for CI or when you just need a working DMG.

## App icon seeding

By default, the `.app` uses whichever icon is baked into the engine-global `Assets.xcassets` — which means a UAT build silently shows the Unreal default icon unless you've changed it engine-side.

Icon seeding solves this by copying a source-controlled `.xcassets` catalog into `Intermediate/SourceControlled/Assets.xcassets` and patching every `project.pbxproj` in the workspace to reference it before archiving. Your icon ships without any engine-side changes.

**Enabled by default.** Expected location: `$REPO_ROOT/macOS-SourceControlled.xcassets`. If the path doesn't exist and wasn't set explicitly, the script warns and continues without seeding.

```bash
MACOS_ICON_SYNC="0"   # disable entirely
```

```bash
MACOS_ICON_XCASSETS="macOS-SourceControlled.xcassets"   # relative to REPO_ROOT or absolute
```

If your catalog uses a non-standard `*.appiconset` name (not `AppIcon`), the script auto-detects it. Override explicitly if needed:

```bash
MACOS_APPICON_SET_NAME="MyCustomIcon"
```
