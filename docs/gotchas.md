# Gotchas

Things that will bite you about macOS signing and notarization — collected from building this pipeline.

## "It runs on my machine" is not a test

Your development Mac has your Developer ID certificate, your signing identity, your Gatekeeper exceptions, and probably the quarantine flag stripped from every binary you've ever touched. None of that is true on a fresh Mac.

Always test on a separate machine or a clean user account, with the binary downloaded normally (not `scp`'d directly). Quarantine behavior is what most of your users will experience.

## Notarization is not optional for distribution

macOS Gatekeeper will block an unsigned or unnotarized app for any user who didn't build it. "Hardened runtime + Developer ID" gets you past the signing check. Notarization gets you past the Apple OCSP check. Stapling means it works offline too.

You need all three for a build that works reliably for other people.

## `--deep` codesign will fail notarization

`codesign --deep` sounds convenient but it processes nested binaries in the wrong order and often misses things. Apple's notarization service will reject bundles signed this way.

The correct approach is to walk the bundle yourself — sign each nested `.dylib`, `.so`, and `.framework` individually (deepest first), then sign the outer `.app` last. That's what this script does.

## Hardened runtime + injected dylibs conflict by design

The hardened runtime exists to prevent exactly what launchers like Steam do: inject a dylib at startup via `DYLD_INSERT_LIBRARIES`. To use Steam's overlay, you need to explicitly opt out of library validation and allow dyld environment variables in your entitlements plist.

These are real security weaknesses. Only add them if you need them (see [Steam support](steam.md)).

## Xcode scheme must be Shared

This trips people up constantly. An Xcode scheme that isn't marked Shared only exists in your local Xcode preferences — it's invisible to `xcodebuild` on the command line and to anyone else who clones the repo.

If your archive step fails with a scheme-not-found error but you can see the scheme in Xcode, this is almost certainly the problem.

## The xcconfig gets regenerated

`GenerateProjectFiles.sh` overwrites the xcconfig at `Intermediate/ProjectFiles/XcconfigsMac/<project>.xcconfig`. Any manual edits you make there won't survive a project regeneration.

This is why the script stamps it at build time instead of asking you to edit it. The stamp runs fresh on every build, after any regeneration that may have happened.

## UAT and Xcode are separate pipelines

UAT (`BuildCookRun`) cooks and stages your game assets. It does not produce a distributable binary. The Xcode archive/export step is what signs the final `.app` with your Developer ID.

If you only run UAT and try to distribute the result directly, you'll get a build that either isn't signed or is signed with a development cert. It will be blocked by Gatekeeper.

## Notarization failures are often silent until you pull the log

Apple's notarization service accepts submissions before it finishes checking them. A successful `notarytool submit` just means Apple received the file — it doesn't mean it passed. Always wait for the result and pull the log on rejection:

```bash
xcrun notarytool log <submission-id> --keychain-profile "MyNotaryProfile"
```

The rejection reason is almost never surfaced in the CLI output itself.

## App Sandbox and Game Mode are separate

Enabling macOS Game Mode (`LSSupportsGameMode`) does not require the App Sandbox. Game Mode just tells macOS to deprioritize background processes while a controller is connected. You can and should enable it for any game — it has no security implications and no entitlement requirements.

The App Sandbox is a different and much more restrictive thing. Most UE5 games distributed outside the App Store are not sandboxed.
