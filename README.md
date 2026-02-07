**About this README**  
> This README and shell script were written with the help of a large language model, and it represents the *end result* of many back‑and‑forths, dead ends, and genuine frustration while trying to ship a signed and notarized macOS Unreal build.  
> 
> I’m sharing it because getting all of this right was *hard enough* that it felt irresponsible not to document it once it finally worked.

# The Best Mac Unreal Build Script Ever™ (Archive / Sign / Notarize)

A pragmatic bash script for building a macOS **Developer ID** distributable from an Unreal Engine project, with optional notarization and optional Steam runtime tweaks.

In many cases, the “easy mode” is:
- drop this script into your project root
- create a `.env` next to it
- set your Team ID + signing identity (an ExportOptions.plist can be provided or generated automatically)
- run it

This exists because: **shipping macOS builds is not “just click Package”** — especially once you care about hardened runtime, notarization, and making a build that works on a different Mac.

## What this script does

1. **Build + Cook + Stage + Package** the project using Unreal Automation Tool (`RunUAT.sh BuildCookRun`).
2. **Locate or generate an Xcode workspace**, then create an Xcode archive (`.xcarchive`) using `xcodebuild archive`.
3. **Export a signed `.app`** using `xcodebuild -exportArchive` + your `ExportOptions.plist`.
4. Optionally:
   - **Notarize** the exported app (zip → `notarytool submit` → wait).
   - **Staple** the notarization ticket to the app.
5. Validates signatures and runtime assumptions (`codesign` verification, `otool` check, team identifiers).
6. Optionally (if enabled):
   - Stages and signs `libsteam_api.dylib` alongside the executable.
   - Writes/removes `steam_appid.txt` for local non-launcher testing.
   - Adds entitlements commonly needed for Steam overlay / client-injected libs.

The script logs everything to a timestamped file under `Logs/`, while still printing human-friendly status lines to your terminal.

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

### Xcode workspace handling (.xcworkspace)

This script **does not require you to manually manage your Xcode workspace in advance**.

When Xcode export is enabled:

- If **exactly one** `.xcworkspace` is found, it is used automatically.
- If **multiple** workspaces are found, you’ll be prompted to choose one (interactive shells only).
- If **no workspace** is found, the script will offer to **generate it on the fly** using Unreal’s
  `GenerateProjectFiles.sh`.

In non-interactive contexts (CI), the script will fail with a clear error if it cannot uniquely determine which workspace to use.

If you ever want to generate or regenerate the workspace manually, this is the underlying command:

```bash
UE_ROOT="/Users/Shared/Epic Games/UE_5.x"   # change this
SCRIPTS="$UE_ROOT/Engine/Build/BatchFiles"

"$SCRIPTS/Mac/GenerateProjectFiles.sh" \
  -project="<path_to_project>/<project_file>.uproject" \
  -game
```

This will create (or refresh) a `.xcworkspace` next to your `.uproject`.  
If your workspace or scheme cannot be resolved automatically, the script will guide you interactively or fail with a clear message explaining what needs to be set explicitly.

- Apple Developer account with:
  - Team ID
  - Developer ID Application certificate installed in Keychain
- If notarizing:
  - `notarytool` credentials stored in Keychain (`xcrun notarytool store-credentials ...`)

## Quick Start

1. **Copy the script** into your project root (the folder that contains the `.uproject`).
2. Recommended: create a `.env` file next to the script and set your values there.
   - You generally should **not** need to edit the script itself.
   - You do **not** need to pre-generate an Xcode workspace; the script will locate or generate one if needed.
3. Run:

```bash
chmod +x build_archive_sign_notarize_macos.sh
./build_archive_sign_notarize_macos.sh
```

You’ll be prompted for:
- build type: Shipping or Development
- whether to notarize

## Configuration

Recommended: use a `.env` file (no script edits)

Create a file named `.env` next to the script. It’s sourced as shell code, so only use a `.env` you trust.

Minimum you’ll usually need:
```bash
DEVELOPMENT_TEAM="ABCDE12345"
SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"

# If using Xcode export (default), point at an ExportOptions.plist
EXPORT_PLIST="$PWD/ExportOptions.plist"

# If notarizing, provide your notarytool profile name
NOTARY_PROFILE="MyNotaryProfileName"
```


The script automatically loads `.env` if it exists in the same folder as the script.

If `EXPORT_PLIST` is not provided and no suitable ExportOptions.plist is found, the script will offer to
**generate a minimal ExportOptions.plist interactively** (Developer ID export) using your configured Team ID.

In CI or other non-interactive contexts, you must provide `EXPORT_PLIST` explicitly.

You can still use environment variables (no file edits)

Example:
```bash
export REPO_ROOT="/Users/you/Documents/Unreal Projects/MyGame"
export UPROJECT_NAME="MyGame.uproject"
export UE_ROOT="/Users/Shared/Epic Games/UE_5.x"   # optional; the script can auto-detect common EGL installs
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

Set these via `.env`, environment variables, or CLI flags:

```bash
# BUILD_TYPE_OVERRIDE="shipping"      # "shipping" or "development"
# NOTARIZE_OVERRIDE="yes"             # "yes" or "no"
```

### About the Xcode scheme (and why it matters)

The script will attempt to auto-detect a reasonable default scheme, and will prompt you to choose one if multiple viable schemes exist. In CI or non-interactive runs, you must specify `XCODE_SCHEME` explicitly.

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
- `Logs/build_YYYY-MM-DD_HH-MM-SS.log` — full build log

## Troubleshooting checklist
- **Missing configuration:** if the script stops immediately, a required value (such as `DEVELOPMENT_TEAM` or
  `SIGN_IDENTITY`) was not provided via `.env`, environment variable, or CLI flag.
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
