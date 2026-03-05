# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-file bash script (`ship.sh`) that automates the macOS UE5 game distribution pipeline: UAT build → Xcode archive → Developer ID sign → notarize → staple. It is not an application; there is nothing to compile or install.

## Linting (only automated check in CI)

```bash
shellcheck ship.sh
```

The CI workflow (`.github/workflows/shellcheck.yml`) runs shellcheck at `warning` severity on every push/PR. All changes must pass `shellcheck ship.sh` cleanly before merging.

## Running the script (manual testing only — no unit tests)

```bash
chmod +x ship.sh
./ship.sh --help          # print all CLI flags
./ship.sh --print-config    # show resolved config and exit without building
./ship.sh --dry-run         # preview the pipeline without executing
```

Real builds require a macOS machine with Xcode, an Apple Developer account, and a UE5 install. The `.env` file (not committed) provides `DEVELOPMENT_TEAM`, `SIGN_IDENTITY`, etc.

## Architecture of ship.sh

The script is one file with a deliberate top-to-bottom layout. Key sections in order:

1. **Logging helpers** (`die`, `warn`, `good`, `info`, `error`) — all write to FD 3 (terminal), not stdout. After log redirection (`exec >>$LOG_FILE 2>&1`), plain `echo` goes to the log file only; FD 3 always reaches the terminal.

2. **`.env` loading** — sourced from the script's own directory with ownership/permission safety checks. Priority: `CLI flags > env/.env > auto-detect > defaults`.

3. **Configuration defaults** — every config variable is set with `${VAR:-}` or `${VAR:-default}`. Do not edit these to set values; use `.env` or CLI flags.

4. **Internal helpers** — path resolution (`abspath_existing`, `abspath_from`), INI parsing (`read_ini_value`), name sanitization, semver helpers, Xcode SDK compat check.

5. **Auto-detection functions** — discover `.uproject`, `UE_ROOT`, `.xcworkspace`, `XCODE_SCHEME`, `ExportOptions.plist`, Steam settings, `DEVELOPMENT_TEAM` from `DefaultEngine.ini`.

6. **CLI flag parser** — `while [[ $# -gt 0 ]]; do case "$1"` loop; unknown flags call `die`.

7. **Config resolution** — runs all auto-detect functions, validates required fields, prints config if `PRINT_CONFIG=1`.

8. **Pre-flight checks** — verifies signing identity in keychain, notary profile accessible, UAT paths exist, tools available. These run *before* the multi-hour build so failures surface immediately.

9. **Build pipeline** — sequential: UAT BuildCookRun → optional icon seeding → Xcode archive → Xcode export → per-component codesign → optional Steam dylib → ZIP/DMG creation → notarization (ZIP and DMG submitted in parallel before waiting) → stapling.

## Key design rules

- **Never use `--deep` codesign.** Sign nested `.dylib`/`.so`/`.framework` components individually first, then sign the outer `.app`. The script uses a `find`-based loop for this.
- **All errors go through `die()`**, which triggers `on_error_exit` for cleanup (temp entitlements file, DMG staging dirs) and log tail printing.
- **Steam entitlements** (`disable-library-validation`, `allow-dyld-environment-variables`) are only added when `ENABLE_STEAM=1`. Do not add them unconditionally.
- **FD 3 discipline**: status lines visible to the user use `>&3`. Build command output goes to the log file via redirected stdout/stderr. Helper functions always write to FD 3.
- **Config precedence is strict**: `CLI > .env/env > auto-detect > script defaults`. No value is ever read from the script body itself after the defaults block.

## Files

- `ship.sh` — the entire implementation (~1800 lines)
- `ExportOptions.plist.example` — annotated template; copy to `ExportOptions.plist` in the target repo root
- `.github/workflows/shellcheck.yml` — CI lint
- `.github/workflows/build.yml.example` — untested self-hosted CI reference (not run in CI)
- `CHANGELOG.md` — tracks all changes by PR; no semantic versioning
