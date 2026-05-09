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
| `CFBundleVersion` (`CURRENT_PROJECT_VERSION`) | **Path A:** `Build/Mac/<Project>.PackageVersionCounter` (UE auto-increments per build); CL prefix stripped via project-level `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` override (`AppleToolChain.cs:394-397`).<br>**Path B:** `CFBUNDLE_VERSION` env var / `--cfbundle-version N` CLI flag (post-export `PlistBuddy` rewrite of `.app/Contents/Info.plist` before codesign). | `Engine/Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` |

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

### CFBundleVersion: two paths, pick one

There are two ways to control `CFBundleVersion`. They're complementary, not competing — pick whichever fits your workflow:

| Path | Format | Source of truth | When to use |
|---|---|---|---|
| **A. UE-canonical (default)** | `X.Y` (e.g. `0.2`) | `Build/Mac/<Project>.PackageVersionCounter`, auto-incremented by UE every build | You want UE to manage build numbers, with no CI plumbing. Auto-increments per local build. |
| **B. Direct override** | Anything (`7`, `42`, `1.2.3`) | `CFBUNDLE_VERSION` env var or `--cfbundle-version N` CLI flag | You want App-Store-style explicit control, typically driven by CI (`$GITHUB_RUN_NUMBER`, Jenkins build number, internal release counter). |

If `CFBUNDLE_VERSION` is set, path B wins (post-export `PlistBuddy` rewrites the `.app`'s `Info.plist` before signing). If unset, path A applies (UE's canonical flow with our CL-stripping override).

#### Path A — UE-canonical (auto-incrementing, no CL prefix)

`CFBundleVersion` is driven by UE's canonical mechanism: `Build/Mac/<Project>.PackageVersionCounter`. UE's `UpdateVersionAfterBuild.sh` (invoked by xcodebuild) reads it, increments the minor (`0.0` → `0.1` → `0.2` …), and writes the value to `Intermediate/Build/Versions.xcconfig`. The generated xcconfig references this as `CURRENT_PROJECT_VERSION = $(UE_MAC_BUILD_VERSION)`, which Xcode resolves into `CFBundleVersion` in the final `Info.plist`.

The script seeds the counter to `0.0` if missing, so the first build ships `CFBundleVersion=0.1`.

#### Stripping the engine changelist prefix

By default the engine's `UpdateVersionAfterBuild.sh` writes `UE_MAC_BUILD_VERSION = <CL>.<MAC_VERSION>` where `<CL>` comes from `Engine/Build/Build.version`'s `Changelist` field. For an Epic Games Launcher install of 5.7.4 that's `51494982`, so projects ship `CFBundleVersion=51494982.0.2` — almost never what you want.

The script defensively drops a project-level `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` that omits the `<CL>.` prefix. UE's `AppleToolChain.cs:394-397` explicitly checks the project for this script and falls back to the engine's copy only if absent — this is the sanctioned override path. With it in place, `CFBundleVersion` becomes the `PackageVersionCounter` contents verbatim (e.g. `0.2`).

**Commit `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh`** so every machine and CI runner gets the same behavior. Disable the seed (and accept the engine's CL prefix) with `SEED_MAC_UPDATE_VERSION_AFTER_BUILD=0` or `--no-seed-mac-update-version-after-build`.

#### Customizing the starting value

To start at a specific value, edit the counter file directly — the script never overwrites an existing one.

```bash
echo "1.41" > Build/Mac/MyGame.PackageVersionCounter   # next build: increments to 1.42 → CFBundleVersion=1.42
```

#### Format constraints

The format is `X.Y` — two integers separated by a single dot. The engine's increment script (which our override mirrors) splits on `.` and increments index `[1]`, dropping any third component:

```text
1.0.5  →  IFS split → [1, 0, 5]  →  writes back as "1.1"   # third part lost
```

If you want a single-integer-style `CFBundleVersion` (e.g. App Store style: `1`, `2`, `3`…), use `0.N` and let `N` auto-increment. Apple accepts 1, 2, or 3 dot-separated integers — `0.2` is valid.

#### Should `PackageVersionCounter` be committed?

**No.** Per UE convention, `Build/{Platform}/*.PackageVersionCounter` is gitignored — it's per-checkout state that UBT writes during builds (alongside `Build/{Platform}/UBTGenerated/` and `Build/{Platform}/FileOpenOrder/`). UE auto-creates and increments it; our seed just bootstraps a clean starting point so the first build ships `0.1` instead of `0.2`. To enforce a consistent starting point across machines, set the seed value via env var or commit a different mechanism.

The `Build/BatchFiles/Mac/UpdateVersionAfterBuild.sh` override **is** committed — it's a project-level script your build infrastructure depends on.

#### Path B — Direct override (`CFBUNDLE_VERSION`)

For App-Store-style monotonic integers (e.g. Psychonauts 2 ships `CFBundleVersion=7`), set `CFBUNDLE_VERSION` to your desired exact value:

```bash
CFBUNDLE_VERSION="7"
```

CLI: `--cfbundle-version 7`

When set, the script rewrites `<App>.app/Contents/Info.plist`'s `CFBundleVersion` via `PlistBuddy` *after* `xcodebuild -exportArchive` produces the bundle but *before* the codesign step. The signature is computed over the modified `Info.plist`, so the bundle stays internally consistent. UE's `PackageVersionCounter` and `UpdateVersionAfterBuild.sh` still run as part of the build, but their value is overwritten by this final pass.

This is what AAA UE studios typically do when shipping. CI systems supply the value:

```bash
# GitHub Actions
./ship.sh --cfbundle-version "$GITHUB_RUN_NUMBER"

# Jenkins
./ship.sh --cfbundle-version "$BUILD_NUMBER"

# Manual release counter committed to a file
./ship.sh --cfbundle-version "$(cat .release-counter)"
```

`CFBUNDLE_VERSION` accepts any value Apple permits for `CFBundleVersion`: a single integer (`7`), or up to three dot-separated integers (`1.2.3`). For App Store submissions, monotonically increasing is required across builds of the same `CFBundleShortVersionString`.

Path A and Path B are mutually exclusive at the bundle level — when both are configured, Path B wins (because the post-export rewrite happens last). Setting `CFBUNDLE_VERSION` makes the `PackageVersionCounter` increment effectively cosmetic for that build.

### Disabling the seeds

```bash
SEED_MAC_INFO_TEMPLATE_PLIST="0"
SEED_MAC_PACKAGE_VERSION_COUNTER="0"
SEED_MAC_UPDATE_VERSION_AFTER_BUILD="0"
```

CLI: `--no-seed-mac-info-template-plist`, `--no-seed-mac-package-version-counter`, `--no-seed-mac-update-version-after-build`

Disable when you're managing the files outside the script and don't want a missing-file bootstrap.
