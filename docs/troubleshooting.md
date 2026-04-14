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

## The xcconfig stamp step is skipped

The xcconfig at `Intermediate/ProjectFiles/XcconfigsMac/<project>.xcconfig` doesn't exist yet. Run `GenerateProjectFiles.sh` first:

```bash
"$UE_ROOT/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh" \
  -project="/path/to/MyGame.uproject" \
  -game
```

## Getting more detail

The full log is at `Logs/build_YYYY-MM-DD_HH-MM-SS.log`. All command output from UAT, `xcodebuild`, `codesign`, and `notarytool` goes there. The terminal only shows status lines.

When filing a bug report, include:
- macOS version
- UE5 version
- The flags you passed
- The last 50 lines or so of the build log
