> **About this README**  
> This README and shell script were written with the help of a large language model, and it represents the *end result* of many back‑and‑forths, dead ends, and genuine frustration while trying to ship a signed and notarized macOS Unreal build.  
> 
> I’m sharing it because getting all of this right was *hard enough* that it felt irresponsible not to document it once it finally worked.

# The Best Mac Unreal Build Script Ever™ (Archive / Sign / Notarize)

A pragmatic bash script for building a macOS **Developer ID** distributable from an Unreal Engine project, with optional notarization and optional Steam runtime tweaks.

This exists because: **shipping macOS builds is not “just click Package”** — especially once you care about hardened runtime, notarization, and making a build that works on a different Mac.

## What this script does

1. **Build + Cook + Stage + Package** the project using Unreal Automation Tool (`RunUAT.sh BuildCookRun`).
2. **Create an Xcode archive** (`.xcarchive`) using `xcodebuild archive`.
3. **Export a signed `.app`** using `xcodebuild -exportArchive` + your `ExportOptions.plist`.
4. Optionally:
   - **Notarize** the exported app (zip → `notarytool submit` → wait).
   - **Staple** the notarization ticket to the app.
5. Validates signatures and runtime assumptions (`codesign` verification, `otool` check, team identifiers).
6. Optionally (if enabled):
   - Stages and signs `libsteam_api.dylib` alongside the executable.
   - Writes/removes `steam_appid.txt` for local non-launcher testing.
   - Adds entitlements commonly needed for Steam overlay / client-injected libs.

The script logs everything to a timestamped file under `Logs/script-logs/`, while still printing human-friendly status lines to your terminal.

## Why this is necessary (macOS reality check)

macOS distribution for apps outside the App Store typically requires:

- **Developer ID signing**
- **Hardened Runtime**
- **Notarization**
- **Stapling** (optional but strongly recommended)
- Testing on a machine that didn’t build it (Gatekeeper / quarantine behavior)

Unreal can produce a packaged `.app`, but the moment you care about:
- consistent signing,
- correct entitlements,
- notarization automation,
- and reproducible builds,

…you end up writing glue around `UAT`, `xcodebuild`, `codesign`, and `notarytool`.

This script is that glue.

## Requirements

- macOS
- Xcode installed (and Command Line Tools)
- Unreal Engine installed (any UE5.x — you configure the path)

### Generating the Xcode workspace (.xcworkspace)

This script assumes you already have an Xcode workspace generated for your Unreal project.
Unreal does **not** automatically keep this up to date, and it will not exist at all unless you generate it.

A simple, reliable way to generate (or regenerate) it on macOS is:

```bash
#!/usr/bin/env bash
SCRIPTS="/Users/Shared/Epic Games/UE_5.7/Engine/Build/BatchFiles"

"$SCRIPTS/Mac/GenerateProjectFiles.sh" \
    -project="<path_to_project>/<project_file>.uproject" \
    -game
```

This will create (or refresh) a `.xcworkspace` next to your `.uproject`.  
If your workspace is missing, stale, or Xcode can’t find your scheme, regenerate it before debugging anything else.

- Apple Developer account with:
  - Team ID
  - Developer ID Application certificate installed in Keychain
- If notarizing:
  - `notarytool` credentials stored in Keychain (`xcrun notarytool store-credentials ...`)

## Quick Start

1. **Copy the script** into your project tooling folder.
2. Open it and replace all `__REPLACE_ME__` placeholders in the **USER CONFIG** section.
3. Run:

```bash
chmod +x build_archive_sign_notarize_macos.sh
./build_archive_sign_notarize_macos.sh
```

You’ll be prompted for:
- build type: Shipping or Development
- whether to notarize

## Configuration

> **Naming note:** While macOS supports spaces in paths and filenames, they can complicate shell scripts and CI pipelines.  This script supports spaces but will emit warnings. If you are early in a project, consider using space-free names for `SHORT_NAME`, `LONG_NAME`, and your Xcode scheme.

Recommended: use environment variables (no file edits)

Example:
```bash
export REPO_ROOT="/Users/you/Documents/Unreal Projects/MyGame"
export UPROJECT_NAME="MyGame.uproject"
export UE_ROOT="/Users/Shared/Epic Games/UE_5.6"
export XCODE_WORKSPACE="MyGame (Mac).xcworkspace"
export XCODE_SCHEME="MyGame"
export DEVELOPMENT_TEAM="ABCDE12345"
export SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"
export EXPORT_PLIST="/Users/you/MyGame/ExportOptions.plist"
export NOTARY_PROFILE="MyNotaryProfileName"
export SHORT_NAME="MyGame"
export LONG_NAME="MyGameFullName"

./build_archive_sign_notarize_macos.sh
```

Optional: skip prompts (CI-friendly)

Uncomment and set these in the script:

```bash
# BUILD_TYPE_OVERRIDE="shipping"      # "shipping" or "development"
# NOTARIZE_OVERRIDE="yes"             # "yes" or "no"
```

### About the Xcode scheme (and why it matters)

The `XCODE_SCHEME` is the glue between Unreal’s generated Xcode project and the command‑line `xcodebuild` steps this script runs.

A few important details:

- The scheme **must exist** inside the `.xcworkspace`.
- The scheme **must be marked as Shared** in Xcode, or `xcodebuild` will not be able to see it.
- Unreal usually names the scheme after your project, but this is not guaranteed if you’ve renamed things over time.

If you’re unsure:

1. Open the `.xcworkspace` in Xcode.
2. Go to **Product → Scheme → Manage Schemes…**
3. Confirm the scheme you expect exists and that **Shared** is checked.

If `xcodebuild -list -workspace YourProject.xcworkspace` does not list your scheme, the script *cannot* archive your build.

## Optional Steam support

**This script does not assume Steam.**  
Steam support is *off by default.*

To enable:
```bash
export ENABLE_STEAM="1"
export STEAM_DYLIB_SRC="/path/to/libsteam_api.dylib"
```

Optional:
```bash
export WRITE_STEAM_APPID="1"
export STEAM_APP_ID="480"   # testing
```

### Notes on Steam entitlements

Some launcher/overlay setups (Steam being the famous one) may require:
- disabling library validation
- allowing dyld environment variables

This script only adds those entitlements when `ENABLE_STEAM=1`, because they are **not something you want enabled casually.**

If you don’t need Steam/launcher-injected libraries: keep `ENABLE_STEAM=0`.

## Output

Artifacts go under (names derived from `SHORT_NAME` / `LONG_NAME`):

- `Build/${SHORT_NAME}.xcarchive` — Xcode archive
- `Build/${SHORT_NAME}-export/*.app` — exported app
- `Build/${LONG_NAME}.zip` — zip used for notarization (name is cosmetic)
- `Logs/script-logs/build_YYYY-MM-DD_HH-MM-SS.log` — full build log

## Troubleshooting checklist
- **Placeholders:** if the script stops immediately, you probably left `__REPLACE_ME__` somewhere.
- **Xcode scheme not found:** the scheme must be Shared in Xcode. (seen by `xcodebuild -list -workspace ...`)
- **RunUAT.sh not found:** double check `UE_ROOT`.
- **Notarization fails:** ensure your `NOTARY_PROFILE` exists and is valid:
  - `xcrun notarytool history --keychain-profile "NAME"`
- **Gatekeeper blocks it** on a test Mac:
  - confirm notarization succeeded and stapling occurred
  - verify with: `spctl -a -vv /path/to/App.app`

## What we learned building this

- Unreal packaging is only the start; macOS distribution is a separate pipeline.
- “It runs on my machine” is meaningless unless you test:
  - on a separate Mac or a clean user account
  - with Gatekeeper and quarantine behavior intact
- Hardened runtime + external/injected dylibs is where pain lives.
- A script like this makes builds reproducible and reduces “ritual knowledge.”
