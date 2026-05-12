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

## Game Center entitlement missing from IPA or Mac app

Both platforms require a committed entitlements file. After the first `--game-center` run, commit:
- `Build/Mac/Resources/<Project>.entitlements`
- `Build/IOS/Resources/<Project>.entitlements`

**Mac:** Every `GenerateProjectFiles.sh` run overwrites the xcconfig. The script writes the entitlements path to **both** `PremadeMacEntitlements` and `ShippingSpecificMacEntitlements` under `[/Script/MacTargetPlatform.XcodeProjectSettings]` — UE's `BaseEngine.ini` defaults the Shipping key to `Sandbox.NoNet.entitlements` and prefers it over `PremadeMacEntitlements` for Shipping configs, so setting only one leaves Shipping pointed at the engine default (no Game Center). If either ini key points to a file that doesn't exist on disk, `GenerateProjectFiles` silently skips `CODE_SIGN_ENTITLEMENTS` for that config. Verify:

```bash
grep -E "CODE_SIGN_ENTITLEMENTS" \
  Intermediate/ProjectFiles/XcconfigsMac/*Shipping*.xcconfig
grep -E "PremadeMacEntitlements|ShippingSpecificMacEntitlements" Config/DefaultEngine.ini
```

Note: ship.sh's Mac codesign step also injects `com.apple.developer.game-center` independently into the final signing plist, so ship.sh-produced Mac builds get the entitlement even if the xcconfig path is broken. But without the matching xcconfig entry, the archive step won't auto-create a provisioning profile that authorizes the entitlement, so the final app fails AMFI at launch — see "Mac app exits immediately at launch / 'cannot be opened' with Game Center enabled" below.

**iOS:** `bEnableGameCenterSupport=True` tells UBT to write the entitlement to `Intermediate/IOS/<Target>.entitlements`, but that file is in `Intermediate/` and is not picked up by `xcodebuild` under `CODE_SIGN_STYLE=Automatic`. ship.sh passes `CODE_SIGN_ENTITLEMENTS=<path>` as a build setting override pointing to `Build/IOS/Resources/<Project>.entitlements`. If that file doesn't exist (e.g. after a clean on a machine that never committed it), the entitlement is silently dropped.

Verify the iOS entitlements file exists and contains the key:

```bash
/usr/libexec/PlistBuddy -c "Print :com.apple.developer.game-center" \
  "Build/IOS/Resources/$(basename *.uproject .uproject).entitlements"
```

Should print `true`. If the file is missing, run `./ship.sh --game-center` once and commit both `.entitlements` files.

## `xcodebuild -exportArchive` fails with "doesn't include the Game Center capability"

```
error: exportArchive Provisioning profile "..." doesn't include the Game Center capability.
error: exportArchive Provisioning profile "..." doesn't include the com.apple.developer.game-center entitlement.
```

Expected. Apple does not encode `com.apple.developer.game-center` into Developer ID provisioning profile binaries, regardless of what the dev portal's "Enabled Capabilities" panel shows. See [gotchas](gotchas.md#comappledevelopergame-center-is-a-restricted-entitlement--but-the-mac-developer-id-story-is-notarization-not-profile) for the full mechanism.

If you're seeing this error from `./ship.sh`, check that `ENABLE_GAME_CENTER=1` is set on the run — when it is, the script bypasses `xcodebuild -exportArchive` entirely and copies the `.app` straight out of the `.xcarchive`. Re-running with the flag set should skip the export step. Verify:

```bash
grep -E "Copy \\.app from archive \\(bypassing" Saved/Logs/build_*.log | head -2
```

If you see that line, the bypass is active and `xcodebuild -exportArchive` is not being called for the Mac export.

## Mac app exits immediately at launch (Game Center enabled), pre-notarization test

Symptoms: the exported `.app` is signed (`codesign --verify --deep --strict` passes) but trying to launch it from Finder or the terminal exits the process instantly. `log show --last 2m --predicate 'eventMessage CONTAINS "<bundle id>"'` shows:

```
amfid: ... Error -413 "No matching profile found"
  unsatisfiedEntitlements: com.apple.developer.game-center
kernel: AMFI: Code has restricted entitlements, but the validation of
its code signature failed.
```

This is **expected before notarization** for Mac Developer ID builds with `com.apple.developer.game-center`. The Mac Direct Distribution path authorizes restricted entitlements at runtime via the **notarization ticket**, not via an embedded provisioning profile — and the ticket only exists after `notarytool submit` succeeds and `stapler staple` writes it into the bundle.

To unblock launch testing:

1. Confirm `ENABLE_GAME_CENTER=1` is set on the run.
2. Run `./ship.sh` with `NOTARIZE=yes` (or the `--notarize` flag).
3. Wait for `notarytool wait` to return `status: Accepted`.
4. Confirm the staple succeeded with `xcrun stapler validate "<App>.app"`.
5. Launch the stapled `.app`. AMFI will now accept it because the embedded ticket vouches for the restricted entitlement.

If `notarytool` rejects the submission, run:

```bash
xcrun notarytool log <submission-id> --keychain-profile "<your-notary-profile>"
```

A rejection citing Game Center usually means **the App ID in App Store Connect doesn't have Game Center enabled** — confirm at https://developer.apple.com/account/resources/identifiers/list → your bundle ID → Capabilities. The script doesn't manage this; it's a one-time portal step.

## Getting more detail

The full log is at `Logs/build_YYYY-MM-DD_HH-MM-SS.log`. All command output from UAT, `xcodebuild`, `codesign`, and `notarytool` goes there. The terminal only shows status lines.

When filing a bug report, include:
- macOS version
- UE5 version
- The flags you passed
- The last 50 lines or so of the build log
