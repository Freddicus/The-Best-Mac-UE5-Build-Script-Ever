# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-file bash script (`ship.sh`, ~5300 lines) that automates UE5 game distribution on Apple platforms. It is not an application; there is nothing to compile or install.

Two independent pipelines run per invocation, selected by `MAC_DISTRIBUTION` (`developer-id` | `app-store` | `off`) and `IOS_DISTRIBUTION` (`app-store` | `off`):

- **Mac Developer ID** — UAT build → Xcode archive → sign → notarize → staple → ZIP/DMG
- **Mac App Store** — UAT build → archive → export `.pkg` → `altool` upload (no notarize/staple)
- **iOS App Store** — UAT build → archive → export `.ipa` → `altool` upload

`--preset` (`steam-mac`, `direct-mac`, `mas-mac`, `ios`, `mac-ios`, `mas-ios`) wires the common combinations; `--list-presets` prints them with their resolved settings.

## Read the docs before reading the script

`docs/` is current and maintained. Check it before deriving behavior from `ship.sh`:

| File | Use when |
|------|----------|
| `pipeline.md` | You need the exact step order for any distribution mode |
| `gotchas.md` | **Before changing signing, entitlements, architectures, or `Build/` layout** |
| `configuration.md` | Any question about a specific variable or flag |
| `versioning.md` | CFBundleVersion / MARKETING_VERSION work (Path A vs Path B) |
| `troubleshooting.md` | Diagnosing a failure mode |
| `output.md` | What lands where (`Build/` vs `Saved/` vs `BuildArtifacts/`) |
| `steam.md` | Steam dylib staging |

## Linting (only automated check in CI)

```bash
shellcheck ship.sh
```

The CI workflow (`.github/workflows/shellcheck.yml`) runs shellcheck at `warning` severity on every push/PR. All changes must pass `shellcheck ship.sh` cleanly before merging.

## Running the script (manual testing only — no unit tests)

```bash
chmod +x ship.sh
./ship.sh --help            # print all CLI flags
./ship.sh --list-presets    # show presets and what each one sets
./ship.sh --print-config    # show resolved config and exit without building
./ship.sh --dry-run         # preview the pipeline without executing
./ship.sh --ios-only        # iOS pipeline only (skips Mac signing pre-flight)
```

Real builds require a macOS machine with Xcode, an Apple Developer account, and a UE5 install. The `.env` file (not committed) provides `DEVELOPMENT_TEAM`, `SIGN_IDENTITY`, etc. Copy `.env.example` or a preset variant (`.env.example.steam-mac`, `.env.example.mas-mac`, …); `.env.example.full` documents every supported variable.

Build logs land in the *target project's* `Saved/Logs/build_YYYY-MM-DD_HH-MM-SS.log`.

## Architecture of ship.sh

The script is one file with a deliberate top-to-bottom layout. Key sections in order:

1. **Logging helpers** (`die`, `warn`, `good`, `info`, `error`) — all write to FD 3 (terminal), not stdout. After log redirection (`exec >>$LOG_FILE 2>&1`), plain `echo` goes to the log file only; FD 3 always reaches the terminal.

2. **`.env` loading** — sourced from the script's own directory with ownership/permission safety checks. Priority: `CLI flags > env/.env > preset > auto-detect > defaults`.

3. **Configuration defaults** — every config variable is set with `${VAR:-}` or `${VAR:-default}`. Do not edit these to set values; use `.env` or CLI flags.

4. **Internal helpers** — path resolution (`abspath_existing`, `abspath_from`), INI parsing (`read_ini_value`), name sanitization, semver helpers, Xcode SDK compat check.

5. **Versioning and canonical-file seeding** — CFBundleVersion auto-bump (Path B default, `USE_UE_PACKAGE_VERSION_COUNTER=1` for UE's Path A), `MARKETING_VERSION`/`APP_CATEGORY` writes into `DefaultEngine.ini`, `Info.Template.plist` and LaunchScreen seeding, AppIcon catalog mirroring. See `docs/versioning.md`.

6. **Entitlements management** — Game Center, Mac App Store sandbox, and Steam entitlements are written into per-platform entitlements plists. Restricted entitlements have signing prerequisites; read `docs/gotchas.md` first.

7. **Auto-detection functions** — discover `.uproject`, `UE_ROOT`, `.xcworkspace` (Mac and iOS), `XCODE_SCHEME`, `ExportOptions.plist` (Developer ID / MAS / iOS variants), Steam settings, ASC credentials, Targeted RHIs, `DEVELOPMENT_TEAM` from `DefaultEngine.ini`.

8. **CLI flag parser** — `while [[ $# -gt 0 ]]; do case "$1"` loop; unknown flags call `die`. ~80 flags.

9. **Presets** — `apply_preset` assigns via `_preset_assign`, which respects `CLI_SET_*` and `PRESET_ENV_LOCK_*` markers so a preset never overrides an explicit CLI flag or `.env` value. Precedence: `CLI > .env > preset > defaults`.

10. **Distribution resolution** — `resolve_distribution_flags` and `validate_distribution_compatibility` settle the Mac/iOS dispatcher and reject incompatible combinations before any work starts.

11. **Config resolution** — runs all auto-detect functions, validates required fields, prints config if `PRINT_CONFIG=1`.

12. **Pre-flight checks** — verifies signing identity in keychain, notary profile accessible, UAT paths exist, tools available, Mac shader platform targeting is coherent. These run *before* the multi-hour build so failures surface immediately.

13. **Build pipeline** — shared setup, then the Mac pipeline, then the iOS pipeline. See `docs/pipeline.md` for the authoritative step order; do not reconstruct it from the script.

## Key design rules

- **Never use `--deep` codesign.** Sign nested `.dylib`/`.so`/`.framework` components individually first, then sign the outer `.app`. The script uses a `find`-based loop for this.
- **All errors go through `die()`**, which triggers `on_error_exit` for cleanup (temp entitlements file, DMG staging dirs) and log tail printing.
- **Steam entitlements** (`disable-library-validation`, `allow-dyld-environment-variables`) are only added when `ENABLE_STEAM=1`. Do not add them unconditionally.
- **FD 3 discipline**: status lines visible to the user use `>&3`. Build command output goes to the log file via redirected stdout/stderr. Helper functions always write to FD 3.
- **Config precedence is strict**: `CLI > .env/env > preset > auto-detect > script defaults`. No value is ever read from the script body itself after the defaults block.

## Conventions for changes

- **Prefer inference over configuration.** If a value can be auto-detected from `.uproject`, `DefaultEngine.ini`, or the workspace, detect it — do not add a flag. A new knob needs a reason the script cannot look the value up itself. The goal is a pipeline that runs unattended.

- **Every PR updates `CHANGELOG.md`.** Add a new `## [YYYY-MM-DD] — Short description` heading (a trailing `(PR #N)` is common but not universal in recent entries), followed by a short prose paragraph explaining *why*, then Keep-a-Changelog groups — `### Added` / `### Changed` / `### Fixed` / `### Removed`, plus `### Notes`, `### Docs`, or `### Migration` as needed. Newest entry goes at the top, separated by `---`. No semantic versioning.

- **One logical change per PR**, and `shellcheck ship.sh` must pass clean.

## Files

- `ship.sh` — the entire implementation (~5300 lines)
- `docs/` — maintained reference; see the table above
- `ExportOptions.plist.example` — Developer ID export template; copy to `ExportOptions.plist` in the target repo root
- `MAS-ExportOptions.plist.example` / `iOS-ExportOptions.plist.example` — App Store variants
- `.env.example`, `.env.example.full`, and six preset variants (`.steam-mac`, `.direct-mac`, `.mas-mac`, `.ios`, `.mac-ios`, `.mas-ios`)
- `CONTRIBUTING.md` — design philosophy and PR expectations
- `CHANGELOG.md` — tracks all changes by PR; no semantic versioning
- `.github/workflows/shellcheck.yml` — CI lint
- `.github/workflows/build.yml.example` — untested self-hosted CI reference (not run in CI)
