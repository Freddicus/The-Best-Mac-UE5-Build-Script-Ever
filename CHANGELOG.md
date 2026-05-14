# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are grouped by PR/merge. No semantic versioning — this is a single-file utility script.

---

## [2026-05-13] — Fix Developer ID export when Mac entitlements file holds Game Center; surface notarytool submit errors

Two cooperating fixes. After the `MAC_DISTRIBUTION` dispatcher landed (PR #28), switching a project from a prior MAS build back to Developer ID left `com.apple.developer.game-center=true` in `Build/Mac/Resources/<Project>.entitlements`. UE reads the same file via `ShippingSpecificMacEntitlements`, so the next archive embedded the entitlement and `xcodebuild -exportArchive` failed with `error: exportArchive No profiles for '<bundle id>' were found` — Developer ID provisioning profiles cannot carry game-center. Separately, when `notarytool submit` returned non-zero (notably the transient exit 69 you get if your Mac sleeps or loses network mid-upload), `submit_notary` died at the `out=$(...)` assignment under `set -e` before the captured stderr ever made it to the log, leaving "Script failed at line 93 (exit 69)" with no diagnostic.

### Fixed
- **`ensure_game_center_entitlements` now honors `--no-game-center` under `MAC_DISTRIBUTION=developer-id`**. The Mac cleanup branch previously gated on `MAC_DISTRIBUTION == app-store` only — symmetric for add, but wrong for remove, because `Build/Mac/Resources/<Project>.entitlements` is the same file UE Shipping reads via `ShippingSpecificMacEntitlements`. Widened the predicate to also fire under `developer-id` + remove (only remove — add on developer-id is already blocked upstream by `validate_distribution_compatibility`). Verified end-to-end on a project switching from MAS back to Developer ID: removes the `com.apple.developer.game-center` key, writes `bEnableGameCenterSupport=False` under `[/Script/MacRuntimeSettings.MacRuntimeSettings]`, archive embeds clean entitlements, `exportArchive` succeeds.
- **`submit_notary` no longer swallows `notarytool` errors**. Captures the exit code explicitly via `if out="$(...)"; then rc=0; else rc=$?; fi` so `set -e` cannot kill the function before the captured output is emitted, and the `die` message includes the exit code plus the last non-empty line of `notarytool`'s output. A transient service blip (machine sleep mid-upload, brief network outage, intermittent service error) now surfaces a usable error message instead of an unannotated exit code.

### Docs
- **`docs/configuration.md`** updated to describe the new `ENABLE_GAME_CENTER=0` cleanup semantics under `MAC_DISTRIBUTION=developer-id`. The "no-op with a warning" claim no longer applies to the remove path — it always cleans up; only the add path is rejected for incompatible distributions.

---

## [2026-05-13] — Auto-patch `Apple_SDK.json` when Xcode is newer than UE supports

When the Xcode/UE compatibility pre-flight (`check_apple_sdk_json_compat`) finds the active Xcode missing from the engine's `Apple_SDK.json` mapping table, ship.sh now offers to add the entry in place. The LLVM version that pairs with the local Xcode is sourced from Apple's own version-definition file in `apple/llvm-project` (branch `swift/release/<major.minor>`, file `cmake/Modules/LLVMVersion.cmake` on 6.1+ or inline in `llvm/CMakeLists.txt` on older branches) — the same data Apple's own toolchain build system reads, and the same data Wikipedia's editors transcribe from. Local `xcrun swift --version` provides the major.minor that picks the branch, so the lookup is driven entirely by what's actually installed. Removes a recurring failure mode where adopting a new Xcode point release stops a UE build until the user hand-edits the JSON.

### Added
- **`get_local_swift_branch`** — reads `xcrun swift --version`, returns Swift major.minor (e.g. `6.3`). Doubles as the `apple/llvm-project` branch suffix.
- **`fetch_llvm_version_from_apple_source`** — pure bash + `curl` + `grep`. Tries `cmake/Modules/LLVMVersion.cmake` first, falls back to `llvm/CMakeLists.txt` for older branches; extracts `LLVM_VERSION_MAJOR/MINOR/PATCH` and returns `X.Y.Z`. No Python, no HTML parsing, no third-party data source.
- **`patch_apple_sdk_json`** — inserts the new `"Xcode-LLVM"` pair after the last entry in `AppleVersionToLLVMVersions` (preserving comma placement and the file's existing tab indent), and bumps `MaxVersion` if the new Xcode is higher than the current ceiling. Idempotent: re-running with an entry already present returns `already_present` and writes nothing. Python is used here for surgical regex-edit of the JSON text — the existing formatting (including the `//1`..`//9` comment keys at the top) is preserved exactly.
- **Interactive offer in `check_apple_sdk_json_compat`** when the mapping check fails. Gated on (a) a TTY on FD 3, (b) `xcrun swift --version` producing a usable branch suffix, and (c) `python3` available — the offer is not shown unless all three can complete, so the prompt never dangles a non-functional path. On accept: fetch → patch → success message; on decline: falls through to the existing manual-fix instructions.

### Verified
End-to-end against the active install (UE 5.7 + Xcode 26.5): Swift `6.3` → LLVM `21.1.6`, identical to the existing `26.5.0-21.1.6` entry in Apple_SDK.json. Also verified across older branches: Swift `6.0` → `17.0.6` (matches `16.0.0-17.0.6`), Swift `5.10` → `16.0.0` (matches `15.0.0-16.0.0`) — confirming the source maps 1:1 to every entry Epic ships. Patcher tested for new-entry add (with MaxVersion bump), idempotent re-run, corrupt JSON, and missing file — each returns a distinct sentinel and the bash case statement handles them without false-success.

---

## [2026-05-12] — Mac App Store pipeline (`MAC_DISTRIBUTION=app-store`) (PR #29)

Wires the Mac App Store channel end-to-end on top of the dispatcher landed in the previous PR. `MAC_DISTRIBUTION=app-store` now runs a real build: xcodebuild archive under automatic provisioning → exportArchive against a MAS-specific ExportOptions.plist → optional `xcrun altool -t macos` validate/upload. Mirrors the existing iOS pipeline — same tooling, only the `-t macos` target and the export-plist `method=app-store-connect` differ. No ZIP, no DMG, no notarize/staple: App Store review is the equivalent gate. Resolves PR-2 of [issue #27](https://github.com/Freddicus/The-Best-Mac-UE5-Build-Script-Ever/issues/27).

### Added
- **Mac App Store build pipeline** (`MAC_DISTRIBUTION=app-store`). The roadmap die that PR-1 left behind is removed; the dispatcher now drops into a parallel branch alongside the existing Developer ID branch. Pipeline: UAT `BuildCookRun -targetplatform=Mac` → `xcodebuild archive -destination 'generic/platform=macOS' -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic` → `xcodebuild -exportArchive -exportOptionsPlist MAS-ExportOptions.plist -allowProvisioningUpdates`. Skips the per-component codesign loop, the script-generated temp entitlements file, the ZIP/DMG steps, and notarize+staple — none apply to MAS submissions. xcodebuild handles nested signing in one pass under automatic provisioning (same as iOS).
- **`MAS_EXPORT_PLIST`** config variable + **`--mas-export-plist PATH`** CLI flag. Auto-detected by conventional name `MAS-ExportOptions.plist` in the repo root. Validated up-front: must declare `method=app-store-connect`, `signingStyle=automatic`, and a `teamID` matching `DEVELOPMENT_TEAM` — Apple rejects mismatches at export time, so catching them now turns a multi-hour wasted build into a one-line error.
- **`MAS-ExportOptions.plist.example`** annotated template, parallel to the existing `ExportOptions.plist.example` (Developer ID) and `iOS-ExportOptions.plist.example`.
- **`MAS_ASC_VALIDATE` / `MAS_ASC_UPLOAD`** plus **`--mas-validate-app` / `--mas-upload-app`** flags. Runs `xcrun altool --validate-app -t macos` / `--upload-app -t macos` against the exported `.app`, post-archive.
- **`ASC_API_KEY_ID` / `ASC_API_ISSUER` / `ASC_API_KEY_PATH`** as the canonical, platform-neutral names for the App Store Connect API key (one Apple Developer account has one ASC API key, used by both iOS IPA uploads and Mac App Store `.app` uploads). New CLI flags `--asc-api-key-id`, `--asc-api-issuer`, `--asc-api-key-path`. The legacy `IOS_ASC_API_*` env vars and `--ios-asc-api-*` flags continue to work — resolved into `ASC_API_*` by `resolve_asc_credential_aliases()` immediately after CLI parse, then projected back so any existing reader keeps working.
- **`autodetect_asc_credentials_if_needed`** (renamed from `autodetect_ios_asc_credentials_if_needed`) — now fires for either `IOS_ASC_VALIDATE/UPLOAD` or `MAS_ASC_VALIDATE/UPLOAD`. Same `Config/DefaultEngine.ini` source (`AppStoreConnectKeyID` / `AppStoreConnectIssuerID` / `AppStoreConnectKeyPath`), same `_extract_ue_filepath` handling for the FFilePath struct wrapper.
- **Mac Game Center entitlement seeding** for `MAC_DISTRIBUTION=app-store`. `ensure_game_center_entitlements` now writes `Build/Mac/Resources/<Project>.entitlements` (parallel to the existing iOS path) and sets `bEnableGameCenterSupport=True` under `[/Script/MacRuntimeSettings.MacRuntimeSettings]`. `CODE_SIGN_ENTITLEMENTS=<path>` is passed to `xcodebuild archive` so UBT's intermediate entitlements file is bypassed (automatic provisioning ignores it). AMFI accepts `com.apple.developer.game-center` on this channel because the MAS provisioning profile encodes it. The function is refactored into a shared `_ensure_game_center_entitlement_for_platform` worker that both iOS and Mac branches dispatch into.
- **Apple Distribution / 3rd Party Mac Developer Application keychain pre-flight**: under `MAC_DISTRIBUTION=app-store`, the keychain check switches from `Developer ID Application` to `Apple Distribution` (preferred) / `3rd Party Mac Developer Application` (legacy). Fails fast with the available identities listed if neither is present.
- **Distinct MAS artifact paths**: `${SHORT_NAME}-mas.xcarchive` and `${SHORT_NAME}-mas-export/` under `Saved/Packages/Mac/`, alongside the Developer ID paths. Alternating channels for testing won't clobber each other's artifacts.
- **Interactive "upload now?" prompt after a successful App Store Connect validation** (iOS + MAS, symmetric). When `--ios-validate-ipa` or `--mas-validate-app` is set but the matching `--ios-upload-ipa` / `--mas-upload-app` is not, and stdin is a TTY, ship.sh prompts `Upload this .ipa/.pkg to App Store Connect now? (y/N)` after validation succeeds. Flag-driven runs are unchanged (upload flag wins, no prompt). CI / non-TTY runs are unchanged (no prompt; upload only when the flag was passed). Shared helper: `_maybe_prompt_for_asc_upload`.
- **Interactive export-plist generators for MAS and iOS** (`maybe_generate_mas_export_plist_interactively`, `maybe_generate_ios_export_plist_interactively`). Mirrors the existing `maybe_generate_export_plist_interactively` for Developer ID — when the conventional plist isn't found and the user is on a TTY, the autodetect helper offers to generate a minimal one in the repo root (method=`app-store-connect`, signingStyle=`automatic`, compileBitcode=`false`). Closes the asymmetry where dev-id had interactive generation but MAS/iOS just warned at the user to copy the `.example` file. When `DEVELOPMENT_TEAM` is unresolved at generation time, the plist is written with a literal `YOUR_TEAM_ID` placeholder and a warning is logged — the pre-flight teamID validator (added earlier in this PR for MAS) catches the forgotten edit before the multi-hour build.

### Fixed
- **MAS upload requires `com.apple.security.app-sandbox=true`.** Initial PR-2 had `ensure_game_center_entitlements` create `Build/Mac/Resources/<Project>.entitlements` with only `com.apple.developer.game-center=true`. Passing that file as `CODE_SIGN_ENTITLEMENTS` to the MAS archive shadowed UE's `ShippingSpecificMacEntitlements` path (which points at `Sandbox.NoNet.entitlements`, where the sandbox key actually lives) — so the resulting signed app shipped without sandbox, and ASC rejected the upload. Refactored entitlements management into composable PlistBuddy helpers (`_seed_entitlements_file_if_missing`, `_set_entitlement_bool`, `_delete_entitlement_key_if_present`) and added `ensure_mac_app_store_entitlements()` which runs unconditionally under `MAC_DISTRIBUTION=app-store` and enforces sandbox=true on the canonical entitlements file. Game Center on MAS now ALSO sets `com.apple.security.network.client=true` (Game Center cannot reach Apple's servers from inside the sandbox without it — silent failure mode otherwise). The MAS archive command now always passes `CODE_SIGN_ENTITLEMENTS=<path>` (was: only when `ENABLE_GAME_CENTER=1`), so the sandbox baseline is reliable. Pre-existing custom entitlement keys in the file are preserved across the composition (PlistBuddy `Add`/`Set` is per-key). Caught during the first end-to-end MAS upload attempt (Overhead Micro Game, 2026-05-12).
- **MAS export artifact is `.pkg`, not `.app`.** Initial PR-2 commit assumed `xcodebuild -exportArchive` with `method=app-store-connect` on macOS would produce a `.app` bundle under the export directory (mirroring the `find_first_app_under` lookup used by the Developer ID branch). It produces a signed `.pkg` installer (productbuild output) — that's the artifact `xcrun altool --upload-app -t macos` expects. The post-export lookup now searches for `*.pkg`, verification uses `pkgutil --check-signature` (the `codesign --verify --deep` chain only applies to unwrapped `.app` bundles), and the altool calls + end-of-run summary pass/report the `.pkg`. Caught during the first end-to-end MAS run on a real project (Overhead Micro Game, 2026-05-12).

### Changed
- **`SIGN_IDENTITY` is required only for `MAC_DISTRIBUTION=developer-id`** (was: required for any non-`IOS_ONLY` run). MAS uses automatic provisioning, so `SIGN_IDENTITY` is not consulted on that channel.
- **Notarize prompt skipped for non-Developer ID Mac channels.** Previously the interactive `Notarize + staple this build? (Y/n)` prompt fired regardless of `MAC_DISTRIBUTION`; it now defaults `NOTARIZE_ENABLED=0` non-interactively when `MAC_DISTRIBUTION != developer-id`. (Notarization only applies to direct-download Developer ID builds; MAS review is the equivalent gate.)
- **`ensure_game_center_entitlements`** no longer warns "iOS-only" when `MAC_DISTRIBUTION=app-store` — the function now treats Mac App Store as a co-equal eligible channel and seeds the entitlements file + ini section for both platforms in a single pass. The "no eligible channel" warning still fires when `ENABLE_GAME_CENTER=1` but neither MAS nor iOS is active.
- **`--game-center` help text** updated to describe both eligible channels (was: "iOS-only").
- **iOS `altool` upload now reads `ASC_API_*`** (instead of `IOS_ASC_API_*`) — no behavior change because the legacy variables remain in sync, but consolidates the read site on the canonical names.

### Compatibility matrix (updated)

| Combination | Behavior | Reason |
|---|---|---|
| `MAC_DISTRIBUTION=off` + `IOS_DISTRIBUTION=off` | rejected | Nothing to build. |
| `MAC_DISTRIBUTION=app-store` + `ENABLE_STEAM=1` | rejected | Mac App Store review forbids `com.apple.security.cs.disable-library-validation` and `com.apple.security.cs.allow-dyld-environment-variables`. |
| `MAC_DISTRIBUTION=developer-id` + `ENABLE_GAME_CENTER=1` for Mac (no iOS) | rejected | AMFI rejects `com.apple.developer.game-center` on Developer-ID-signed Mac apps at exec, regardless of notarization. |
| `MAC_DISTRIBUTION=app-store` + `ENABLE_GAME_CENTER=1` | **supported** | MAS provisioning profile encodes the entitlement; AMFI accepts it. |
| `MAC_DISTRIBUTION=app-store` | **supported** (newly wired by this PR) | UAT → archive → exportArchive → optional `altool -t macos`. |

### Legacy compatibility (no breaking changes)

- `IOS_ASC_API_KEY_ID/ISSUER/KEY_PATH` env vars + `--ios-asc-api-*` flags continue to work — the resolver promotes them into `ASC_API_*` when the canonical names are unset.
- `ENABLE_IOS` / `IOS_ONLY` and their CLI aliases keep working as projected onto the dispatcher (unchanged from PR-1).

### Roadmap (still tracked in [issue #27](https://github.com/Freddicus/The-Best-Mac-UE5-Build-Script-Ever/issues/27))
- **PR-3**: `--preset NAME` layer for common configurations (`steam-mac`, `direct-mac`, `mas-mac`, `ios`, `mac+ios`, `mas+ios`). `steam-mac` → `MAC_DISTRIBUTION=developer-id` + `ENABLE_STEAM=1` + `ENABLE_ZIP=1` (Steam upload format) + `NOTARIZE=yes`. `direct-mac` → `MAC_DISTRIBUTION=developer-id` + `ENABLE_STEAM=0` + `ENABLE_DMG=1` + `NOTARIZE=yes`. `mas-mac` → `MAC_DISTRIBUTION=app-store`, `ENABLE_GAME_CENTER` optional.

---

## [2026-05-12] — Distribution dispatcher (`MAC_DISTRIBUTION` / `IOS_DISTRIBUTION`) (PR #28)

Carves out the two macOS distribution paths (Direct Distribution vs Mac App Store) and the single iOS path into explicit dispatcher variables, so every downstream check (entitlements, signing cert, ExportOptions method, upload tooling) has one place to consult. Foundational change with no new build behavior — `MAC_DISTRIBUTION=developer-id` (default) runs the existing pipeline unchanged.

### Added
- **`MAC_DISTRIBUTION` dispatcher** ∈ `developer-id` *(default)* | `app-store` | `off`. The `developer-id` branch is the script's existing Direct Distribution pipeline (Developer ID Application, hardened runtime, notarize + staple, Steam allowed). `app-store` is recognized — validates compatibility with other flags — but the pipeline itself is on the roadmap and currently fails fast with a clear pointer to [issue #27](https://github.com/Freddicus/The-Best-Mac-UE5-Build-Script-Ever/issues/27); use Xcode Organizer's `Distribute App → App Store Connect` in the meantime. `off` skips Mac entirely (iOS-only run).
- **`IOS_DISTRIBUTION` dispatcher** ∈ `off` *(default)* | `app-store`. iOS has no other distribution channel in the US, so this is a single-valued dispatcher today.
- **CLI flags** `--mac-distribution VALUE` and `--ios-distribution VALUE`.
- **`resolve_distribution_flags`** and **`validate_distribution_compatibility`** — run once after CLI parse. The resolver reconciles legacy `ENABLE_IOS` / `IOS_ONLY` flags with the new dispatcher (CLI dispatcher wins, otherwise legacy flags promote into the dispatcher, finally the dispatcher is projected back onto the legacy names so existing condition-checks keep working without a sweeping rewrite). The validator enforces the compatibility matrix below.
- **`ROADMAP_ISSUE_URL`** script constant pointing at issue #27 — referenced from the `die` messages so the user always knows where the roadmap lives.

### Compatibility matrix (enforced up-front)

| Combination | Behavior | Reason |
|---|---|---|
| `MAC_DISTRIBUTION=off` + `IOS_DISTRIBUTION=off` | rejected | Nothing to build. |
| `MAC_DISTRIBUTION=app-store` + `ENABLE_STEAM=1` | rejected | Mac App Store review forbids `com.apple.security.cs.disable-library-validation` and `com.apple.security.cs.allow-dyld-environment-variables`. |
| `MAC_DISTRIBUTION=developer-id` + `ENABLE_GAME_CENTER=1` for Mac (no iOS) | rejected | AMFI rejects `com.apple.developer.game-center` on Developer-ID-signed Mac apps at exec, regardless of notarization. |
| `MAC_DISTRIBUTION=app-store` | rejected (today) | Pipeline not yet wired — tracked at [issue #27](https://github.com/Freddicus/The-Best-Mac-UE5-Build-Script-Ever/issues/27). |

### Legacy compatibility (no breaking changes)

- `ENABLE_IOS=1` ⇔ `IOS_DISTRIBUTION=app-store`
- `IOS_ONLY=1` ⇔ `MAC_DISTRIBUTION=off` + `IOS_DISTRIBUTION=app-store`
- `--ios`, `--no-ios`, `--ios-only` continue to work exactly as before. Existing `.env` files and CI configs work without changes.

### Docs
- New "Distribution channels" section near the top of `docs/configuration.md` documenting the dispatcher, the compatibility matrix, and the legacy-flag mapping.
- `README.md` quick-start section gains a "Distribution channels" paragraph forward-referencing the new docs section.
- `.env.example` adds commented-out `MAC_DISTRIBUTION` / `IOS_DISTRIBUTION` entries with the same documentation tone as the existing config blocks.

### Roadmap (tracked in [issue #27](https://github.com/Freddicus/The-Best-Mac-UE5-Build-Script-Ever/issues/27))
- **PR-2**: Wire `MAC_DISTRIBUTION=app-store` end-to-end (Apple Distribution signing identity verification, MAS ExportOptions auto-generator, skip the manual nested-component codesign loop, skip the temp entitlements file, mirror the iOS Game Center seed for Mac, `xcrun altool -t macos` validate/upload).
- **PR-3**: Add a `--preset NAME` layer for common configurations (`steam-mac`, `direct-mac`, `mas-mac`, `ios`, `mac+ios`, `mas+ios`).

---

## [2026-05-11] — Add iOS pipeline; migrate Mac to xcodebuild build-setting overrides; canonical icon sync (PR #23)

### Removed
- **`<Platform>-SourceControlled.xcassets/` source-controlled staging.** The previous flow rsync'd a separate `macOS-SourceControlled.xcassets/` (or `iOS-SourceControlled.xcassets/`) into `Build/{Platform}/Resources/Assets.xcassets/`. That added a sync step and a second copy of the icons. The simpler convention: maintain `Build/{Platform}/Resources/Assets.xcassets/` directly (UE's auto-discovered canonical path per `XcodeProject.cs:1731-1742`) and commit it. Removed: `_stage_platform_icon_assets`, `seed_macos_icon_assets`, `seed_ios_icon_assets`, env vars `MACOS_ICON_SYNC`/`MACOS_ICON_XCASSETS`/`IOS_ICON_SYNC`/`IOS_ICON_XCASSETS`, CLI flags `--macos-icon-sync`/`--no-macos-icon-sync`/`--macos-icon-xcassets`/`--ios-icon-sync`/`--no-ios-icon-sync`/`--ios-icon-xcassets`, and the associated default-path resolution + pre-flight checks.
- **Migration:** if you have a `<Platform>-SourceControlled.xcassets/` at the repo root, move its contents into `Build/<Platform>/Resources/Assets.xcassets/` and commit. UE auto-discovers it at `GenerateProjectFiles` time.

### Kept
- **`MACOS_APPICON_SET_NAME` and `IOS_APPICON_SET_NAME`** (env vars + CLI flags) — repurposed to drive the canonical-catalog AppIcon mirror. UE's xcconfig hardcodes `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` (`XcodeProject.cs:2157`), so if your appiconset is named differently, the script mirrors it to `AppIcon.appiconset` alongside via `_mirror_appicon_in_catalog`. Auto-detects the first appiconset if the env var is unset.

### Added (icon mirror)
- **`_mirror_appicon_in_catalog(catalog, override)`**: idempotent helper that creates `AppIcon.appiconset` by copying from a named (or auto-detected first) appiconset within the catalog. No-op when `AppIcon.appiconset` already exists or when the catalog has no appiconsets.
- **`ensure_macos_canonical_appicon` / `ensure_ios_canonical_appicon`**: pipeline helpers that run before `regenerate_project_files`, ensuring `Build/Mac/Resources/Assets.xcassets/AppIcon.appiconset/` and `Build/IOS/Resources/Assets.xcassets/AppIcon.appiconset/` exist (mirroring from a non-`AppIcon`-named set if the user maintains their catalog under a different name).

This branch ships three tightly-related changes. All three rest on the canonical-overrides foundation laid in PR #22 (`Move outputs to Saved/, route Info.plist through canonical UE overrides, auto-bump CFBundleVersion`).

### Added
- **iOS pipeline (opt-in)**: `ENABLE_IOS=1` / `--ios` runs an iOS pass after the Mac build; `IOS_ONLY=1` / `--ios-only` skips Mac entirely (doesn't require `SIGN_IDENTITY`). Pipeline: UAT `BuildCookRun -targetplatform=IOS` → `xcodebuild archive -destination 'generic/platform=iOS' -allowProvisioningUpdates` → `xcodebuild -exportArchive` → `.ipa` → optional `xcrun altool` validate/upload. Outputs land in `Saved/Packages/IOS/`. Skips notarization (App Store handles the equivalent on submission) and per-component codesign (xcodebuild + ExportOptions handles iOS App Store signing in one pass).
- **Auto-detection** for iOS: `IOS_WORKSPACE` (`<Project> (iOS).xcworkspace`), `IOS_SCHEME` (inferred from `XCODE_SCHEME` if set, else `xcodebuild -list`), `IOS_EXPORT_PLIST` (conventional name `iOS-ExportOptions.plist`, or content-scan that excludes Mac-only methods like `developer-id`/`mac-application`).
- **Shared `MARKETING_VERSION` across Mac and iOS.** `ensure_marketing_version_in_engine_ini` now writes to BOTH `[/Script/MacRuntimeSettings.MacRuntimeSettings] VersionInfo=` (read by UE at `XcodeProject.cs:1997`) and `[/Script/IOSRuntimeSettings.IOSRuntimeSettings] VersionInfo=` (read at `XcodeProject.cs:2011`). Optional `IOS_MARKETING_VERSION` overrides only the iOS section (rare; for projects shipping different display versions per platform).
- **Shared `CFBUNDLE_VERSION` across platforms.** The auto-bump runs once per `ship.sh` invocation; both Mac and iOS `xcodebuild archive` calls receive the same `CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION` build-setting override, so Mac and iOS archives ship the same build counter.
- **`xcrun altool` integration** for App Store Connect: `--ios-validate-ipa` runs `--validate-app`, `--ios-upload-ipa` runs `--upload-app` (implies validate). `IOS_ASC_API_KEY_ID/ISSUER/KEY_PATH` are auto-detected from `Config/DefaultEngine.ini` (`AppStoreConnectKeyID`, `AppStoreConnectIssuerID`, `AppStoreConnectKeyPath` — what Xcode stores when you configure the API key in project settings). Documentation explicitly distinguishes `altool` (iOS upload to ASC) from `notarytool` (Mac notarization) — different tools, different services, different credential formats.
- **`iOS-ExportOptions.plist.example`**: annotated template with `method=app-store-connect` (replaces deprecated `app-store`), `signingStyle=automatic`, and a "this is iOS not macOS" warning.

### Changed (BREAKING for the in-flight CFBundleVersion mechanism)
- **Mac CFBundleVersion: post-export `PlistBuddy` → xcodebuild build-setting override.** Previously the script ran `PlistBuddy` on the exported `.app/Contents/Info.plist` (post-export, pre-codesign) and on `<ARCHIVE_PATH>/Info.plist`'s `ApplicationProperties:CFBundleVersion` (Organizer cosmetic stamp). Now the script passes `CURRENT_PROJECT_VERSION=$CFBUNDLE_VERSION` directly to `xcodebuild archive`. Apple-documented behavior: command-line build settings take precedence over xcconfig, so this shadows UE's `CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION)` xcconfig line. Xcode bakes the value into both the `.app`'s `Info.plist` and the `.xcarchive` metadata at archive time — one pass, no fixups, no broken signature mid-flow. Removed `override_cfbundle_version_in_app_plist` and `override_cfbundle_version_in_xcarchive_metadata`.
- **Icon sync: `Intermediate/SourceControlled/` + pbxproj patching → canonical `Build/{Platform}/Resources/Assets.xcassets`.** UE's `XcodeProject.cs:1731-1742` auto-discovers the canonical path via `UnrealData.ProjectOrEnginePath()` at GenerateProjectFiles time. The script stages the source catalog into the canonical UE-discovered path *before* `regenerate_project_files`, eliminating the post-UAT pbxproj-walking sed loop entirely. The `_stage_platform_icon_assets` helper is shared between Mac and iOS.

### New CLI flags
- `--ios` / `--no-ios`
- `--ios-only`
- `--ios-workspace PATH`, `--ios-scheme NAME`, `--ios-export-plist PATH`
- `--ios-appicon-set-name NAME` (mirror an existing `*.appiconset` in `Build/IOS/Resources/Assets.xcassets/` to `AppIcon.appiconset`)
- `--ios-marketing-version STRING`
- `--ios-validate-ipa`, `--ios-upload-ipa`
- `--ios-asc-api-key-id ID`, `--ios-asc-api-issuer UUID`, `--ios-asc-api-key-path PATH`

### Migration
- **Existing Mac-only users:** no action required. `ENABLE_IOS=0` (default) means no iOS code runs. The Mac CFBundleVersion mechanism switch is internal — same final value lands in the shipped `Info.plist`, just via a cleaner mechanism.
- **Adding iOS to an existing project:** copy `iOS-ExportOptions.plist.example` to `iOS-ExportOptions.plist`, edit the team ID. Create `Build/IOS/Resources/Assets.xcassets/AppIcon.appiconset/` (or rely on the mirror — see "Kept" above). Run `./ship.sh --print-config --ios` to see what the script will do.
- **CI uploads to App Store Connect:** create an ASC API key (appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API), download the `.p8`, and either set `IOS_ASC_API_KEY_ID/ISSUER/KEY_PATH` in `.env` or let Xcode store them in `Config/DefaultEngine.ini` for auto-detection.

### Docs
- [README.md](README.md): pipeline list reorganized into Mac and iOS phases; new "Targeting iOS too" quick-start section.
- [docs/configuration.md](docs/configuration.md): new "iOS pipeline (opt-in)" section with full `IOS_*` env-var reference; new "iOS App Store Connect upload (xcrun altool — NOT notarytool)" subsection with side-by-side comparison; new iOS-only minimal CI config example.
- [docs/versioning.md](docs/versioning.md): MARKETING_VERSION and CFBUNDLE_VERSION sections updated to call out cross-platform sharing; new IOS_MARKETING_VERSION subsection.
- [docs/output.md](docs/output.md): split artifact-paths table into Mac and iOS subsections with `Saved/Packages/IOS/` paths.
- [.env.example](.env.example): new "iOS pipeline (opt-in, default off)" and "iOS App Store Connect upload (xcrun altool — NOT notarytool)" sections.

### New file
- `iOS-ExportOptions.plist.example`

---

## [2026-05-09] — Stamp `.xcarchive` metadata so Xcode Organizer shows auto-bumped `CFBundleVersion`

### Added
- **`override_cfbundle_version_in_xcarchive_metadata()`**: between `xcodebuild archive` and `xcodebuild -exportArchive`, `PlistBuddy`-stamps the resolved `CFBundleVersion` into `<ARCHIVE_PATH>/Info.plist`'s `:ApplicationProperties:CFBundleVersion`. Without this, Xcode Organizer's Archives view showed UE's pre-export internal value (e.g. `1.0.2 (0.1)`) while the shipped `.app` had the auto-bumped value — confusing if you're cross-checking. Now the Organizer shows the same `CFBundleVersion` that ships. Cosmetic; the archive's embedded `.app` is intentionally left untouched (modifying it would invalidate its signature inside the archive without buying anything — the script's exported `.app` is what actually ships and gets signed independently). No-op on Path A (`USE_UE_PACKAGE_VERSION_COUNTER=1`) since `CFBUNDLE_VERSION` is cleared by the resolver and UE's flow supplies the value end-to-end. Idempotent.

---

## [2026-05-09] — Default `CFBUNDLE_VERSION` to auto-bump; gate UE-canonical path behind opt-in flag

### Changed (BREAKING)
- **`CFBUNDLE_VERSION` is now auto-bumped on every build by default.** The script reads `CFBUNDLE_VERSION` from `.env` (treating empty/missing as `0`), pre-increments by 1, ships that value as `CFBundleVersion`, and persists the new value back to `.env` on a successful build. With `.env.example`'s `CFBUNDLE_VERSION="0"`, the first build ships `CFBundleVersion=1`. Failed/interrupted builds don't persist — the next build retries the same number, so no build numbers are wasted.
- **`--cfbundle-version N` renamed to `--set-cfbundle-version N`** to convey the new "set baseline" semantics: the value is shipped *and* persisted, so subsequent auto-bump builds resume from `N`. Use to reset the counter (`--set-cfbundle-version 100`) or pin to a CI value (`--set-cfbundle-version "$GITHUB_RUN_NUMBER"`).
- **UE-canonical `CFBundleVersion` path is now opt-in.** The previous default (Path A: seed `Build/Mac/<Project>.PackageVersionCounter` + project-level `UpdateVersionAfterBuild.sh` override) is gated behind a single new flag `USE_UE_PACKAGE_VERSION_COUNTER` (default `0`) / CLI `--use-ue-package-version-counter`. When enabled, the script seeds both files and skips the Info.plist override; UE's flow supplies `CFBundleVersion` end-to-end. Mutually exclusive with the auto-bump.
- **Removed env vars `SEED_MAC_PACKAGE_VERSION_COUNTER` and `SEED_MAC_UPDATE_VERSION_AFTER_BUILD`** (and their CLI flags). Both seed functions are now gated on `USE_UE_PACKAGE_VERSION_COUNTER` together — one knob covers the whole Path A bundle.

### Added
- **`_resolve_cfbundle_version_for_build()`**: at build start (after dry-run / print-config exits), decides what `CFBundleVersion` will ship. Three branches: Path A (clear `CFBUNDLE_VERSION`, no override, no persist); explicit set via `--set-cfbundle-version` (use as-is, persist); default auto-bump (pre-increment integer, persist). Sets `_CFBV_PERSIST=1` to mark for end-of-script persistence on success.
- **`_write_env_var(name, value)`**: shared idempotent in-place writer for `NAME="value"` pairs in `.env`. Updates the line if it exists, appends if it doesn't, creates `.env` if missing. Now used by both `write_bumped_version_to_env` (for `VERSION_STRING`) and the new `write_cfbundle_version_to_env` (for `CFBUNDLE_VERSION`).
- **`write_cfbundle_version_to_env()`**: persists the bumped/set `CFBUNDLE_VERSION` to `.env` on the success path. Called alongside `write_bumped_version_to_env` at end-of-script. No-op when `_CFBV_PERSIST=0` (Path A or non-integer auto-bump skip).
- **`.env.example`**: now ships with `CFBUNDLE_VERSION="0"` uncommented, since the script auto-bumps from this baseline. Documentation explains both `--set-cfbundle-version` (new baseline) and `USE_UE_PACKAGE_VERSION_COUNTER=1` (Path A opt-in).

### Migration
- **No action required for most users.** The auto-bump default produces the same integer-style `CFBundleVersion` you'd want for App Store / Gatekeeper. First build after this change ships `1` (or `<previous CFBUNDLE_VERSION> + 1` if you already had a value in `.env`).
- **If you previously relied on Path A** (seeded `PackageVersionCounter` + `UpdateVersionAfterBuild.sh` override): set `USE_UE_PACKAGE_VERSION_COUNTER=1` in your `.env` to restore that behavior. The `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` you previously committed is still valid.
- **If you previously used `--cfbundle-version N`** (one-off override that didn't persist): rename to `--set-cfbundle-version N` and note that the value now persists to `.env`. To explicitly reset to a one-off behavior, follow up by editing `.env` manually — but most callers actually want the new "set baseline" semantics.
- **`--bump-major/--bump-minor/--bump-patch` are unchanged** — they still bump only `VERSION_STRING` (semver, runtime `Content/<dir>/version.txt`), not `CFBundleVersion`. The two version concepts are intentionally independent.

---

## [2026-05-09] — Replace xcconfig hijack with canonical UE override paths

### Removed (BREAKING)
- **`update_xcconfig_versions()` removed.** The script no longer post-processes `Intermediate/ProjectFiles/XcconfigsMac/<Project>.xcconfig`. That approach fought with `GenerateProjectFiles` every regen and put canonical project state in an `Intermediate/` file. All five Info.plist values it used to stamp now route through their sanctioned UE override locations.

### Changed (BREAKING)
- **`MARKETING_VERSION`** (`CFBundleShortVersionString`): now writes to `Config/DefaultEngine.ini` `[/Script/MacRuntimeSettings.MacRuntimeSettings] VersionInfo=`. Read by UE at `XcodeProject.cs:1997` and stamped into the generated xcconfig automatically. Unset = leave `DefaultEngine.ini` alone (UE falls back to engine display version — set this once for any production build).
- **`APP_CATEGORY`** (`LSApplicationCategoryType`): now writes to `Config/DefaultEngine.ini` `[/Script/MacTargetPlatform.XcodeProjectSettings] AppCategory=`. Read at `XcodeProject.cs:1982`. UE's `BaseEngine.ini:3462` already defaults this to `public.app-category.games` — only override for a different category.
- **`ENABLE_GAME_MODE`** (`LSSupportsGameMode` + `GCSupportsGameMode`): now sets keys directly in `Build/Mac/Resources/Info.Template.plist` via `PlistBuddy`. UE's `BaseEngine.ini:3463` configures `TemplateMacPlist=` to point here, so any plist landing at this path is auto-discovered and its contents merged into the final `Info.plist` by Xcode at build time.
- **`CFBundleVersion`** (`CURRENT_PROJECT_VERSION`): now driven by UE's canonical `Build/Mac/<Project>.PackageVersionCounter` mechanism. UE's `Engine/Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` reads this counter, increments the minor (`0.0` → `0.1` → …), and writes the value to `Intermediate/Build/Versions.xcconfig` as `UE_MAC_BUILD_VERSION` — referenced by the generated xcconfig as `CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION)`. **CFBundleVersion is no longer derived from `VERSION_STRING` / `VERSION_MODE`** — those still control the runtime `version.txt` stamp, but Xcode's bundle version is now an independent monotonic counter (per UE convention).
- **Default behavior change** when `MARKETING_VERSION` is unset: previously the script defaulted to `1.0.0` with a warning; now the script does nothing and UE falls back to its engine display version. Action: set `MARKETING_VERSION` in `.env` once and let the script write it to `DefaultEngine.ini`.
- **Default behavior change** when `ENABLE_GAME_MODE` is unset: previously defaulted to `YES` with a warning; now the script does not touch the plist's GameMode keys at all (your plist is sovereign).

### Added
- **`set_engine_ini_value()`**: idempotent setter for a key=value pair under a section in `Config/DefaultEngine.ini`. No-op when the value already matches; replaces in place when different; inserts after the section header when the section exists but the key doesn't; appends section + key when neither exists.
- **`ensure_marketing_version_in_engine_ini()`** and **`ensure_app_category_in_engine_ini()`**: thin wrappers that route `MARKETING_VERSION` and `APP_CATEGORY` to their canonical ini sections when set.
- **`seed_mac_info_template_plist()`**: defensively copies the engine's stock `Info.Template.plist` from `$UE_ROOT/Engine/Build/Mac/Resources/` to `$REPO_ROOT/Build/Mac/Resources/` if missing, then sets `LSSupportsGameMode` and `GCSupportsGameMode` via `PlistBuddy` when `ENABLE_GAME_MODE` is set. Idempotent. Controlled by `SEED_MAC_INFO_TEMPLATE_PLIST` (default `1`) and `--seed-mac-info-template-plist` / `--no-seed-mac-info-template-plist`.
- **`seed_mac_package_version_counter()`**: defensively seeds `Build/Mac/<Project>.PackageVersionCounter` to `0.0` when missing. Idempotent. Controlled by `SEED_MAC_PACKAGE_VERSION_COUNTER` (default `1`) and `--seed-mac-package-version-counter` / `--no-seed-mac-package-version-counter`. To start at a specific value, edit the counter file directly — the script never overwrites an existing one. Per UE convention, this file is gitignored (`Build/{Platform}/*.PackageVersionCounter` is in the "UBT writes here itself" category).
- **`override_cfbundle_version_in_app_plist()`**: escape hatch from UE's `<CL>.<X>.<Y>` `CFBundleVersion` format, matching the pattern AA/AAA studios typically use when CI manages an explicit monotonic build counter. When `CFBUNDLE_VERSION` is set (env var or `--cfbundle-version N` CLI flag), the script `PlistBuddy`-rewrites `CFBundleVersion` in the exported `.app/Contents/Info.plist` *after* `xcodebuild -exportArchive` but *before* the codesign step — the signature is computed over the modified plist, so the bundle stays internally consistent. Bypasses UE's `PackageVersionCounter` auto-increment for the shipped bundle. Use for App-Store-style monotonic integers (`7`, `42`, `$GITHUB_RUN_NUMBER`, `$BUILD_NUMBER`). Idempotent (skips when current value matches). Unset = UE-canonical `PackageVersionCounter` flow takes over. The two paths are complementary and documented as "Path A vs Path B" in [docs/versioning.md](docs/versioning.md#cfbundleversion-two-paths-pick-one).
- **`seed_mac_update_version_after_build_script()`**: defensively drops a project-level `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` that strips the engine's `Build.version` Changelist from `CFBundleVersion`. UE's engine script writes `UE_MAC_BUILD_VERSION = <CL>.<MAC_VERSION>` where `<CL>` is the Perforce changelist baked into `Engine/Build/Build.version` — for an Epic Games Launcher install of 5.7.4 that's `51494982`, so projects ship `CFBundleVersion=51494982.0.2`. Our override is byte-identical to the engine script except it omits the `<CL>.` prefix, so projects ship `CFBundleVersion=0.2` as expected. Sanctioned override path at `AppleToolChain.cs:394-397` (UE checks the project for this script first and only falls back to the engine's copy if absent). Idempotent. Controlled by `SEED_MAC_UPDATE_VERSION_AFTER_BUILD` (default `1`) and `--seed-mac-update-version-after-build` / `--no-seed-mac-update-version-after-build`. **Commit this file** so CI and other machines get the same behavior.
- **`_set_plist_bool()`**: helper for idempotent boolean writes via `PlistBuddy` (no-op when value matches; uses `Set` if key exists, `Add` otherwise).
- **Pipeline order** (between `write_version_to_content` and `regenerate_project_files`): `seed_apple_launchscreen_compat` → `seed_mac_info_template_plist` → `seed_mac_package_version_counter` → `ensure_app_category_in_engine_ini` → `ensure_marketing_version_in_engine_ini`. All seeds and ini writes happen before `GenerateProjectFiles` so UE picks up the canonical config in a single pass.
- **Dry-run preview** updated to show the seed step.
- **Docs:**
  - [docs/versioning.md](docs/versioning.md): the entire "xcconfig stamping" section replaced by "Info.plist values via canonical UE overrides", with the canonical-mapping table, per-key migration notes, the auto-incrementing CFBundleVersion explanation, and seed opt-out flags.
  - [docs/configuration.md](docs/configuration.md): new env-var rows for `SEED_MAC_INFO_TEMPLATE_PLIST`, `SEED_MAC_PACKAGE_VERSION_COUNTER`, `MARKETING_VERSION`, `APP_CATEGORY`, `ENABLE_GAME_MODE` (semantics updated). New CLI examples.
  - [docs/output.md](docs/output.md): "ship.sh does write three specific files under Build/" exception called out with a table mapping each canonical seed to its purpose and disable flag.
  - [README.md](README.md): pipeline list reorganized — old "xcconfig stamp" step removed, replaced by "Canonical UE seeds" + "Canonical ini ensures" steps.
  - [.env.example](.env.example): version/Info.plist section rewritten to describe canonical UE override paths.

### Migration
- **Set `MARKETING_VERSION` in your `.env`** (or `Config/DefaultEngine.ini` directly under the canonical section). Without it, `CFBundleShortVersionString` falls back to UE's engine display version (e.g. `5.7.0`).
- **Run the script once** to seed `Build/Mac/Resources/Info.Template.plist` and `Build/Mac/<Project>.PackageVersionCounter` from the engine stock, then **commit them**. They become permanent project source.
- **CFBundleVersion is now monotonically auto-incrementing** (`0.1` → `0.2` → ...). If you previously expected CFBundleVersion to track `VERSION_STRING`, edit `Build/Mac/<Project>.PackageVersionCounter` to your desired baseline and let UE auto-increment from there. The seeded `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` override ensures Epic's engine Changelist (e.g. `51494982` for EGL 5.7.4) is *not* prepended.
- **Game Mode**: if you want it on, set `ENABLE_GAME_MODE=1` once and run the script — it'll stamp `LSSupportsGameMode=true` and `GCSupportsGameMode=true` into your seeded `Info.Template.plist`. Subsequent builds with the env var unset preserve those values (the plist is yours to own).

---

## [2026-05-08] — Move outputs from `Build/` to `Saved/`; always regenerate project files

### Changed
- **`BUILD_DIR_REL` default: `Build` → `Saved/Packages/Mac`.** Build artifacts (xcarchive, export dir, ZIP, DMG, UAT-archived `.app`) now land under UE's documented `Saved/` tree instead of the `Build/` folder. `Build/{Platform}/` is reserved for committed source-controlled inputs (app icons, custom launch storyboard, `Info.plist` fragments, entitlements, `PakBlacklist*.txt`) — UBT writes a small set of intermediates there but ship.sh no longer does. See [docs/output.md](docs/output.md#build-vs-saved--what-goes-where) for the rationale.
- **`LOG_DIR_REL` default: `Logs` → `Saved/Logs`.** Matches UE convention.
- **UAT BuildCookRun's `-archivedirectory` is now derived as `dirname BUILD_DIR`.** UAT appends `/<TargetPlatform>/` to whatever path is given, so pointing it at the parent of `BUILD_DIR` lands UAT's output at `Saved/Packages/Mac/<App>-Mac-Shipping.app/` — the same directory as the script-side artifacts. Previously, with `BUILD_DIR_REL=Build`, UAT was writing into `Build/Mac/` (or `Build/IOS/` for cross-platform consumers), violating the inputs/outputs split.
- **Build pipeline order:** `GenerateProjectFiles` and `update_xcconfig_versions` now run *before* UAT BuildCookRun, so the regenerated and stamped xcconfig is in place by the time UAT executes. The previous order ran the xcconfig stamp before regen would have happened (regen didn't run unconditionally then).

### Added
- **`regenerate_project_files()`**: runs `Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh -project="$UPROJECT_PATH" -game` once per ship invocation, before xcconfig stamping and the Xcode build. Idempotent and cheap (~few seconds). Closes a class of "I added a file under `Build/{Platform}/Resources/` but the build doesn't see it" bugs — UBT bakes resolved absolute paths into `Intermediate/ProjectFilesMac/<Project> (Mac).xcodeproj/project.pbxproj` at *project-file-generation time*, so adding a sibling file (e.g. a custom `LaunchScreen.storyboard`) doesn't flow into the build until project files are regenerated.
- **`seed_apple_launchscreen_compat()`**: defensively copies `$(UE)/Engine/Build/IOS/Resources/Interface/LaunchScreen.storyboardc` to `$(Project)/Build/Apple/Resources/Interface/LaunchScreen.storyboardc` if the destination is missing, so Mac's launch-screen path priority list short-circuits at a pre-compiled wrapper before reaching a consumer-supplied iOS `.storyboard` source. Without this, adding a custom iOS launch storyboard breaks Mac builds: `XcodeProject.cs::ProcessAssets`'s `AddResource` call is unconditional, and Xcode can't compile an iOS `.storyboard` source for macOS. Idempotent (skips if dest exists or engine source is missing). The one exception to "ship.sh does not write under `Build/`" — the seeded file is a stock engine asset, not a customization, and is intended to be committed afterwards. Controlled by `SEED_APPLE_LAUNCHSCREEN_COMPAT` (default `1`) and `--seed-apple-launchscreen-compat` / `--no-seed-apple-launchscreen-compat`. See the new ["Adding a custom iOS LaunchScreen.storyboard breaks the Mac build" gotcha](docs/gotchas.md#adding-a-custom-ios-launchscreenstoryboard-breaks-the-mac-build).
- **`REGEN_PROJECT_FILES`** config variable (default `1` when `USE_XCODE_EXPORT=1`) and **`--regen-project-files` / `--no-regen-project-files`** CLI flags. Escape hatch for the rare case the regen is unwanted.
- **`--build-dir PATH`** CLI flag for overriding `BUILD_DIR_REL` from the command line.
- **`UAT_ARCHIVE_DIR`** is shown in `--print-config` output (derived from `BUILD_DIR`).
- **Dry-run preview** now lists `GenerateProjectFiles` as an explicit step when applicable.
- **Docs:**
  - [docs/output.md](docs/output.md): new "Build/ vs Saved/ — what goes where" section; updated artifact paths table; new "How `BUILD_DIR_REL` and `UAT_ARCHIVE_DIR` relate" section explaining the parent-dir derivation and UAT flag map.
  - [docs/configuration.md](docs/configuration.md): `BUILD_DIR_REL` / `LOG_DIR_REL` default updates; new `REGEN_PROJECT_FILES` row; expanded "Project files are regenerated every ship" explanation under Xcode workspace; CLI examples for `--build-dir` and `--no-regen-project-files`.
  - [docs/gotchas.md](docs/gotchas.md): two new gotchas — "`Build/{Platform}/` is for committed inputs, not output" and "New files under `Build/{Platform}/Resources/` need a project-file regen to be picked up" (with the `XcodeProject.cs::ProcessAssets` path priority list).
  - [docs/troubleshooting.md](docs/troubleshooting.md): two new symptom-driven entries — "I added a file to `Build/{Platform}/Resources/` but the build still uses the engine default" and "My packaged `.app` ended up in `Build/{Platform}/` instead of `Saved/Packages/`".
  - [README.md](README.md): updated pipeline step list (added GenerateProjectFiles, reordered xcconfig stamp before UAT, moved icon seeding) and artifact-path summary.

### Migration
- If your `.env` sets `BUILD_DIR_REL=Build` (or `LOG_DIR_REL=Logs`), remove those overrides to pick up the new defaults — or set them explicitly to `Saved/Packages/Mac` / `Saved/Logs`.
- If you intentionally want output to stay in `Build/`, set `BUILD_DIR_REL=Build/Mac` (note the `/Mac` suffix — the script's app-discovery expects `BUILD_DIR` to be the directory UAT writes its `.app` into, which means it must end with `/<Platform>`).
- If you have CI that uploads artifacts from `Build/`, update the path to `Saved/Packages/Mac/`.

---

## [2026-04-14] — Restructure docs: slim README + supplemental docs/ (PR #20)

### Added
- `docs/configuration.md`: full `.env` variable reference, CLI flags, Xcode workspace auto-detection, scheme setup, `ExportOptions.plist`, and a minimal CI config block.
- `docs/versioning.md`: `VERSION_MODE` reference, bump flags, xcconfig/Info.plist stamping (`MARKETING_VERSION`, `ENABLE_GAME_MODE`, `APP_CATEGORY`).
- `docs/output.md`: artifact paths, ZIP/DMG options, icon seeding.
- `docs/steam.md`: dylib staging, entitlements, `steam_appid.txt`.
- `docs/troubleshooting.md`: common failure scenarios with concrete fix steps and commands.
- `docs/gotchas.md`: lessons learned about macOS signing and notarization (`--deep` codesign, injected dylibs, Shared scheme requirement, xcconfig regeneration, UAT vs Xcode pipeline, notarization log, Game Mode vs App Sandbox).

### Changed
- `README.md`: rewritten to focus on quick start and pipeline execution order. All configuration and feature detail moved to `docs/`.

---

## [2026-04-12] — Info.plist xcconfig stamping: MARKETING_VERSION + Game Mode (PR #19)

### Added
- `update_xcconfig_versions()`: stamps the UE-generated xcconfig (`Intermediate/ProjectFiles/XcconfigsMac/<project>.xcconfig`) before the Xcode archive step. Only rewrites the specific keys below; everything else in the file is untouched. Skips with an informational message if the xcconfig does not exist yet.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`): written from the resolved version string when `VERSION_MODE != NONE`.
- `MARKETING_VERSION` (`CFBundleShortVersionString`): new config variable and `--marketing-version STRING` CLI flag. Defaults to `1.0.0` with a warning if not explicitly set.
- `ENABLE_GAME_MODE`: new config variable and `--game-mode` / `--no-game-mode` CLI flags. Stamps `INFOPLIST_KEY_LSSupportsGameMode` and `INFOPLIST_KEY_GCSupportsGameMode` (`YES`/`NO`). Defaults to `YES` with a warning if not explicitly set. macOS Game Mode (Sonoma 14+) gives the app elevated CPU/GPU priority when a controller is connected. Both keys are placed immediately after `INFOPLIST_KEY_LSApplicationCategoryType` in the xcconfig.
- `APP_CATEGORY`: new optional config variable and `--app-category STRING` CLI flag. Overrides `INFOPLIST_KEY_LSApplicationCategoryType` in the xcconfig. If unset, the existing value in the file is preserved unchanged. Valid identifiers: https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype
- All new variables appear in `--print-config` output and are documented in `.env.example` and README.

---

## [2026-03-18] — HYBRID version mode + --bump-* flags (PR #18)

### Added
- `VERSION_MODE=HYBRID`: combines a manual base version (`VERSION_STRING`) with the git short hash, producing strings like `1.2.3-a1b2c3d`. Falls back to `VERSION_STRING` alone if no git history.
- `--bump-major`, `--bump-minor`, `--bump-patch`: increment `VERSION_STRING` (from `.env` or a preceding `--version-string`) for the current run without editing any file. Supports `X.Y.Z` and `vX.Y.Z`; preserves the `v` prefix. Implies `VERSION_MODE=MANUAL` if `VERSION_MODE` was `NONE`.
- `bump_semver()` internal helper used by the bump flags.
- `VERSION_STRING` is now shown in `--print-config` output for both `MANUAL` and `HYBRID` modes.
- On a successful build, the bumped `VERSION_STRING` is written back to `.env` (`VERSION_STRING=` line updated in-place if present, otherwise appended). This means the next run automatically continues from the bumped value. No-op when no bump flag was used.
- Documented in README, CHANGELOG, and `.env.example`.

---

## [2026-03-17] — Fix entitlements mktemp + pre-UAT version stamping (PR #17)

### Fixed
- `codesign: cannot read entitlement data` — `mktemp -t` on macOS treats its argument as a plain prefix and appends the random suffix *after* the extension, producing a malformed filename like `…XXXXXX.plist.AbCdEf`. Switched to the full-path form with `XXXXXX` at the end and no extension (codesign does not require `.plist`).

### Changed
- `VERSION_FILE_BUNDLE_PATH` / `--version-file-bundle-path` removed. Replaced by `VERSION_CONTENT_DIR` / `--version-content-dir` (see below).
- `version.txt` is now stamped **before UAT runs** (in `Content/<VERSION_CONTENT_DIR>/`) rather than written into the exported `.app` bundle after the fact. UAT bundles it automatically via the `DirectoriesToAlwaysStageAsNonUFS` project packaging setting, eliminating all manual post-export staging and codesign interaction.
- An `EXIT` trap resets `Content/<VERSION_CONTENT_DIR>/version.txt` back to `dev` after every run — whether the build succeeds, fails, or exits early — so the editor never sees a stamped file.

### Added
- `VERSION_CONTENT_DIR` (default `BuildInfo`): subdirectory under `Content/` where `version.txt` lives. Must stay inside `Content/` so UAT can stage it.
- `--version-content-dir DIR` CLI flag.
- `ensure_game_ini_staging_entry()`: idempotently adds `+DirectoriesToAlwaysStageAsNonUFS=(Path="BuildInfo")` under `[/Script/UnrealEd.ProjectPackagingSettings]` in `DefaultGame.ini` when `VERSION_MODE != NONE`, so teams do not need to configure it manually.

---

## [2026-03-17] — Optional version.txt stamp (PR #16)

### Added
- `VERSION_MODE` (default `NONE`): controls whether a `version.txt` is written into the app bundle before signing. Values: `NONE` (skip), `MANUAL` (literal string), `DATETIME` (auto-generated timestamp + git hash)
- `VERSION_STRING`: the literal version string to write when `VERSION_MODE=MANUAL`
- `VERSION_FILE_BUNDLE_PATH` (default `Contents/version.txt`): path inside the `.app` where the file is written, relative to the app root
- `write_version_file()` helper: called after app discovery, before codesign, so the file is included in the Developer ID signature and notarized artifact
- CLI flags `--version-mode`, `--version-string`, `--version-file-bundle-path`
- `DATETIME` format: `yyyyMMdd-HHmmss-<git-short-hash>` (e.g. `20260317-143022-a1b2c3d`); falls back to `yyyyMMdd-HHmmss` if no git history
- All three new variables shown in `--print-config` output and dry-run pipeline summary
- Documented in README and `.env.example`

---

## [2026-03-05] — Standardize CLI flag paradigm (PR #13)

### Changed
- Boolean CLI flags now use `--flag` / `--no-flag` instead of `--flag 0|1`
- `--enable-steam`, `--enable-zip`, `--enable-dmg` renamed to `--steam`, `--zip`, `--dmg` (with `--no-steam`, `--no-zip`, `--no-dmg`)
- `--use-xcode-export` renamed to `--xcode-export` (with `--no-xcode-export`)
- `--notarize yes|no` replaced by `--notarize` / `--no-notarize`
- `NOTARIZE` env variable no longer accepts `y`/`n` shorthands; only `yes`/`no` (case-insensitive)

---

## [2026-03-05] — macOS app icon seeding (PR #12)

### Added
- `seed_macos_icon_assets_for_workspace`: syncs a source-controlled `.xcassets` catalog into `Intermediate/SourceControlled/Assets.xcassets` and patches every workspace project's `project.pbxproj` to point at it, so the macOS app icon is no longer sourced from the engine-global `Assets.xcassets`
- `first_appiconset_name_in_catalog`: helper that returns the first `*.appiconset` name in a catalog, used to auto-detect the icon set when `MACOS_APPICON_SET_NAME` is unset
- `MACOS_ICON_SYNC` (default `1`): enables/disables icon catalog seeding
- `MACOS_ICON_XCASSETS`: path to the source-controlled `.xcassets` catalog; defaults to `$REPO_ROOT/macOS-SourceControlled.xcassets`
- `MACOS_APPICON_SET_NAME`: explicitly names the `*.appiconset` to use; auto-detected when unset
- CLI flags `--macos-icon-sync`, `--macos-icon-xcassets`, `--macos-appicon-set-name`
- All three new variables shown in `--print-config` output

### Changed
- If `MACOS_ICON_XCASSETS` path does not exist at runtime and was not set explicitly via CLI, the script downgrades to a warning and disables icon seeding rather than hard-failing

---

## [2026-03-05] — polish (PR #11)

### Added
- Block comment at top of `ship.sh` documenting the two-stage FD 3/4 logging architecture
- `ExportOptions.plist.example`: annotated template matching what the script auto-generates interactively
- `.github/workflows/build.yml.example`: annotated GitHub Actions CI starting point for self-hosted macOS UE5 builds (untested — adapt to your runner setup)
- `shellcheck` GitHub Actions workflow (`.github/workflows/shellcheck.yml`)

### Changed
- `.env.example`: added missing `ENTITLEMENTS_FILE` entry (user-configurable since PR #9)
- `README.md`: shellcheck noted as a development requirement in Contributing section

---

## [2026-03-04] — Robustness improvements (PR #10)

### Added
- Pre-flight check: `SIGN_IDENTITY` is verified in the keychain via `security find-identity` before the build starts; a typo or expired cert now fails immediately with a list of available identities
- Pre-flight check: `NOTARY_PROFILE` is verified accessible via `notarytool history` before the build starts when `NOTARIZE=yes`
- `.env` ownership and permission guard: the script refuses to source `.env` if it is owned by a different user or is world-writable
- `codesign --verify` runs immediately after DMG signing so a bad signature fails fast rather than surfacing hours later at notarization

### Changed
- Steam auto-enable now emits `warn` (⚠️) instead of `info` and explicitly names the entitlements being added (`disable-library-validation`, `allow-dyld-environment-variables`)
- `--uproject` argument is fully resolved at parse time: absolute paths set both `UPROJECT_PATH` and `UPROJECT_NAME` immediately; bare filenames set only `UPROJECT_NAME` for later autodetect. Removes the `CLI_SET_UPROJECT` flag and post-parse normalization dance

---

## [2026-03-04] — Cleanup Pass (PR #9)

### Fixed
- Replace all bare `exit N` calls with `die()` so errors consistently trigger `on_error_exit` cleanup and print the log tail
- `ENTITLEMENTS_FILE` temp file now cleaned up in `on_error_exit` (previously leaked into `/tmp` on mid-run failures)
- App is now stapled after DMG-only notarization (`ENABLE_ZIP=0`, `ENABLE_DMG=1`); previously Gatekeeper would block the app on a fresh Mac even after successful notarization
- Replace deprecated `codesign --deep` with per-component signing: all nested `.dylib`/`.so`/`.framework` bundles are signed individually before the outer `.app`, per Apple's distribution guidance
- Remove unreliable "Development" strings heuristic that false-positived on virtually every UE Shipping build; verify build type via `LogInit: Build: Shipping` at runtime instead
- User-provided `ENTITLEMENTS_FILE` is no longer deleted on script exit or error — only script-generated temp files are cleaned up

---

## [2026-02-14] — Rename script (PR #8)

### Changed
- Renamed script from `build_archive_sign_notarize_macos.sh` to `ship.sh`
- Updated `.env.example` and `README.md` references accordingly

---

## [2026-02-08] — DMG support (PR #6)

### Added
- DMG output: `ENABLE_DMG`, `DMG_NAME`, `DMG_VOLUME_NAME`, `DMG_OUTPUT_DIR` config variables
- Experimental "fancy DMG" mode (`FANCY_DMG=1`): Finder layout with drag-to-Applications symlink; disabled by default due to Finder scripting reliability limits
- ZIP + DMG parallel notarization: both artifacts submitted before waiting on either
- Notarization retry/backoff for keychain profile availability (`wait_for_notary_profile_with_backoff`)
- Manual recovery guidance printed to terminal when notary profile check fails
- Dry-run output now reflects all conditional steps based on active flags

### Fixed
- Notarization controls use explicit enable semantics and apply consistently to both ZIP and DMG artifacts
- `on_error_exit` trap now reports failing command context, log path, and tail of recent log lines

### Changed
- Removed script-side `_DEFAULT` override behavior; precedence is now strictly `CLI args > env/.env > auto-detect`
- Log files moved outside `Build/` so they survive `CLEAN_BUILD_DIR=1` wipes

---

## [2026-02-07] — Xcode version detection, bug fixes, sanity checks (PR #5)

### Added
- `check_apple_sdk_json_compat`: validates installed Xcode version against UE's `Apple_SDK.json` (`MinVersion`/`MaxVersion` and `AppleVersionToLLVMVersions` mappings)
- Semver normalization and integer comparison helpers (`normalize_semver_3`, `semver3_to_int`) for toolchain version checks
- Additional pre-flight sanity checks for required tools and paths

### Fixed
- Multiple bug fixes across path resolution and config validation

---

## [2026-02-07] — Xcworkspace generation, ExportOptions.plist auto-detect (PR #4)

### Added
- Interactive Xcode workspace generation via `GenerateProjectFiles.sh` when no `.xcworkspace` is found
- `autodetect_export_plist_if_needed`: scans repo root for `ExportOptions.plist`-like files by content heuristic
- Interactive generation of a minimal `ExportOptions.plist` for Developer ID exports when none is found
- `autodetect_scheme_if_needed`: discovers Xcode schemes from workspace, selects by project name match
- `.env.example` template (renamed from `.env`)
- `PRINT_CONFIG` flag: print resolved configuration and exit without building
- `DRY_RUN` flag: preview the build pipeline without executing

### Changed
- Replaced `__REPLACE_ME__` placeholder pattern with `is_placeholder` (empty string check)
- Improved README with Quick Start and full configuration reference

---

## [2026-02-05] — Version 2: auto-detection, Steam, .env support (PR #3)

### Added
- `.env` file loading from script directory (`set -a` / `. "$ENV_FILE"`)
- Auto-detection of `UE_ROOT` from Epic Games Launcher install paths (`/Users/Shared/Epic Games/UE_*`)
- Auto-detection of `.uproject` file in repo root (single-file heuristic with multi-candidate prompting)
- Auto-detection of short/long names from project name
- Auto-detection of Steam from `DefaultEngine.ini` (`OnlineSubsystemSteam`, `bEnabled`)
- Auto-detection of `libsteam_api.dylib` path from `Steamworks.build.cs` version number
- Steam App ID read from `DefaultEngine.ini` (`SteamDevAppId` / `SteamAppId`)
- `WRITE_STEAM_APPID` flag to control `steam_appid.txt` presence in app bundle
- `DEVELOPMENT_TEAM` auto-detection from `IOSTeamID` in `DefaultEngine.ini`
- ZIP packaging (`ENABLE_ZIP`) and notarization submission flow
- Interactive `read` prompts for `BUILD_TYPE` and `NOTARIZE` when not set via env/CLI
- Full CLI flag parser (`--help` and all config flags)
- `abspath_existing` / `abspath_from` path resolution helpers
- `read_ini_value` INI key parser
- `sanitize_name_for_tmp` for safe `mktemp` templates

### Changed
- Full internal rewrite; config precedence formalized as `CLI > env/.env > auto-detect > defaults`

---

## [2026-02-02] — Initial release (PR #1–#2)

### Added
- First working version of the macOS UE5 build + sign + notarize pipeline
- UAT `BuildCookRun` invocation for Mac Shipping/Development targets
- Xcode archive + Developer ID export via `xcodebuild -exportArchive`
- `codesign` signing with hardened runtime and optional Steam entitlements
- Notarization via `notarytool submit` + `wait` + `xcrun stapler staple`
- Codesign verification (`codesign --verify --deep --strict`) and team ID cross-check
- `README.md` with Quick Start, requirements, and configuration reference
- LLM authorship disclaimer in README
