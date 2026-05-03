# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are grouped by PR/merge. No semantic versioning — this is a single-file utility script.

---

## [2026-04-23] — iOS build pipeline: UAT → archive → IPA → App Store Connect (PR #21)

### Added
- `ENABLE_IOS=1` / `--ios`: optional iOS build pass that runs after the Mac pipeline. Produces an IPA via UAT BuildCookRun → `xcodebuild archive` (destination `generic/platform=iOS`) → `xcodebuild -exportArchive`.
- `IOS_ONLY=1` / `--ios-only`: skip the entire Mac pipeline (UAT, signing, ZIP, DMG, notarization) and run only the iOS steps.
- iOS workspace auto-detection: looks for `<ProjectName> (iOS).xcworkspace` by convention first, then falls back to a `find`-based scan. UE generates both Mac and iOS workspaces together via `GenerateProjectFiles.sh` when iOS support is enabled in the Epic Games Launcher.
- iOS scheme auto-detection: inferred from the Mac scheme when already resolved, otherwise detected via `xcodebuild -list` with the same name-match logic as the Mac path.
- iOS `ExportOptions.plist` auto-detection (conventional name `iOS-ExportOptions.plist`, content-scan for `app-store-connect` / `release-testing` methods) and interactive generation when not found.
- `IOS_WORKSPACE` / `--ios-workspace`: override the detected iOS workspace path.
- `IOS_SCHEME` / `--ios-scheme`: override the detected iOS scheme name.
- `IOS_EXPORT_PLIST` / `--ios-export-plist`: path to the iOS `ExportOptions.plist`.
- `IOS_ICON_SYNC=1` / `--ios-icon-sync`: seeds icon assets from `IOS_ICON_XCASSETS` (default: `iOS-SourceControlled.xcassets`) into the iOS workspace before archiving, mirroring the macOS icon sync behavior.
- `IOS_ICON_XCASSETS` / `--ios-icon-xcassets`, `IOS_APPICON_SET_NAME` / `--ios-appicon-set-name`: control the source catalog and appiconset name for iOS icon seeding.
- `IOS_MARKETING_VERSION` / `--ios-marketing-version`: iOS-specific `CFBundleShortVersionString`. Falls back to `MARKETING_VERSION`, then `1.0.0`.
- `update_ios_xcconfig_versions()`: stamps `Intermediate/ProjectFiles/XcconfigsIOS/<project>.xcconfig` with `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Leading `v` prefix is stripped automatically with a terminal warning — App Store Connect requires `CFBundleVersion` to be purely numeric.
- `IOS_ASC_VALIDATE=1` / `--ios-validate-ipa`: validates the IPA against App Store Connect (`xcrun altool --validate-app`) after export. Equivalent to Xcode's "Validate App" button — catches bundle ID mismatches, entitlement rejections, and missing privacy strings before committing to an upload.
- `IOS_ASC_UPLOAD=1` / `--ios-upload-ipa`: uploads the IPA to App Store Connect (`xcrun altool --upload-app`). Implies `--ios-validate-ipa`. From there, mark as internal or external TestFlight, or submit for App Review, in the App Store Connect UI.
- `IOS_ASC_API_KEY_ID`, `IOS_ASC_API_ISSUER`, `IOS_ASC_API_KEY_PATH` / `--ios-asc-api-key-id`, `--ios-asc-api-issuer`, `--ios-asc-api-key-path`: App Store Connect API credentials. Auto-detected from `Config/DefaultEngine.ini` keys `AppStoreConnectKeyID`, `AppStoreConnectIssuerID`, `AppStoreConnectKeyPath` — the same values Xcode stores when you configure ASC in Xcode → project → Signing & Capabilities.
- `iOS-ExportOptions.plist.example`: annotated template for iOS distribution plists.

### Changed
- Mac xcconfig stamping (`update_xcconfig_versions`) is skipped when `--ios-only` is active — only the iOS xcconfig is stamped.

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
