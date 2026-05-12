# Troubleshooting

## The script stops immediately with a missing config error

A required value wasn't provided. The most common missing values:

- `DEVELOPMENT_TEAM` — your 10-character Apple Team ID
- `SIGN_IDENTITY` — must match a certificate installed in your Keychain exactly
- `NOTARY_PROFILE` — required if `NOTARIZE=yes`; created with `xcrun notarytool store-credentials`

Run `./ship.sh --print-config` to see all resolved values before building.

## Xcode scheme not found

`xcodebuild` can only see schemes that are marked **Shared** in Xcode.

1. Open the `.xcworkspace` in Xcode.
2. Go to **Product → Scheme → Manage Schemes…**
3. Confirm your scheme is listed and **Shared** is checked.

Verify from the command line:
```bash
xcodebuild -list -workspace YourGame\ \(Mac\).xcworkspace
```

If your scheme doesn't appear there, the script can't archive. You may also need to regenerate the workspace after renaming the project.

## RunUAT.sh not found

The script couldn't locate your UE install. Set `UE_ROOT` explicitly:

```bash
UE_ROOT="/Users/Shared/Epic Games/UE_5.x"
```

Check that the path is correct and that `Engine/Build/BatchFiles/RunUAT.sh` exists under it.

## Notarization fails

First, confirm your profile is valid:

```bash
xcrun notarytool history --keychain-profile "MyNotaryProfile"
```

If this command fails or returns an auth error, re-run `xcrun notarytool store-credentials` to recreate the profile.

If the submission is accepted but Apple rejects it, check the notarization log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "MyNotaryProfile"
```

Common rejection reasons:
- Unsigned or incorrectly signed binaries inside the bundle (nested dylibs, frameworks)
- Missing hardened runtime entitlement
- Entitlements present in the plist that aren't justified by usage

## Gatekeeper blocks the app on a test Mac

This means either notarization didn't succeed or stapling didn't happen. Check:

```bash
spctl -a -vv /path/to/MyGame.app
xcrun stapler validate /path/to/MyGame.app
```

If stapling failed, the app will still pass Gatekeeper with an internet connection (Apple's OCSP check), but will be blocked offline. Stapling embeds the ticket so it works without a network connection.

Also confirm the test Mac is running the app after removing the quarantine attribute from a normal download (i.e. actually downloaded via browser or copied from a DMG, not just copied from your build machine). Developer machines often bypass Gatekeeper checks.

## Codesign verification fails

After a successful build, verify the signing chain manually:

```bash
codesign -dvvv /path/to/MyGame.app
codesign --verify --deep --strict /path/to/MyGame.app
```

If you see errors about nested components, one or more dylibs/frameworks inside the bundle weren't signed correctly. The script signs them individually via a `find` loop — check the build log for any `codesign` errors during that step.

## I added a file to `Build/{Platform}/Resources/` but the build still uses the engine default

Most commonly seen with a custom `LaunchScreen.storyboard` or app icon catalog: you commit the file, run a build, and the launch screen is still the Unreal default.

The cause is that UBT freezes resolved paths into the generated `.xcodeproj` at project-file-generation time, not at build time. Adding a new sibling under `Build/{Platform}/Resources/` doesn't flow into the build until project files are regenerated. The script runs `GenerateProjectFiles.sh` automatically every ship invocation by default — confirm that step actually ran:

```bash
./ship.sh --print-config | grep REGEN_PROJECT_FILES
```

If it shows `0`, re-run with `--regen-project-files` (or remove `REGEN_PROJECT_FILES=0` from your `.env`). If it shows `1` and the resource still isn't picked up, regenerate manually and check the resulting pbxproj actually references your file:

```bash
"$UE_ROOT/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh" \
  -project="/path/to/MyGame.uproject" -game

grep -F "LaunchScreen.storyboard" \
  "Intermediate/ProjectFilesMac/MyGame (Mac).xcodeproj/project.pbxproj"
```

See [the gotchas page](gotchas.md#new-files-under-buildplatformresources-need-a-project-file-regen-to-be-picked-up) for the full path priority list and why this happens.

## My packaged `.app` ended up in `Build/{Platform}/` instead of `Saved/Packages/`

`Build/{Platform}/` is for committed source-controlled inputs (icons, launch storyboard, entitlements), not for build output. If you have an app sitting in `Build/Mac/` or `Build/IOS/`, something is misconfigured — most likely a UAT `-archivedirectory` flag pointing at `Build/`, or a downstream copy step.

The script writes outputs under `Saved/Packages/Mac/` by default. If you previously had `BUILD_DIR_REL=Build` in your `.env`, remove it (or change it to `Saved/Packages/Mac`). See [output.md](output.md#build-vs-saved--what-goes-where) for the convention.

## The xcconfig stamp step is skipped

The xcconfig at `Intermediate/ProjectFiles/XcconfigsMac/<project>.xcconfig` doesn't exist yet. Run `GenerateProjectFiles.sh` first:

```bash
"$UE_ROOT/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh" \
  -project="/path/to/MyGame.uproject" \
  -game
```

## Game Center entitlement disappears after project regeneration

Every `GenerateProjectFiles.sh` run (including the automatic regen ship.sh does before each build) overwrites `Intermediate/ProjectFiles/XcconfigsMac/*.xcconfig`. If `PremadeMacEntitlements` in `DefaultEngine.ini` points to a file that doesn't exist on disk, `GenerateProjectFiles` silently skips `CODE_SIGN_ENTITLEMENTS` — and Xcode drops the entitlement.

The fix is to commit `Build/Mac/Resources/<Project>.entitlements` to source control after the first `--game-center` run. Verify it landed in the xcconfig:

```bash
grep CODE_SIGN_ENTITLEMENTS \
  "Intermediate/ProjectFiles/XcconfigsMac/$(basename *.uproject .uproject).xcconfig"
```

If that key is absent, either the file wasn't committed or the `PremadeMacEntitlements` value in `DefaultEngine.ini` doesn't match the actual path. Run `./ship.sh --print-config` and check the `DefaultEngine.ini` directly:

```bash
grep PremadeMacEntitlements Config/DefaultEngine.ini
```

Note: ship.sh's codesign step injects `com.apple.developer.game-center` independently into the signing plist regardless of the xcconfig state — so ship.sh-produced builds are always correct. Xcode-direct builds depend on the committed file.

## Getting more detail

The full log is at `Logs/build_YYYY-MM-DD_HH-MM-SS.log`. All command output from UAT, `xcodebuild`, `codesign`, and `notarytool` goes there. The terminal only shows status lines.

When filing a bug report, include:
- macOS version
- UE5 version
- The flags you passed
- The last 50 lines or so of the build log
