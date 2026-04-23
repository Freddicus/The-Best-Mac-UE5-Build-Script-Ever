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

## iOS pipeline

The iOS pipeline is opt-in. Enable it with `ENABLE_IOS=1` or `--ios`. It runs after the Mac pipeline and produces an IPA.

**Prerequisite:** iOS support must be enabled in the Epic Games Launcher before running `GenerateProjectFiles.sh`. This generates both `<Project> (Mac).xcworkspace` and `<Project> (iOS).xcworkspace` in a single pass.

### iOS variables

| Variable | Default | Description |
|---|---|---|
| `ENABLE_IOS` | `0` | Set to `1` to enable the iOS pipeline |
| `IOS_ONLY` | `0` | Set to `1` to skip the entire Mac pipeline and run only iOS steps |
| `IOS_WORKSPACE` | auto-detected | Path to `<Project> (iOS).xcworkspace` |
| `IOS_SCHEME` | auto-detected | Xcode scheme name (inferred from Mac scheme, then `xcodebuild -list`) |
| `IOS_EXPORT_PLIST` | auto-detected | Path to your iOS `ExportOptions.plist` |
| `IOS_ICON_SYNC` | `1` | Copy source-controlled icon assets into the workspace before archiving |
| `IOS_ICON_XCASSETS` | `iOS-SourceControlled.xcassets` | Source `.xcassets` catalog for iOS icons |
| `IOS_APPICON_SET_NAME` | auto-detected | `*.appiconset` name inside the catalog |
| `IOS_MARKETING_VERSION` | falls back to `MARKETING_VERSION` | `CFBundleShortVersionString` stamped into iOS xcconfig |
| `IOS_ASC_VALIDATE` | `0` | Validate IPA with App Store Connect after export |
| `IOS_ASC_UPLOAD` | `0` | Upload IPA to App Store Connect (implies validate) |
| `IOS_ASC_API_KEY_ID` | auto-detected from `DefaultEngine.ini` | App Store Connect API key ID (10-char) |
| `IOS_ASC_API_ISSUER` | auto-detected from `DefaultEngine.ini` | App Store Connect API issuer UUID |
| `IOS_ASC_API_KEY_PATH` | auto-detected from `DefaultEngine.ini` | Path to the `.p8` API key file |

### iOS workspace and scheme

Auto-detection follows the same logic as the Mac path:
- Workspace: looks for `<ProjectName> (iOS).xcworkspace` first, then scans for any `*iOS*.xcworkspace`.
- Scheme: inferred from the Mac scheme if already resolved; otherwise detected via `xcodebuild -list` and matched by name.

Set `IOS_WORKSPACE` and `IOS_SCHEME` explicitly in CI.

### iOS ExportOptions.plist

The iOS plist uses different method values than the Mac one. An annotated template is provided in `iOS-ExportOptions.plist.example`. Common methods:

| Method | Use |
|---|---|
| `app-store-connect` | Submit to App Store / TestFlight |
| `release-testing` | Ad hoc distribution (registered devices, no App Review) |

For interactive runs, the script auto-detects an existing iOS plist or offers to generate one. For CI, set `IOS_EXPORT_PLIST` explicitly.

### App Store Connect upload

`--ios-upload-ipa` automates Xcode's "Distribute App → App Store Connect" flow via `xcrun altool`. The API credentials are auto-detected from `Config/DefaultEngine.ini` if you've already configured them in Xcode's Signing & Capabilities panel (keys: `AppStoreConnectKeyID`, `AppStoreConnectIssuerID`, `AppStoreConnectKeyPath`). Generate an API key at App Store Connect → Users and Access → Integrations → App Store Connect API.

After upload, use App Store Connect to designate the build as internal TestFlight, external TestFlight, or submit for App Review — the upload method is the same in all cases.

### iOS-only builds

```bash
./ship.sh --ios-only
```

Skips everything Mac-specific (UAT Mac cook, Xcode Mac archive/export, codesign, ZIP, DMG, notarization) and runs only the iOS UAT → archive → export → optional validate/upload sequence. `SIGN_IDENTITY` is not required.

### Minimal iOS CI config

```bash
DEVELOPMENT_TEAM="ABCDE12345"
ENABLE_IOS="1"
IOS_WORKSPACE="MyGame (iOS).xcworkspace"
IOS_SCHEME="MyGame"
IOS_EXPORT_PLIST="iOS-ExportOptions.plist"
IOS_MARKETING_VERSION="1.2.0"
IOS_ASC_UPLOAD="1"
IOS_ASC_API_KEY_ID="ABCDE12345"
IOS_ASC_API_ISSUER="12345678-abcd-1234-abcd-123456789abc"
IOS_ASC_API_KEY_PATH="/path/to/AuthKey_ABCDE12345.p8"
```

---

## Minimal CI config (Mac)

```bash
DEVELOPMENT_TEAM="ABCDE12345"
SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"
NOTARY_PROFILE="MyNotaryProfile"
EXPORT_PLIST="/path/to/ExportOptions.plist"
XCODE_SCHEME="MyGame"
BUILD_TYPE="shipping"
NOTARIZE="yes"
```
