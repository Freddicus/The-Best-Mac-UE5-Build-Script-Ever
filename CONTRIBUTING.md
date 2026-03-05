# Contributing

Thanks for improving `ship.sh`.

## The design philosophy

**`ship.sh` should make distributing a UE5 game feel boring.** You run it, it figures things out, it does the work, it tells you if something is broken. Contributions that fit this spirit are welcome. Contributions that add config knobs for things the script could just detect, or that require the user to know things the script could look up, are not.

Concretely, when adding something new, ask:
- Can this be auto-detected from the project structure? (`.uproject`, `DefaultEngine.ini`, the workspace, etc.) If yes, detect it.
- Can a sensible default cover 90% of users? If yes, make it the default and only expose a flag for the rest.
- Does the user need to do anything manually that the script could do? If yes, make the script do it.

The goal is a pipeline that runs unattended. Prefer inference over configuration. Prefer silent success over verbose confirmation.

## The one rule: shellcheck must pass

The only automated CI check is shellcheck at warning severity:

```bash
shellcheck ship.sh
```

Every PR must pass this cleanly. Run it locally before opening a PR.

## Testing your changes

Real builds require Xcode, an Apple Developer account, and UE5 installed. For most changes, these modes cover you:

```bash
./ship.sh --help          # see all flags
./ship.sh --print-config  # validate config resolution without building
./ship.sh --dry-run       # walk the pipeline steps without executing them
```

Copy `.env.example` to `.env` in your repo root and fill in your values for local testing.

## What a good PR looks like

- **One logical change per PR.** Mixing unrelated changes makes review harder.
- **Update `CHANGELOG.md`.** Add a dated entry under a new `## [YYYY-MM-DD] — Short description (PR #N)` heading. Follow the existing format (Added / Changed / Fixed / Removed).
- **Describe the why.** The PR description should explain the problem being solved, not just what changed.
- **Respect the architecture.** `CLAUDE.md` documents the layout and key design rules (FD 3 discipline, no `--deep` codesign, config precedence). Read it before making structural changes.

## Suggesting changes without code

Open an issue. Bug reports are most useful when they include your macOS version, UE5 version, the flags you passed, and the relevant tail of the log file (`ship_build_*.log`).
