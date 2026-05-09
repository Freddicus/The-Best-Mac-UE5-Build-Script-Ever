# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are grouped by PR/merge. No semantic versioning — this is a single-file utility script.

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
