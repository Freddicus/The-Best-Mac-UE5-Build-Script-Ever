# Configuration reference

Configuration priority (highest to lowest): **CLI flags > `.env` > auto-detect > script defaults**.

The script auto-detects most things when run from your project root. In practice, you only need to set signing credentials and a notary profile. Everything else has a sensible default or can be found automatically.

## .env file

Copy `.env.example` to `.env` next to `ship.sh`. It's sourced as shell code — only use a `.env` you trust.

### Signing and notarization (required)

| Variable | Description |
|---|---|
| `DEVELOPMENT_TEAM` | Your 10-character Apple Team ID |
| `SIGN_IDENTITY` | Full `Developer ID Application: Name (TEAM)` string from Keychain |
| `NOTARY_PROFILE` | Keychain profile name created with `xcrun notarytool store-credentials` |
| `EXPORT_PLIST` | Path to `ExportOptions.plist`. Auto-detected or generated interactively if not set; must be set explicitly in CI. |
| `ENTITLEMENTS_FILE` | Path to a custom entitlements plist. Auto-generated if not set. |

### Project paths (usually optional)

The script locates your project automatically when run from the project root. Set these explicitly if the layout is non-standard.

| Variable | Description |
|---|---|
| `REPO_ROOT` | Absolute path to your project root. Defaults to the directory containing `ship.sh`. |
| `UPROJECT_PATH` | Absolute path to your `.uproject` file. Auto-detected if not set. |
| `UPROJECT_NAME` | Filename of the `.uproject`. Used for auto-detect if `UPROJECT_PATH` is not set. |
| `XCODE_WORKSPACE` | Workspace filename (e.g. `MyGame (Mac).xcworkspace`). See [workspace handling](#xcode-workspace) below. |
| `XCODE_SCHEME` | Xcode scheme name. See [scheme setup](#xcode-scheme) below. |

### Unreal Engine location

| Variable | Description |
|---|---|
| `UE_ROOT` | Path to your UE install (e.g. `/Users/Shared/Epic Games/UE_5.4`). Auto-detected from common EGL locations if not set. |
| `UAT_SCRIPTS_SUBPATH` | Relative path from `UE_ROOT` to the BatchFiles directory. Default: `Engine/Build/BatchFiles`. |
| `UE_EDITOR_SUBPATH` | Relative path from `UE_ROOT` to the UnrealEditor binary. Default: `Engine/Binaries/Mac/UnrealEditor.app/Contents/MacOS/UnrealEditor`. |

### Naming and output

| Variable | Description |
|---|---|
| `SHORT_NAME` | Short identifier used for archive and export folder names. Defaults to the project name. |
| `LONG_NAME` | Full name used for ZIP and DMG filenames. Defaults to `SHORT_NAME`. |
| `BUILD_DIR_REL` | Output directory relative to `REPO_ROOT`. Default: `Build`. |
| `LOG_DIR_REL` | Log directory relative to `REPO_ROOT`. Default: `Logs`. |

### Behavior

| Variable | Description |
|---|---|
| `BUILD_TYPE` | `shipping` or `development` (also accepts `s`/`d`). Prompted interactively if not set. |
| `NOTARIZE` | `yes` or `no`. Prompted interactively if not set. |
| `USE_XCODE_EXPORT` | `1` = use Xcode archive/export (default). `0` = skip Xcode steps. |
| `CLEAN_BUILD_DIR` | `1` = wipe `Build/` before building. Default: `0`. |
| `DRY_RUN` | `1` = print the plan and exit without building. |
| `PRINT_CONFIG` | `1` = print resolved configuration and exit without building. |

## CLI flags

Run `./ship.sh --help` for the full list. Common flags:

```bash
./ship.sh --dry-run
./ship.sh --print-config
./ship.sh --build-type shipping --notarize yes
./ship.sh --bump-patch --version-mode HYBRID
./ship.sh --marketing-version 1.2.0
./ship.sh --game-mode          # enable Game Mode in Info.plist
./ship.sh --no-game-mode       # disable Game Mode in Info.plist
./ship.sh --app-category public.app-category.games
```

CLI flags override `.env`. Both forms are equivalent — you can mix and match.

## Xcode workspace

The script does not require you to set up or maintain the Xcode workspace manually.

**Auto-detection behavior:**
- If exactly one `.xcworkspace` is found under `REPO_ROOT`, it's used automatically.
- If multiple workspaces are found, you're prompted to choose (interactive runs only).
- If no workspace is found, the script offers to run `GenerateProjectFiles.sh` to create one.
- In non-interactive contexts (CI), the script fails with a clear error if it can't resolve the workspace uniquely — set `XCODE_WORKSPACE` explicitly.

To generate or regenerate a workspace manually:

```bash
UE_ROOT="/Users/Shared/Epic Games/UE_5.x"
"$UE_ROOT/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh" \
  -project="/path/to/MyGame.uproject" \
  -game
```

## Xcode scheme

The scheme name is the glue between the Unreal-generated Xcode project and `xcodebuild`. The script attempts to auto-detect it, and prompts if multiple candidates exist. In CI, set `XCODE_SCHEME` explicitly.

Two requirements the script cannot fix for you:

1. **The scheme must exist** inside the `.xcworkspace`.
2. **The scheme must be marked Shared** in Xcode — otherwise `xcodebuild` can't see it.

To verify: open the workspace in Xcode → **Product → Scheme → Manage Schemes…** and confirm your scheme has **Shared** checked.

If `xcodebuild -list -workspace YourProject.xcworkspace` doesn't list your scheme, the script can't archive.

## ExportOptions.plist

`ExportOptions.plist` controls how Xcode signs and packages the exported `.app`. An annotated template is provided in `ExportOptions.plist.example` — copy it to your project root and edit as needed.

For interactive runs, the script tries to auto-detect an existing plist or offers to generate a minimal one. For CI, set `EXPORT_PLIST` explicitly.

## Minimal CI config

```bash
DEVELOPMENT_TEAM="ABCDE12345"
SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"
NOTARY_PROFILE="MyNotaryProfile"
EXPORT_PLIST="/path/to/ExportOptions.plist"
XCODE_SCHEME="MyGame"
BUILD_TYPE="shipping"
NOTARIZE="yes"
```
