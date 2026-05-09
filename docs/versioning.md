# Versioning

The script has two separate versioning concepts that work independently or together:

- **`version.txt`** — a runtime-readable file bundled into your game's `Content/` by UAT
- **Info.plist values** — written through UE's *canonical* override paths (`DefaultEngine.ini`, `Build/Mac/Resources/Info.Template.plist`, `Build/Mac/<Project>.PackageVersionCounter`) so they survive every `GenerateProjectFiles` regeneration without intermediate-file post-processing

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

## Info.plist values via canonical UE overrides

Earlier versions of this script post-processed the UE-generated xcconfig at `Intermediate/ProjectFiles/XcconfigsMac/<project>.xcconfig` to inject Info.plist values. That fought with `GenerateProjectFiles` every regen and put canonical project state in an `Intermediate/` file. The script now routes each value through its sanctioned UE override location, so values are visible to you in committed config and survive every regen.

### Canonical mapping

| Info.plist key | Canonical override location | Reference |
|---|---|---|
| `CFBundleShortVersionString` (`MARKETING_VERSION`) | `Config/DefaultEngine.ini` → `[/Script/MacRuntimeSettings.MacRuntimeSettings]` `VersionInfo=` | `XcodeProject.cs:1997` |
| `LSApplicationCategoryType` | `Config/DefaultEngine.ini` → `[/Script/MacTargetPlatform.XcodeProjectSettings]` `AppCategory=` | `XcodeProject.cs:1982` (defaults to `public.app-category.games` in `BaseEngine.ini`) |
| `LSSupportsGameMode`, `GCSupportsGameMode` | `Build/Mac/Resources/Info.Template.plist` (UE merges this template into the final `Info.plist`) | `BaseEngine.ini:3463` `TemplateMacPlist=` |
| `CFBundleVersion` (`CURRENT_PROJECT_VERSION`) | **Path B (default):** `CFBUNDLE_VERSION` in `.env`, auto pre-incremented every build by the script and persisted on success. Post-export `PlistBuddy` rewrite of `.app/Contents/Info.plist` before codesign. `--set-cfbundle-version N` sets a new baseline.<br>**Path A (opt-in via `USE_UE_PACKAGE_VERSION_COUNTER=1`):** `Build/Mac/<Project>.PackageVersionCounter` (UE auto-increments per build); CL prefix stripped via project-level `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` override (`AppleToolChain.cs:394-397`). | `Engine/Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` |

The script defensively seeds the two non-ini files (`Info.Template.plist`, `PackageVersionCounter`) when they're missing, so a fresh clone bootstraps without any manual setup. Once seeded, **commit them** — they're project state.

### MARKETING_VERSION

```bash
MARKETING_VERSION="1.2.0"
```

CLI: `--marketing-version 1.2.0`

When set, the script writes `VersionInfo=1.2.0` to `Config/DefaultEngine.ini` under `[/Script/MacRuntimeSettings.MacRuntimeSettings]` (creating the section if needed). UE's `XcodeProject.cs::WriteXcconfigFile` reads it and stamps `MARKETING_VERSION` into the generated xcconfig at regen time. The value is therefore visible to you in your committed `DefaultEngine.ini` — not buried in `Intermediate/`.

When unset, the script does **not** touch `DefaultEngine.ini`. UE falls back to the engine display version (e.g. `5.7.0`) — almost certainly not what you want, so set this once.

### APP_CATEGORY

```bash
APP_CATEGORY="public.app-category.games"
```

CLI: `--app-category public.app-category.games`

When set, the script writes `AppCategory=` to `Config/DefaultEngine.ini` under `[/Script/MacTargetPlatform.XcodeProjectSettings]`. **`BaseEngine.ini` already defaults to `public.app-category.games`** for every UE project, so you only need to override if you want a different category (e.g. `public.app-category.action-games`).

Valid identifiers: https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype

### ENABLE_GAME_MODE

macOS Game Mode (Sonoma 14+) gives your app elevated CPU and GPU priority when a game controller is connected. There's no UE ini path for these keys — they live in your Mac `Info.Template.plist`.

```bash
ENABLE_GAME_MODE="1"   # set both LSSupportsGameMode and GCSupportsGameMode to true
ENABLE_GAME_MODE="0"   # set both to false
```

CLI: `--game-mode` / `--no-game-mode`

When set, the script edits `Build/Mac/Resources/Info.Template.plist` via `PlistBuddy` (idempotent — no-op when the key already matches). When unset, the plist's existing GameMode keys (if any) are left alone — your plist is sovereign.

The plist is auto-seeded from the engine's stock template (`$UE_ROOT/Engine/Build/Mac/Resources/Info.Template.plist`) on first run if missing. After that, edit it however you want — it's a regular plist file you own.

### CFBundleVersion: auto-bump by default, opt-in for UE-canonical

`CFBundleVersion` (the integer `Info.plist` build counter) is managed by the script automatically. There are two strategies — Path B is the default and what most projects want; Path A is opt-in for advanced workflows.

| Path | Default? | Source of truth | Format | When to use |
|---|---|---|---|---|
| **B. Auto-bump (default)** | yes | `CFBUNDLE_VERSION` in `.env`, pre-incremented every build by the script | integer (e.g. `1`, `2`, `7`) | You want App-Store-style monotonic integers and zero ceremony — first build ships `1`, every subsequent build ships one more. |
| **A. UE-canonical** | no — opt in via `USE_UE_PACKAGE_VERSION_COUNTER=1` | `Build/Mac/<Project>.PackageVersionCounter`, auto-incremented by UE inside `xcodebuild` | `X.Y` (e.g. `0.2`) | You're integrating with a larger UE pipeline that already relies on `PackageVersionCounter`, or you specifically want UE's `<CL>.<X>.<Y>` format and the changelist semantics it implies. |

The two paths are mutually exclusive. Setting `USE_UE_PACKAGE_VERSION_COUNTER=1` disables the auto-bump and Info.plist override; UE's canonical flow takes over.

> **Relationship to `--bump-major/--bump-minor/--bump-patch`:** these flags bump the *runtime* `VERSION_STRING` (used for `Content/<dir>/version.txt`) — they don't touch `CFBundleVersion`. The two version concepts are intentionally independent: `VERSION_STRING` is a semver string for in-game display; `CFBundleVersion` is an integer build counter for App Store / Gatekeeper.

#### Path B — auto-bump (default behavior)

Every build, the script reads `CFBUNDLE_VERSION` from `.env` (defaulting to `0` if missing), pre-increments by 1, ships that value as `CFBundleVersion`, and persists the new value back to `.env` on a successful build:

```text
.env: CFBUNDLE_VERSION="0"   →  build 1 ships CFBundleVersion=1, .env now CFBUNDLE_VERSION="1"
.env: CFBUNDLE_VERSION="1"   →  build 2 ships CFBundleVersion=2, .env now CFBUNDLE_VERSION="2"
```

If `CFBUNDLE_VERSION` is not present in `.env` at all, the first build still bumps from the default `0` and writes `CFBUNDLE_VERSION="1"` into `.env` on success. No initial setup required.

The persist happens after a fully successful pipeline (notarization + stapling, or earlier success points if notarization is disabled). A failed or interrupted build leaves `.env` untouched, so the next build retries the same number — no wasted build numbers.

##### Setting an explicit baseline

`--set-cfbundle-version N` sets `CFBundleVersion` to exactly `N` for this build *and* persists `N` to `.env`. The next auto-bump build resumes from `N`:

```bash
./ship.sh --set-cfbundle-version 100      # ships 100, .env becomes CFBUNDLE_VERSION="100"
./ship.sh                                  # next build ships 101, .env becomes CFBUNDLE_VERSION="101"
```

Use this to:
- **Reset the counter** after switching strategies (e.g. coming off a CI-managed counter).
- **Pin to a CI value** for a release build:
  ```bash
  ./ship.sh --set-cfbundle-version "$GITHUB_RUN_NUMBER"
  ./ship.sh --set-cfbundle-version "$BUILD_NUMBER"            # Jenkins
  ./ship.sh --set-cfbundle-version "$(cat .release-counter)"  # custom file
  ```
- **Pin to a non-integer value** (auto-bump only handles pure integers; `--set-cfbundle-version 1.2.3` works but disables auto-bump on subsequent runs until you re-set to an integer).

##### Format

`CFBUNDLE_VERSION` accepts any value Apple permits for `CFBundleVersion`: a single integer (`7`), or up to three dot-separated integers (`1.2.3`). Auto-bump only operates on pure integers — for non-integer baselines, manage bumping manually via `--set-cfbundle-version` per release.

For App Store submissions, monotonically increasing is required across builds of the same `CFBundleShortVersionString` (`MARKETING_VERSION`).

##### How it works under the hood

The script `PlistBuddy`-rewrites `<App>.app/Contents/Info.plist`'s `CFBundleVersion` *after* `xcodebuild -exportArchive` produces the bundle but *before* the codesign step. The signature is computed over the modified `Info.plist`, so the bundle stays internally consistent. UE's `PackageVersionCounter` and `UpdateVersionAfterBuild.sh` still run as part of the build, but their value is irrelevant because the post-export rewrite always wins.

#### Path A — UE-canonical (opt-in, advanced)

To opt out of the auto-bump and route `CFBundleVersion` through UE's `PackageVersionCounter` mechanism instead, set `USE_UE_PACKAGE_VERSION_COUNTER=1` (env or `--use-ue-package-version-counter`). The script then:

1. Defensively seeds `Build/Mac/<Project>.PackageVersionCounter` to `0.0` if missing. UE's `UpdateVersionAfterBuild.sh` (invoked by xcodebuild) reads it, increments the minor (`0.0` → `0.1` → …), and writes the value to `Intermediate/Build/Versions.xcconfig`. The generated xcconfig references this as `CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION)`, which Xcode resolves into `CFBundleVersion`.
2. Defensively drops a project-level `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` that strips the engine's `Build.version` Changelist (e.g. `51494982` for an Epic Games Launcher install of 5.7.4). UE's `AppleToolChain.cs:394-397` checks the project for this script first and falls back to the engine's copy if absent — sanctioned override path. With it in place, `CFBundleVersion` becomes the `PackageVersionCounter` contents verbatim (e.g. `0.2`) instead of `51494982.0.2`.
3. Skips the Info.plist override step, so UE's value reaches the shipped bundle untouched.

**Commit `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh`** if you use Path A — every machine and CI runner needs the override.

The format is `X.Y` — two integers separated by a single dot. The engine's increment script splits on `.` and increments index `[1]`, dropping any third component:

```text
1.0.5  →  IFS split → [1, 0, 5]  →  writes back as "1.1"   # third part lost
```

To start at a specific value, edit `Build/Mac/<Project>.PackageVersionCounter` directly — the script never overwrites an existing one. The counter file itself is gitignored per UE convention (alongside `UBTGenerated/` and `FileOpenOrder/`); it's per-checkout state UBT manages.

### Disabling the launch-screen / Info.Template.plist seeds

```bash
SEED_MAC_INFO_TEMPLATE_PLIST="0"
SEED_APPLE_LAUNCHSCREEN_COMPAT="0"
```

CLI: `--no-seed-mac-info-template-plist`, `--no-seed-apple-launchscreen-compat`

Disable when you're managing the files outside the script and don't want a missing-file bootstrap. The Path A files (`Build/Mac/<Project>.PackageVersionCounter` and `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh`) are seeded only when `USE_UE_PACKAGE_VERSION_COUNTER=1` — they share that opt-in flag rather than having individual toggles.
