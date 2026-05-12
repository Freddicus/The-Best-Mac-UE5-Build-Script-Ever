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

## `Build/{Platform}/` is for committed inputs, not output

The folder name is misleading — `Build/` looks like a build-output directory, but in modern Unreal it's a **source-controlled inputs** folder. App icons, custom launch storyboards, `Info.plist` fragments, entitlements, and `PakBlacklist*.txt` all live there and are committed to git. UBT writes a few intermediates of its own here too (`UBTGenerated/`, `FileOpenOrder/`, `*.PackageVersionCounter`), and those stay gitignored.

Build *output* belongs under `Saved/` — `Saved/Cooked/{Platform}/`, `Saved/StagedBuilds/{Platform}/`, `Saved/Packages/{Platform}/`, `Saved/Logs/`. `Saved/` is gitignored by default and is the documented dumping ground for derived artifacts.

If you find a packaged `.app` sitting at `Build/Mac/<App>-Mac-Shipping.app/`, something is misconfigured — either a UAT `-archivedirectory` flag pointing the wrong way, or a downstream copy step. This script writes outputs under `Saved/Packages/Mac/` by default; see [output.md](output.md) for the path layout.

## New files under `Build/{Platform}/Resources/` need a project-file regen to be picked up

UBT bakes resolved absolute paths from `Build/{Platform}/Resources/` into `Intermediate/ProjectFilesMac/<Project> (Mac).xcodeproj/project.pbxproj` at *project-file-generation time*. The path priority list in `XcodeProject.cs::ProcessAssets` is walked **once** during `GenerateProjectFiles.sh`; the resolved paths are then frozen into the pbxproj.

So if you drop a custom `LaunchScreen.storyboard` into `Build/IOS/Resources/Interface/`, or a `Build/Mac/Resources/Assets.xcassets/`, you have to regenerate project files before the next build sees it. Editing the *contents* of an already-referenced file works without regen; adding or removing a sibling does not.

This script runs `GenerateProjectFiles.sh` automatically before every Xcode build (controlled by `REGEN_PROJECT_FILES`, default on). The symptom you avoid by leaving it on is a stale absolute path inside `project.pbxproj` — extremely hard to debug after the fact, because the file you added is right there on disk and you can see Xcode loading the project, yet the resource never reaches the bundle.

For the launch storyboard specifically, the engine's path priority list (modern Xcode mode) is:

```text
1.  $(Project)/Build/IOS/Resources/Interface/LaunchScreen.storyboardc
2.  $(Project)/Build/IOS/Resources/Interface/LaunchScreen.storyboard       ← what consumer projects own
3.  $(Project)/Build/Apple/Resources/Interface/LaunchScreen.storyboardc
4.  $(Project)/Build/Apple/Resources/Interface/LaunchScreen.storyboard
5.  $(Engine)/Build/IOS/Resources/Interface/LaunchScreen.storyboardc       ← engine fallback
... (engine fallbacks continue)
```

`$(Project)` resolves to the `.uproject`'s parent directory; first hit wins. This is why dropping a file into `Build/IOS/Resources/Interface/` is the clean override path — and why the regen step matters for picking it up.

## Adding a custom iOS `LaunchScreen.storyboard` breaks the Mac build

This one is sneaky. Without any consumer override, Mac builds resolve the launch screen to the engine's pre-compiled iOS `.storyboardc` fallback (an already-compiled storyboard wrapper bundle). Xcode treats `.storyboardc` as opaque — it ships the wrapper as-is, no compilation step, no error.

The moment you drop a custom `Build/IOS/Resources/Interface/LaunchScreen.storyboard` source file into the project (a normal way to override the iOS launch screen), Mac's resolution moves up the priority list and lands on the iOS `.storyboard` source. Xcode now sees `file.storyboard` and tries to *compile* it — but it's an iOS storyboard, and the Mac toolchain rejects iOS-only constructs. The build fails with a storyboard compile error and no obvious link to "you added a launch storyboard for iOS".

There's no engine-level switch — `XcodeProject.cs::ProcessAssets` calls `AddResource` unconditionally. The fix lives at the project layer: place a Mac-platform-shared `.storyboardc` (a pre-compiled wrapper) at `$(Project)/Build/Apple/Resources/Interface/LaunchScreen.storyboardc` so Mac short-circuits there before reaching the iOS source.

This script does that automatically — `seed_apple_launchscreen_compat()` copies the engine's stock `LaunchScreen.storyboardc` from `$(UE)/Engine/Build/IOS/Resources/Interface/` into `$(Project)/Build/Apple/Resources/Interface/` if the destination is missing. It runs before `GenerateProjectFiles`, since UBT bakes the resolved path into the generated `.xcodeproj`. Idempotent: if a `.storyboardc` is already there (e.g. you committed it after the first run, or you supplied your own), the seed is a no-op.

This is the one exception to "ship.sh does not write under `Build/`" — the seeded file is a stock engine asset, not a customization, and you're encouraged to commit it after the first run so the project becomes self-contained. Disable with `SEED_APPLE_LAUNCHSCREEN_COMPAT=0` or `--no-seed-apple-launchscreen-compat`.

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

## Game Center entitlements must be committed source files — intermediate-only paths don't reach signing

**macOS:** There is no UBT ini boolean equivalent of `bEnableGameCenterSupport` for macOS. The mechanism is two ini keys under `[/Script/MacTargetPlatform.XcodeProjectSettings]`:

- `PremadeMacEntitlements` — used for Debug/Development/DebugGame builds
- `ShippingSpecificMacEntitlements` — used for **Shipping** builds; UE's `BaseEngine.ini` defaults this to `/Game/Build/Mac/Resources/Sandbox.NoNet.entitlements` and prefers it over `PremadeMacEntitlements`

Setting only `PremadeMacEntitlements` leaves Shipping archives pointed at UE's stock `Sandbox.NoNet.entitlements` (no Game Center). The script sets **both** keys to the seeded `Build/Mac/Resources/<Project>.entitlements` so every config picks it up. `GenerateProjectFiles` then writes `CODE_SIGN_ENTITLEMENTS = <path>` into each per-config xcconfig.

**iOS:** UBT reads `bEnableGameCenterSupport=True` from `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]` and injects the entitlement into `Intermediate/IOS/<Target>.entitlements` during the build. However, this file is in `Intermediate/` and is not picked up by `xcodebuild` when using `CODE_SIGN_STYLE=Automatic` — xcodebuild defers to the provisioning portal, which only reflects what `CODE_SIGN_ENTITLEMENTS` explicitly declares. Without an explicit `CODE_SIGN_ENTITLEMENTS` build setting pointing to a real file, the Game Center entitlement is silently dropped from the IPA.

The script solves both cases with committed source files:
- Mac: seeds `Build/Mac/Resources/<Project>.entitlements` → both `PremadeMacEntitlements` and `ShippingSpecificMacEntitlements` in `DefaultEngine.ini` → `GenerateProjectFiles` bakes `CODE_SIGN_ENTITLEMENTS` into every config's xcconfig
- iOS: seeds `Build/IOS/Resources/<Project>.entitlements` → passed as `CODE_SIGN_ENTITLEMENTS=<path>` directly to `xcodebuild archive` as a build setting override

**Commit both files** after the first `--game-center` run. Without them in source control, any clean or teammate/CI regen loses the entitlement path.

## `com.apple.developer.game-center` is a restricted entitlement — but the Mac Developer ID story is "notarization, not profile"

A Mac app that declares `com.apple.developer.game-center` (or any other "provisioned" entitlement) has its entitlement authorization checked by the kernel's AMFI (Apple Mobile File Integrity). Two distinct mechanisms can satisfy AMFI:

1. **Embedded provisioning profile lists the entitlement.** This is the Apple Development / Mac App Store / iOS path. The profile's `Entitlements` dict explicitly contains `com.apple.developer.game-center=true`, and AMFI verifies that the signed entitlements are a subset of the profile's claimed entitlements.
2. **Notarization ticket vouches for the entitlement.** This is the Mac Developer ID / Direct Distribution path. The notarization service validates the signed entitlements against the App ID's enabled capabilities in App Store Connect, then issues a ticket. Once stapled to the `.app`, AMFI accepts the launched binary even with no provisioning profile embedded.

**Apple does not encode `com.apple.developer.game-center` into Developer ID provisioning profile binaries**, even when the App ID has Game Center enabled and the portal's "Enabled Capabilities" panel claims the profile carries it. The portal display reflects what's enabled on the App ID, not the actual encoded `.provisionprofile` contents. Decoding any Developer ID profile binary with `security cms -D -i <file>` confirms this — the `Entitlements` dict only contains `application-identifier`, `team-identifier`, and `keychain-access-groups`. There is no portal flow that adds Game Center to a Developer ID profile.

This has a direct consequence for the CLI build pipeline: **`xcodebuild -exportArchive` with `method=developer-id` cannot succeed** for an archive whose binary declares a restricted entitlement. It pre-validates restricted entitlements against the named profile and fails with:

```
error: exportArchive Provisioning profile "..." doesn't include the Game Center capability.
error: exportArchive Provisioning profile "..." doesn't include the com.apple.developer.game-center entitlement.
```

This is true regardless of `-allowProvisioningUpdates`, `signingStyle=automatic` vs `manual`, or which profile/cert is named in `ExportOptions.plist`. There is no CLI flag to skip the validation. Xcode GUI's `Distribute App → Direct Distribution` succeeds because `IDEDistribution` skips this pre-validation entirely and relies on notarization at runtime.

**ship.sh handles this by bypassing `xcodebuild -exportArchive` whenever `ENABLE_GAME_CENTER=1`.** The `.app` is copied directly out of `<archive>/Products/Applications/`, its development `Contents/embedded.provisionprofile` is removed (bound to the Apple Development cert, incompatible with the Developer ID re-sign), the existing per-component re-sign applies the Developer ID signature + script-managed entitlements, and notarization+stapling complete the chain. The stapled ticket is what makes AMFI accept the launched app on clean machines. Without notarization+stapling, a Developer-ID-signed app with `com.apple.developer.game-center` and no embedded profile will be killed at launch by AMFI with `Error -413 "No matching profile found"` — that's expected; the ticket is the missing piece.

The post-export per-component re-sign is otherwise fine: `codesign --force --sign --entitlements <file>` rewrites the signature and entitlements blob but does **not** touch `Contents/embedded.provisionprofile`. (In the bypass path, the profile is already gone before re-sign runs.)

## App Sandbox and Game Mode are separate

Enabling macOS Game Mode (`LSSupportsGameMode`) does not require the App Sandbox. Game Mode just tells macOS to deprioritize background processes while a controller is connected. You can and should enable it for any game — it has no security implications and no entitlement requirements.

The App Sandbox is a different and much more restrictive thing. Most UE5 games distributed outside the App Store are not sandboxed.
