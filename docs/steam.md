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

A Steam build is a **Direct Distribution** build (`MAC_DISTRIBUTION=developer-id`: Developer ID Application cert, hardened runtime, notarized, no App Sandbox, with the two Steam entitlements above).

A Game Center build on Mac is a **Mac App Store** build (`MAC_DISTRIBUTION=app-store`: Apple Distribution cert, MAS provisioning profile, App Sandbox required, uploaded to App Store Connect for review). MAS review forbids the Steam entitlements (`disable-library-validation` and `allow-dyld-environment-variables`) outright, so ship.sh rejects `MAC_DISTRIBUTION=app-store` + `ENABLE_STEAM=1` up-front.

You cannot ship one Mac binary that does both. `ENABLE_STEAM=1` and `ENABLE_GAME_CENTER=1` *can* be set on the same ship.sh run as long as the Mac channel isn't MAS — for example: `MAC_DISTRIBUTION=developer-id` + `IOS_DISTRIBUTION=app-store` + Steam on Mac + Game Center on iOS. The Mac and iOS pipelines run independently and each picks up the matching entitlement set. For a Mac build that ships Game Center, switch the Mac channel to `app-store` and drop Steam.
