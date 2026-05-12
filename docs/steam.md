# Steam support

Steam support is off by default. The script makes no assumptions about Steam.

## Enabling Steam

```bash
ENABLE_STEAM="1"
STEAM_DYLIB_SRC="/path/to/libsteam_api.dylib"
```

When enabled, the script copies `libsteam_api.dylib` into the `.app` bundle next to the executable and signs it as part of the component signing step.

### Optional: steam_appid.txt

Writes a `steam_appid.txt` file alongside the executable for local testing without the Steam launcher:

```bash
WRITE_STEAM_APPID="1"
STEAM_APP_ID="480"   # Valve's public testing app ID; replace with yours
```

## Steam entitlements

Some Steam features (overlay, client-injected libraries) require two non-standard entitlements:

- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.cs.allow-dyld-environment-variables`

These are **only added when `ENABLE_STEAM=1`**. They weaken your app's security posture by allowing unsigned libraries to be injected at launch — don't add them unless you need them.

If you don't use Steam or don't need the overlay: keep `ENABLE_STEAM=0`.

## Steam and Game Center are mutually exclusive on Mac

A Steam build is a **Direct Distribution** build (Developer ID Application cert, hardened runtime, notarized, no App Sandbox, with the two Steam entitlements above).

A Game Center build is a **Mac App Store** build (Apple Distribution cert, MAS provisioning profile, App Sandbox required, uploaded to App Store Connect for review). MAS review forbids the Steam entitlements (`disable-library-validation` and `allow-dyld-environment-variables`) outright.

You cannot ship one Mac binary that does both. `ENABLE_STEAM=1` and the iOS-only `ENABLE_GAME_CENTER=1` can be set on the same ship.sh run — the iOS build gets Game Center and the Mac build gets Steam, since they target different distribution channels. But on a single Mac build, Game Center is unreachable through this script (Direct Distribution / Developer ID Mac apps cannot carry `com.apple.developer.game-center`; AMFI rejects the entitlement at launch). For a Mac Game Center build, use Xcode Organizer's `Distribute App → App Store Connect`; see [gotchas](gotchas.md#game-center-is-a-mac-app-store-feature--shipsh-handles-ios-only).
