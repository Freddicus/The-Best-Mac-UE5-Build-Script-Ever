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
| `BUILD_DIR_REL` | Output directory relative to `REPO_ROOT`. Default: `Saved/Packages/Mac`. UAT BuildCookRun's `-archivedirectory` is derived as the parent so UAT's `/<Platform>/` suffix lands inside this dir. See [output.md](output.md#build-vs-saved--what-goes-where) for the rationale. |
| `LOG_DIR_REL` | Log directory relative to `REPO_ROOT`. Default: `Saved/Logs`. |

### Behavior

| Variable | Description |
|---|---|
| `BUILD_TYPE` | `shipping` or `development` (also accepts `s`/`d`). Prompted interactively if not set. |
| `NOTARIZE` | `yes` or `no`. Prompted interactively if not set. |
| `USE_XCODE_EXPORT` | `1` = use Xcode archive/export (default). `0` = skip Xcode steps. |
| `REGEN_PROJECT_FILES` | `1` = run `GenerateProjectFiles.sh` once per ship invocation before the Xcode build (default). `0` = skip. Only meaningful when `USE_XCODE_EXPORT=1`. See the [workspace section](#xcode-workspace) for why this matters. |
| `SEED_APPLE_LAUNCHSCREEN_COMPAT` | `1` = copy the engine's pre-compiled `LaunchScreen.storyboardc` into `Build/Apple/Resources/Interface/` if absent (default). Prevents Mac builds from trying to compile a consumer-supplied iOS `.storyboard`. |
| `SEED_MAC_INFO_TEMPLATE_PLIST` | `1` = copy the engine's stock `Info.Template.plist` into `Build/Mac/Resources/` if absent (default). Canonical home for `LSSupportsGameMode`, `GCSupportsGameMode`, and any other static plist keys. UE's `BaseEngine.ini` already configures `TemplateMacPlist=` to point here, so any plist landing at this path is auto-discovered. |
| `USE_UE_PACKAGE_VERSION_COUNTER` | `0` (default, Path B) = the script auto-bumps `CFBUNDLE_VERSION` every build and rewrites the exported `.app`'s `Info.plist` post-export. `1` (Path A, opt-in) = the script seeds `Build/Mac/<Project>.PackageVersionCounter` and a project-level `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` override (sanctioned at `AppleToolChain.cs:394-397`) that strips Epic's engine Changelist; UE manages `CFBundleVersion` end-to-end and the script doesn't override the Info.plist. Mutually exclusive with the auto-bump. **Commit the seeded override script** if you opt in. |
| `MARKETING_VERSION` | If set, the script writes `VersionInfo=` to `Config/DefaultEngine.ini` under `[/Script/MacRuntimeSettings.MacRuntimeSettings]` (UE's canonical `CFBundleShortVersionString` source). Unset = leave `DefaultEngine.ini` alone. See [versioning.md](versioning.md#marketing_version). |
| `APP_CATEGORY` | If set, the script writes `AppCategory=` to `Config/DefaultEngine.ini` under `[/Script/MacTargetPlatform.XcodeProjectSettings]`. UE's `BaseEngine.ini` already defaults to `public.app-category.games` — only override when you need a different value. |
| `ENABLE_GAME_MODE` | `1` = set `LSSupportsGameMode` + `GCSupportsGameMode` to `true` in your `Build/Mac/Resources/Info.Template.plist`. `0` = set to `false`. Unset = leave the plist's GameMode keys alone (your plist is sovereign). |
| `CFBUNDLE_VERSION` | Source of truth for the auto-bumped integer build counter. The script reads this on every run, pre-increments by 1, ships the new value as `CFBundleVersion`, and persists the new value back to `.env` on a successful build. Empty/missing = `0`, so the first build ships `1`. Use `--set-cfbundle-version N` to set a new baseline (persists `N`; next build resumes from `N`). See [versioning.md](versioning.md#cfbundleversion-auto-bump-by-default-opt-in-for-ue-canonical) for the two paths. |
| `CLEAN_BUILD_DIR` | `1` = wipe `BUILD_DIR_REL` before building. Default: `0`. |
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
./ship.sh --build-dir Output/Mac           # override BUILD_DIR_REL
./ship.sh --no-regen-project-files         # skip the GenerateProjectFiles step
./ship.sh --no-seed-mac-info-template-plist          # opt out of Info.Template.plist seed
./ship.sh --use-ue-package-version-counter           # Path A: UE-canonical CFBundleVersion (opt-in)
./ship.sh --set-cfbundle-version 100                 # set new baseline; next build resumes from 100
```

CLI flags override `.env`. Both forms are equivalent — you can mix and match.

## Xcode workspace

The script does not require you to set up or maintain the Xcode workspace manually.

**Auto-detection behavior:**
- If exactly one `.xcworkspace` is found under `REPO_ROOT`, it's used automatically.
- If multiple workspaces are found, you're prompted to choose (interactive runs only).
- If no workspace is found, the script offers to run `GenerateProjectFiles.sh` to create one.
- In non-interactive contexts (CI), the script fails with a clear error if it can't resolve the workspace uniquely — set `XCODE_WORKSPACE` explicitly.

### Project files are regenerated every ship

By default the script runs `GenerateProjectFiles.sh` **before every Xcode build**, regardless of whether the workspace already exists. This is not just for first-time setup.

UBT bakes resolved absolute paths from `Build/{Platform}/Resources/` into `Intermediate/ProjectFilesMac/<Project> (Mac).xcodeproj/project.pbxproj` at *project-file-generation time*, not at xcodebuild time. The path priority list in `Engine/Source/Programs/UnrealBuildTool/ProjectFiles/Xcode/XcodeProject.cs::ProcessAssets` (modern Xcode mode) is walked once during regeneration; the resolved absolute paths are then frozen into the pbxproj.

Implications:
- **Adding a new file** under `Build/{Platform}/Resources/` (e.g. dropping in a `LaunchScreen.storyboard`) does **not** flow into the build until project files are regenerated — even though the file is on disk, the pbxproj's resource list still points where it pointed last time.
- **Editing the contents** of an already-referenced file *does* flow through (Xcode reads it at build time).
- Changes to `[/Script/MacTargetPlatform.XcodeProjectSettings] ExtraFolderToCopyToApp` and similar config-driven resource hooks also require a regen.

The regen runs early in the build pipeline, before `update_xcconfig_versions` (which stamps the freshly-generated xcconfig). It's cheap (~few seconds) and idempotent. Disable it with `REGEN_PROJECT_FILES=0` or `--no-regen-project-files` if you have a specific reason — the most common is if you need a `--no-xcode-export` UAT-only build, where the regen is also skipped automatically.

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

## iOS pipeline (opt-in)

Set `ENABLE_IOS=1` in `.env` (or pass `--ios`) to run the iOS pipeline after the Mac build. To skip Mac entirely and build only iOS, use `IOS_ONLY=1` / `--ios-only`. iOS doesn't need `SIGN_IDENTITY` (xcodebuild + automatic provisioning handles iOS App Store signing via `DEVELOPMENT_TEAM`).

| Variable | Description |
|---|---|
| `ENABLE_IOS` | `1` = run iOS after Mac. Default `0` (off). |
| `IOS_ONLY` | `1` = skip Mac entirely; only iOS. Implies `ENABLE_IOS=1`. Doesn't require `SIGN_IDENTITY`. |
| `IOS_WORKSPACE` | iOS workspace path (e.g. `MyGame (iOS).xcworkspace`). Auto-detected by convention if absent. |
| `IOS_SCHEME` | iOS Xcode scheme. Inferred from `XCODE_SCHEME` if set, else auto-detected from `xcodebuild -list`. |
| `IOS_EXPORT_PLIST` | Path to `iOS-ExportOptions.plist`. Auto-detected by name or by content scan. Copy `iOS-ExportOptions.plist.example` to start. |
| `IOS_ICON_SYNC` | `1` = stage `IOS_ICON_XCASSETS` into `Build/IOS/Resources/Assets.xcassets` (canonical UE path). Default `1`. |
| `IOS_ICON_XCASSETS` | Source iOS asset catalog. Default: `$REPO_ROOT/iOS-SourceControlled.xcassets`. |
| `IOS_APPICON_SET_NAME` | Override appiconset name (auto-detected if unset). |
| `IOS_MARKETING_VERSION` | iOS-only override for `CFBundleShortVersionString`. When unset, `MARKETING_VERSION` is shared across both platforms. See [versioning.md](versioning.md). |

### iOS App Store Connect upload (xcrun altool — NOT notarytool)

`xcrun altool` and `xcrun notarytool` are different tools for different services. **They are not interchangeable.**

| Tool | What it talks to | Used for | Credentials |
|---|---|---|---|
| `xcrun notarytool` | Apple notary service | macOS Developer ID notarization (Gatekeeper ticket) | Keychain profile (`xcrun notarytool store-credentials`) |
| `xcrun altool` | App Store Connect submission API | iOS IPA validation/upload (TestFlight, App Store) | API key (`.p8` file + key ID + issuer UUID) |

For iOS uploads, you provide an App Store Connect API key:

| Variable | Description |
|---|---|
| `IOS_ASC_VALIDATE` | `1` = run `xcrun altool --validate-app` on the IPA after export. |
| `IOS_ASC_UPLOAD` | `1` = run `xcrun altool --upload-app` (implies `IOS_ASC_VALIDATE=1`). |
| `IOS_ASC_API_KEY_ID` | 10-character ASC API key ID. Auto-detected from `Config/DefaultEngine.ini`'s `AppStoreConnectKeyID` if Xcode wrote it. |
| `IOS_ASC_API_ISSUER` | ASC API issuer UUID. Auto-detected from `AppStoreConnectIssuerID`. |
| `IOS_ASC_API_KEY_PATH` | Path to the `.p8` file you downloaded from ASC. Auto-detected from `AppStoreConnectKeyPath`. |

To create an API key: appstoreconnect.apple.com → **Users and Access → Integrations → App Store Connect API → Generate API Key**. Download the `.p8`, store it somewhere your build machine can read, and set the three values above (or let Xcode store them in `DefaultEngine.ini` and the script will pick them up).

## Minimal CI config

For Mac-only:

```bash
DEVELOPMENT_TEAM="ABCDE12345"
SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"
NOTARY_PROFILE="MyNotaryProfile"
EXPORT_PLIST="/path/to/ExportOptions.plist"
XCODE_SCHEME="MyGame"
BUILD_TYPE="shipping"
NOTARIZE="yes"
```

For iOS-only (App Store Connect upload):

```bash
DEVELOPMENT_TEAM="ABCDE12345"
ENABLE_IOS="1"
IOS_ONLY="1"
IOS_EXPORT_PLIST="/path/to/iOS-ExportOptions.plist"
IOS_SCHEME="MyGame"
IOS_ASC_UPLOAD="1"
IOS_ASC_API_KEY_ID="ABCD123456"
IOS_ASC_API_ISSUER="00000000-0000-0000-0000-000000000000"
IOS_ASC_API_KEY_PATH="/path/to/AuthKey_ABCD123456.p8"
BUILD_TYPE="shipping"
```
