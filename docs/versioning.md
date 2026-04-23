# Versioning

The script has two separate versioning concepts that work independently or together:

- **`version.txt`** — a runtime-readable file bundled into your game's `Content/` by UAT
- **xcconfig stamping** — writes version and metadata keys into Xcode's build config so they flow into `Info.plist`

## version.txt

Set `VERSION_MODE` in `.env` or via `--version-mode` to enable.

### Modes

| Mode | Output example | Requires |
|---|---|---|
| `NONE` | *(disabled, default)* | — |
| `MANUAL` | `1.2.0` | `VERSION_STRING` |
| `HYBRID` | `1.2.0-a1b2c3d` | `VERSION_STRING` |
| `DATETIME` | `20260318-143022-a1b2c3d` | — |

`HYBRID` and `DATETIME` append the git short hash. Both fall back gracefully if the repo has no git history.

### Configuration

```bash
VERSION_MODE="HYBRID"
VERSION_STRING="1.2.0"
VERSION_CONTENT_DIR="BuildInfo"   # subdirectory under Content/ — default: BuildInfo
```

The file is written to `Content/<VERSION_CONTENT_DIR>/version.txt` before UAT runs, so it's bundled automatically.

### Version bumping

Use `--bump-major`, `--bump-minor`, or `--bump-patch` to auto-increment `VERSION_STRING` for the current run. Supports `X.Y.Z` and `vX.Y.Z` (prefix is preserved).

```bash
# .env has VERSION_STRING="1.2.3"
./ship.sh --bump-patch --version-mode HYBRID    # → 1.2.4-<hash>

# explicit base + bump
./ship.sh --version-string 2.0.0 --bump-minor  # → 2.1.0

# v-prefix preserved
./ship.sh --version-string v1.4.9 --bump-major # → v2.0.0
```

`--bump-*` implies `VERSION_MODE=MANUAL` if `VERSION_MODE` is still `NONE`.

On a **successful build**, the bumped value is written back to `.env` (`VERSION_STRING=` updated in-place, or appended if not present). `.env` is never modified on a failed or dry-run build.

### DefaultGame.ini

For UAT to bundle the directory, your project needs this in `Config/DefaultGame.ini`:

```ini
[/Script/UnrealEd.ProjectPackagingSettings]
+DirectoriesToAlwaysStageAsNonUFS=(Path="BuildInfo")
```

The script adds this automatically if it's missing when `VERSION_MODE != NONE`. If you use a custom `VERSION_CONTENT_DIR`, the entry uses your directory name.

### Editor cleanup

`version.txt` is reset to `dev` after every run — success, failure, or early exit — via an `EXIT` trap. The Unreal Editor never sees a build-stamped version string.

---

## xcconfig stamping

Before the Xcode archive step, the script updates the UE-generated xcconfig at:

```
Intermediate/ProjectFiles/XcconfigsMac/<project>.xcconfig
```

This file is written by `GenerateProjectFiles.sh`. Xcode reads it during archiving and injects the values into `Info.plist` automatically. Only the specific keys below are touched — everything else in the file is left alone.

> **Prerequisite:** the xcconfig must already exist. If it's missing (e.g. fresh clone before `GenerateProjectFiles` has run), the script skips this step with an informational message.

### Keys written

| xcconfig key | Info.plist key | Source |
|---|---|---|
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | Resolved version string (only when `VERSION_MODE != NONE`) |
| `MARKETING_VERSION` | `CFBundleShortVersionString` | `MARKETING_VERSION` config |
| `INFOPLIST_KEY_LSApplicationCategoryType` | `LSApplicationCategoryType` | `APP_CATEGORY` (existing value preserved if not set) |
| `INFOPLIST_KEY_LSSupportsGameMode` | `LSSupportsGameMode` | `ENABLE_GAME_MODE` |
| `INFOPLIST_KEY_GCSupportsGameMode` | `GCSupportsGameMode` | `ENABLE_GAME_MODE` |

### MARKETING_VERSION

The user-visible version string shown in Finder, the About dialog, and the App Store (`CFBundleShortVersionString`). Defaults to `1.0.0` with a warning if not set.

```bash
MARKETING_VERSION="1.2.0"
```

CLI: `--marketing-version 1.2.0`

### ENABLE_GAME_MODE

macOS Game Mode (Sonoma 14+) gives your app elevated CPU and GPU priority when a game controller is connected. Defaults to enabled (`YES`) with a warning if not explicitly set.

```bash
ENABLE_GAME_MODE="1"   # stamp YES (default)
ENABLE_GAME_MODE="0"   # stamp NO
```

CLI: `--game-mode` / `--no-game-mode`

The two Game Mode keys are always placed immediately after `INFOPLIST_KEY_LSApplicationCategoryType` in the xcconfig.

### APP_CATEGORY

Optional. If not set, the existing value in the xcconfig is preserved unchanged.

```bash
APP_CATEGORY="public.app-category.games"
```

CLI: `--app-category public.app-category.games`

Valid identifiers: https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype

---

## iOS xcconfig stamping

Before the iOS Xcode archive step, the script updates the UE-generated xcconfig at:

```
Intermediate/ProjectFiles/XcconfigsIOS/<project>.xcconfig
```

Only two keys are written — the macOS-specific keys (`LSSupportsGameMode`, `LSApplicationCategoryType`, etc.) are not applicable to iOS and are left alone.

| xcconfig key | Info.plist key | Source |
|---|---|---|
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | Resolved version string (only when `VERSION_MODE != NONE`) |
| `MARKETING_VERSION` | `CFBundleShortVersionString` | `IOS_MARKETING_VERSION` → `MARKETING_VERSION` → `1.0.0` |

### v-prefix stripping

App Store Connect requires `CFBundleVersion` to be composed of integers only — no `v` prefix. If your version string is `v1.2.3`, the script strips the `v` automatically and prints a warning at the terminal:

```
⚠ iOS CURRENT_PROJECT_VERSION: stripping 'v' prefix from 'v1.2.3' (CFBundleVersion must be numeric-only for App Store Connect)
```

The Mac xcconfig is not affected — `Developer ID` notarization does not impose this restriction.

### IOS_MARKETING_VERSION

Set a separate marketing version for iOS if it differs from Mac:

```bash
IOS_MARKETING_VERSION="2.0.0"
```

CLI: `--ios-marketing-version 2.0.0`

If not set, falls back to `MARKETING_VERSION`, then `1.0.0` with a warning.
