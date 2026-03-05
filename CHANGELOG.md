# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are grouped by PR/merge. No semantic versioning — this is a single-file utility script.

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
