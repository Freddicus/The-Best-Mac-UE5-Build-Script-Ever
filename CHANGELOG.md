# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are grouped by PR/merge. No semantic versioning — this is a single-file utility script.

---

## [Unreleased] — cleanup-pass (PR #9)

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
