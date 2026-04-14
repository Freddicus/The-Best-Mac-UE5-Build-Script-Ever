# Output and packaging

## Artifact paths

All build output goes under `Build/` (configurable via `BUILD_DIR_REL`). Filenames are derived from `SHORT_NAME` and `LONG_NAME` (both default to your project name).

| Artifact | Path |
|---|---|
| Xcode archive | `Build/${SHORT_NAME}.xcarchive` |
| Exported app | `Build/${SHORT_NAME}-export/*.app` |
| ZIP | `Build/${LONG_NAME}.zip` |
| DMG | `Build/${LONG_NAME}.dmg` |
| Build log | `Logs/build_YYYY-MM-DD_HH-MM-SS.log` |

The build log captures all stdout/stderr from UAT, `xcodebuild`, `codesign`, and `notarytool`. The terminal only shows human-readable status lines.

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
DMG_OUTPUT_DIR="Build"
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
