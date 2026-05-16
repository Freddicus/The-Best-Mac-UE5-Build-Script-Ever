> This script and its docs were built with help from LLMs (started in ChatGPT, now Claude). Stitching UAT, Xcode archiving, codesigning, and notarization into something that actually works reliably took a lot of dead ends and genuine frustration — this stuff doesn't have a clean end-to-end tutorial anywhere. Sharing it here because once it finally worked, it felt wrong not to.

# The Best Mac Unreal Build Script Ever™

A bash script that runs the full macOS Developer ID distribution pipeline for UE5 projects: UAT build → Xcode archive → sign → notarize → staple.

Drop it in your project root and run it.

## Requirements

- macOS with Xcode and Command Line Tools installed
- Unreal Engine 5.x
- Apple Developer account — Team ID + Developer ID Application certificate in Keychain
- For notarization: a stored `notarytool` credential (`xcrun notarytool store-credentials`)

## Quick start

1. Copy `ship.sh` into your project root (the directory containing your `.uproject`).
2. Copy a template to `.env` next to the script and fill in the required values:

```bash
# Minimal template (Developer ID + notarization):
cp .env.example .env

# Or pick a preset-specific starter (already wired for that target):
cp .env.example.steam-mac .env     # Steam Direct Distribution (ZIP + notarize)
cp .env.example.direct-mac .env    # Direct download DMG (notarize)
cp .env.example.mas-mac .env       # Mac App Store
cp .env.example.ios .env           # iOS App Store only
cp .env.example.mac-ios .env       # Direct Mac + iOS App Store
cp .env.example.mas-ios .env       # Mac App Store + iOS App Store
cp .env.example.full .env          # Comprehensive reference of every variable
```

At minimum, set:

```bash
DEVELOPMENT_TEAM="ABCDE12345"
SIGN_IDENTITY="Developer ID Application: My Company (ABCDE12345)"
NOTARY_PROFILE="MyNotaryProfile"   # only if notarizing
```

3. Run it:

```bash
chmod +x ship.sh
./ship.sh
```

The script prompts for build type (Shipping / Development) and whether to notarize. Set `BUILD_TYPE` and `NOTARIZE` in `.env` to skip prompts (required for CI).

Run `./ship.sh --help` for all CLI flags, or `./ship.sh --print-config` to validate your configuration without building.

### Distribution channels

Two dispatcher variables decide which pipeline runs for each platform:

- `MAC_DISTRIBUTION` ∈ `developer-id` *(default)* | `app-store` | `off`
- `IOS_DISTRIBUTION` ∈ `off` *(default)* | `app-store`

The default — `developer-id` for Mac, iOS off — matches everything the script has done since day one. `MAC_DISTRIBUTION=app-store` runs the Mac App Store pipeline (UAT → `xcodebuild archive` under automatic provisioning → `exportArchive` → optional `xcrun altool -t macos` validate/upload), which is also the only channel that supports Game Center on Mac — AMFI rejects the entitlement on Developer-ID-signed Mac apps regardless of notarization. See [configuration.md → Distribution channels](docs/configuration.md#distribution-channels) for the full rules and the compatibility matrix.

### Targeting iOS too

The iOS pipeline is opt-in. To run it alongside Mac:

```bash
./ship.sh --ios
```

Or to skip Mac and build only iOS (no `SIGN_IDENTITY` required):

```bash
./ship.sh --ios-only
```

Both legacy flags are aliases for the dispatcher (`--ios` ⇔ `--ios-distribution app-store`; `--ios-only` ⇔ `--mac-distribution off --ios-distribution app-store`) — pick whichever reads better.

For App Store Connect upload, copy `iOS-ExportOptions.plist.example` to `iOS-ExportOptions.plist`, set `IOS_ASC_API_KEY_ID/ISSUER/KEY_PATH` in `.env`, and pass `--ios-upload-ipa`. See [docs/configuration.md](docs/configuration.md#ios-pipeline-opt-in) for the full iOS section.

## Pipeline

`./ship.sh` runs pre-flight checks, then a Mac and/or iOS pipeline depending on the active distribution channels. Full step-by-step execution order (shared setup, the developer-id vs Mac App Store Mac branches, the iOS branch, and the `CFBundleVersion` mechanics) lives in [docs/pipeline.md](docs/pipeline.md).

## Docs

- [Configuration reference](docs/configuration.md) — all `.env` variables, CLI flags, workspace and scheme setup
- [Pipeline](docs/pipeline.md) — `./ship.sh` execution order, per distribution channel
- [Versioning](docs/versioning.md) — `VERSION_MODE`, bump flags, xcconfig and Info.plist stamping
- [Output and packaging](docs/output.md) — DMG, ZIP, icon seeding, artifact paths
- [Steam support](docs/steam.md) — dylib staging, entitlements, `steam_appid.txt`
- [Troubleshooting](docs/troubleshooting.md) — common failures and how to fix them
- [Gotchas](docs/gotchas.md) — things macOS signing and notarization will bite you with

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The only CI check is `shellcheck ship.sh` — run it before opening a PR.
