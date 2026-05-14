# Configuration reference

Configuration priority (highest to lowest): **CLI flags > `.env` > auto-detect > script defaults**.

The script auto-detects most things when run from your project root. In practice, you only need to set signing credentials and a notary profile. Everything else has a sensible default or can be found automatically.

## Distribution channels

Two variables decide which pipeline runs for each platform. Every downstream decision (entitlements, signing cert, ExportOptions method, upload tooling) keys off them.

| Variable | Values | Default | Meaning |
|---|---|---|---|
| `MAC_DISTRIBUTION` | `developer-id`, `app-store`, `off` | `developer-id` | macOS channel |
| `IOS_DISTRIBUTION` | `off`, `app-store` | `off` | iOS channel |

### MAC_DISTRIBUTION

- **`developer-id`** *(default)* — Direct Distribution. Developer ID Application signing, hardened runtime, notarized + stapled. Steam allowed here (and only here). **Game Center is not available** — AMFI rejects `com.apple.developer.game-center` on Developer-ID-signed Mac apps at exec, regardless of notarization. See [gotchas.md](gotchas.md#game-center-on-mac-requires-mac_distributionapp-store).
- **`app-store`** — Mac App Store. Apple Distribution / 3rd Party Mac Developer Application signing under automatic provisioning, App Sandbox required (enforced by ship.sh; see [the Fixed entry for 2026-05-12](../CHANGELOG.md#2026-05-12--mac-app-store-pipeline-mac_distributionapp-store-pr-29)), Game Center allowed, Steam forbidden. Pipeline: UAT `BuildCookRun -targetplatform=Mac` → `xcodebuild archive -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic` → `xcodebuild -exportArchive` with a MAS export plist → optional `xcrun altool -t macos` validate/upload of the resulting `.pkg`. No ZIP, no DMG, no notarize+staple — App Store review is the equivalent gate.
- **`off`** — Skip Mac entirely (iOS-only run). Equivalent to the legacy `IOS_ONLY=1`. Does not require `SIGN_IDENTITY`.

### IOS_DISTRIBUTION

- **`off`** *(default)* — Skip iOS.
- **`app-store`** — Run the iOS pipeline (UAT → archive → IPA → optional ASC validate/upload). iOS has no other distribution channel in the US, so this is the only non-off value. Equivalent to the legacy `ENABLE_IOS=1`.

### Legacy flag mapping

The legacy `ENABLE_IOS` and `IOS_ONLY` variables (and the `--ios`, `--no-ios`, `--ios-only` CLI flags) remain fully supported and resolve into the dispatcher automatically:

| Legacy | Resolves to |
|---|---|
| `ENABLE_IOS=1` | `IOS_DISTRIBUTION=app-store` |
| `IOS_ONLY=1` | `MAC_DISTRIBUTION=off` + `IOS_DISTRIBUTION=app-store` |

Explicit CLI dispatcher flags (`--mac-distribution`, `--ios-distribution`) override the legacy flags when both are present.

### Compatibility matrix

The script enforces these rules up-front and fails with a clear message if violated:

| Combination | Rule | Why |
|---|---|---|
| `MAC_DISTRIBUTION=off` + `IOS_DISTRIBUTION=off` | rejected | Nothing to build. |
| `MAC_DISTRIBUTION=app-store` + `ENABLE_STEAM=1` | rejected | Mac App Store review forbids `com.apple.security.cs.disable-library-validation` and `com.apple.security.cs.allow-dyld-environment-variables` outright. |
| `MAC_DISTRIBUTION=developer-id` + `ENABLE_GAME_CENTER=1` for Mac (no iOS) | rejected | AMFI rejects `com.apple.developer.game-center` on Developer-ID-signed Mac apps at exec. Game Center on Mac structurally requires Mac App Store distribution. |
| `MAC_DISTRIBUTION=app-store` + `ENABLE_GAME_CENTER=1` | **supported** | MAS provisioning profile encodes the entitlement; AMFI accepts it. Entitlements file also gets `com.apple.security.network.client=true` so Game Center can reach Apple's servers from inside the sandbox. |
| `MAC_DISTRIBUTION=app-store` | **supported** (since 2026-05-12) | Full pipeline: archive → exportArchive → optional altool. Requires `MAS_EXPORT_PLIST` (auto-detected as `MAS-ExportOptions.plist`). |

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
| `ENABLE_GAME_CENTER` | **iOS App Store + Mac App Store.** `1` = seed `Build/IOS/Resources/<Project>.entitlements` and/or `Build/Mac/Resources/<Project>.entitlements` (whichever channel is active) with `com.apple.developer.game-center`, write `bEnableGameCenterSupport=True` to `DefaultEngine.ini` under both `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]` and `[/Script/MacRuntimeSettings.MacRuntimeSettings]`, and pass `CODE_SIGN_ENTITLEMENTS=<path>` to each `xcodebuild archive`. On Mac App Store the entitlements file ALSO gets `com.apple.security.network.client=true` (Game Center cannot reach Apple's servers from inside the sandbox without it). `0` = remove the key and write `False`. The remove path also runs under `MAC_DISTRIBUTION=developer-id` so that switching a project back from a prior MAS build cleans up `Build/Mac/Resources/<Project>.entitlements` — UE points `ShippingSpecificMacEntitlements` at the same file, and a stray `com.apple.developer.game-center=true` makes `xcodebuild -exportArchive` fail with "No profiles for '<bundle id>' were found" because Developer ID provisioning profiles cannot carry that entitlement. Unset = no-op. **Commit the seeded `.entitlements` file(s)** so they survive project regeneration. The bundle ID must have Game Center enabled in App Store Connect. Setting `=1` is blocked under `MAC_DISTRIBUTION=developer-id` with no iOS pass — Game Center is structurally a Mac-App-Store / iOS feature; AMFI rejects it on Developer-ID-signed Mac apps. See [gotchas](gotchas.md#game-center-on-mac-requires-mac_distributionapp-store). |
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
./ship.sh --game-center        # add Game Center entitlement (Mac + iOS)
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
- Workspace detection runs **after** `GenerateProjectFiles.sh`, so a first-time run always has a workspace to detect.
- If exactly one `.xcworkspace` is found under `REPO_ROOT`, it's used automatically.
- If multiple workspaces are found, you're prompted to choose (interactive runs only).
- If no workspace is found after generation, the script fails with a clear error — set `XCODE_WORKSPACE` explicitly or check that `UPROJECT_PATH` is valid.
- In CI, set `XCODE_WORKSPACE` explicitly.

### Project files are regenerated every ship

By default the script runs `GenerateProjectFiles.sh` **before every Xcode build**, regardless of whether the workspace already exists. On a first-time run this creates the workspace; on subsequent runs it keeps the pbxproj in sync with your `Build/{Platform}/Resources/` inputs.

UBT bakes resolved absolute paths from `Build/{Platform}/Resources/` into `Intermediate/ProjectFilesMac/<Project> (Mac).xcodeproj/project.pbxproj` at *project-file-generation time*, not at xcodebuild time. The path priority list in `Engine/Source/Programs/UnrealBuildTool/ProjectFiles/Xcode/XcodeProject.cs::ProcessAssets` (modern Xcode mode) is walked once during regeneration; the resolved absolute paths are then frozen into the pbxproj.

Implications:
- **Adding a new file** under `Build/{Platform}/Resources/` (e.g. dropping in a `LaunchScreen.storyboard`) does **not** flow into the build until project files are regenerated — even though the file is on disk, the pbxproj's resource list still points where it pointed last time.
- **Editing the contents** of an already-referenced file *does* flow through (Xcode reads it at build time).
- Changes to `[/Script/MacTargetPlatform.XcodeProjectSettings] ExtraFolderToCopyToApp` and similar config-driven resource hooks also require a regen.

The regen runs before workspace detection and the Xcode archive step. It's cheap (~few seconds) and idempotent. Disable it with `REGEN_PROJECT_FILES=0` or `--no-regen-project-files` if you have a specific reason — the most common is a `--no-xcode-export` UAT-only build, where regen is also skipped automatically. If `REGEN_PROJECT_FILES=0` and no workspace is found, the script fails with a clear message.

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
| `IOS_APPICON_SET_NAME` | Name of the `*.appiconset` inside `Build/IOS/Resources/Assets.xcassets/` to mirror to `AppIcon.appiconset` (UE's xcconfig hardcodes the name to `AppIcon`). Auto-detects the first appiconset in the catalog if unset. |
| `IOS_MARKETING_VERSION` | iOS-only override for `CFBundleShortVersionString`. When unset, `MARKETING_VERSION` is shared across both platforms. See [versioning.md](versioning.md). |

### Mac App Store config (`MAC_DISTRIBUTION=app-store`)

| Variable | Description |
|---|---|
| `MAS_EXPORT_PLIST` | Path to `MAS-ExportOptions.plist`. Auto-detected by conventional name in the repo root. Must declare `method=app-store-connect`, `signingStyle=automatic`, and a `teamID` matching `DEVELOPMENT_TEAM` — validated up-front so a mismatch fails immediately instead of after a multi-hour build. Copy `MAS-ExportOptions.plist.example` to start. |
| `MAS_ASC_VALIDATE` | `1` = run `xcrun altool --validate-app -t macos` on the exported `.pkg` after archive. |
| `MAS_ASC_UPLOAD` | `1` = run `xcrun altool --upload-app -t macos` (implies validate). |

Apple Distribution / 3rd Party Mac Developer Application identity must be present in the keychain (preferred / legacy fallback respectively); the script fails fast with the available identities listed if neither is found. `SIGN_IDENTITY` is **not** consulted on this channel — automatic provisioning resolves the cert.

### App Store Connect upload (xcrun altool — NOT notarytool)

`xcrun altool` and `xcrun notarytool` are different tools for different services. **They are not interchangeable.**

| Tool | What it talks to | Used for | Credentials |
|---|---|---|---|
| `xcrun notarytool` | Apple notary service | macOS Developer ID notarization (Gatekeeper ticket) | Keychain profile (`xcrun notarytool store-credentials`) |
| `xcrun altool` | App Store Connect submission API | iOS IPA + Mac App Store `.pkg` validation/upload (TestFlight, App Store) | API key (`.p8` file + key ID + issuer UUID) |

One Apple Developer account has one ASC API key — the canonical variables below are platform-neutral and used by both the iOS IPA pipeline and the Mac App Store `.pkg` pipeline:

| Variable | Description |
|---|---|
| `ASC_API_KEY_ID` | 10-character ASC API key ID. Auto-detected from `Config/DefaultEngine.ini`'s `AppStoreConnectKeyID` if Xcode wrote it. |
| `ASC_API_ISSUER` | ASC API issuer UUID. Auto-detected from `AppStoreConnectIssuerID`. |
| `ASC_API_KEY_PATH` | Path to the `.p8` file you downloaded from ASC. Auto-detected from `AppStoreConnectKeyPath`. |

The legacy `IOS_ASC_API_KEY_ID` / `IOS_ASC_API_ISSUER` / `IOS_ASC_API_KEY_PATH` env vars + `--ios-asc-api-*` flags continue to work and resolve into the canonical names automatically.

#### Interactive upload-after-validate prompt

When `--ios-validate-ipa` or `--mas-validate-app` is set but the matching upload flag is not, and stdin is a TTY, ship.sh prompts `Upload this .ipa/.pkg to App Store Connect now? (y/N)` after validation succeeds. Flag-driven runs are unchanged (upload flag wins, no prompt); CI / non-TTY runs are unchanged (no prompt, upload only when the flag was passed).

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
IOS_DISTRIBUTION="app-store"
MAC_DISTRIBUTION="off"
IOS_EXPORT_PLIST="/path/to/iOS-ExportOptions.plist"
IOS_SCHEME="MyGame"
IOS_ASC_UPLOAD="1"
ASC_API_KEY_ID="ABCD123456"
ASC_API_ISSUER="00000000-0000-0000-0000-000000000000"
ASC_API_KEY_PATH="/path/to/AuthKey_ABCD123456.p8"
BUILD_TYPE="shipping"
```

For Mac App Store-only:

```bash
DEVELOPMENT_TEAM="ABCDE12345"
MAC_DISTRIBUTION="app-store"
MAS_EXPORT_PLIST="/path/to/MAS-ExportOptions.plist"
XCODE_SCHEME="MyGame"
MAS_ASC_UPLOAD="1"
ASC_API_KEY_ID="ABCD123456"
ASC_API_ISSUER="00000000-0000-0000-0000-000000000000"
ASC_API_KEY_PATH="/path/to/AuthKey_ABCD123456.p8"
BUILD_TYPE="shipping"
```
