> This script and its docs were built with help from LLMs (started in ChatGPT, now Claude). Stitching UAT, Xcode archiving, codesigning, and notarization into something that actually works reliably took a lot of dead ends and genuine frustration — this stuff doesn't have a clean end-to-end tutorial anywhere. Sharing it here because once it finally worked, it felt wrong not to.

# The Best Mac Unreal Build Script Ever™

A bash script that runs the full macOS Developer ID distribution pipeline for UE5 projects: UAT build → Xcode archive → sign → notarize → staple. Optional iOS pipeline included.

Drop it in your project root and run it.

## Requirements

- macOS with Xcode and Command Line Tools installed
- Unreal Engine 5.x
- Apple Developer account — Team ID + Developer ID Application certificate in Keychain
- For notarization: a stored `notarytool` credential (`xcrun notarytool store-credentials`)
- For iOS (optional): iOS support enabled in the Epic Games Launcher, a provisioning profile downloaded in Xcode (Settings → Accounts → Download Manual Profiles), and an App Store Connect API key if using `--ios-upload-ipa`

## Quick start

1. Copy `ship.sh` into your project root (the directory containing your `.uproject`).
2. Copy `.env.example` to `.env` next to the script and set at minimum:

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

## Pipeline

When you run `./ship.sh`, this is the execution order:

1. **Pre-flight** — validates signing identity, notary profile, UAT paths, and required tools before touching anything.
2. **Version stamp** *(if `VERSION_MODE` is set)* — writes `version.txt` into `Content/BuildInfo/` so UAT bundles it automatically.
3. **Icon seeding** *(if enabled)* — copies your source-controlled `.xcassets` into the workspace so Xcode uses your app icon instead of the engine default.
4. **UAT BuildCookRun** — cooks and packages the project via `RunUAT.sh BuildCookRun`.
5. **xcconfig stamp** — writes `MARKETING_VERSION`, Game Mode flags, and app category into the Xcode-generated xcconfig before archiving.
6. **Xcode archive** — runs `xcodebuild archive` → `.xcarchive`.
7. **Xcode export** — runs `xcodebuild -exportArchive` with your `ExportOptions.plist` → signed `.app`.
8. **Component signing** — signs all nested `.dylib`, `.so`, and `.framework` files individually, then signs the outer `.app`. Never uses `--deep`.
9. **Steam staging** *(if `ENABLE_STEAM=1`)* — copies `libsteam_api.dylib` next to the executable and signs it.
10. **ZIP / DMG** — packages the signed app for distribution.
11. **Notarization** — submits ZIP and DMG to Apple in parallel, then waits for both.
12. **Stapling** — attaches the notarization ticket to the app, ZIP, and DMG.
13. **iOS pipeline** *(if `ENABLE_IOS=1`)* — UAT BuildCookRun for iOS → `xcodebuild archive` → `xcodebuild -exportArchive` → `.ipa`. Optionally validates and uploads to App Store Connect. Use `--ios-only` to skip steps 4–12 entirely.

Run `./ship.sh --ios-only` to build iOS without running the Mac pipeline at all.

Full build log: `Logs/build_YYYY-MM-DD_HH-MM-SS.log`. Artifacts land in `Build/`.

## Docs

- [Configuration reference](docs/configuration.md) — all `.env` variables, CLI flags, workspace and scheme setup, iOS pipeline
- [Versioning](docs/versioning.md) — `VERSION_MODE`, bump flags, xcconfig and Info.plist stamping (Mac + iOS)
- [Output and packaging](docs/output.md) — DMG, ZIP, icon seeding, artifact paths
- [Steam support](docs/steam.md) — dylib staging, entitlements, `steam_appid.txt`
- [Troubleshooting](docs/troubleshooting.md) — common failures and how to fix them
- [Gotchas](docs/gotchas.md) — things macOS signing and notarization will bite you with

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The only CI check is `shellcheck ship.sh` — run it before opening a PR.
