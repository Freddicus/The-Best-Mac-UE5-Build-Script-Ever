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
