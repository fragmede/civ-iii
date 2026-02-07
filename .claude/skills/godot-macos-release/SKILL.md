---
name: godot-macos-release
description: Build, code-sign, notarize, and release a Godot 4.x Mono/.NET project for macOS. Use when the user wants to export a Godot game for macOS, sign a Godot app with Developer ID, notarize a macOS app with Apple, create a GitHub release for a Godot project, or do the full build-sign-notarize-release pipeline. Triggers on phrases like "build for mac", "sign the app", "notarize", "export macOS", "create a release", "code sign".
---

# Godot macOS Build, Sign, Notarize & Release

## Prerequisites

Verify before starting. Install any that are missing:

| Dependency | Install | Verify |
|---|---|---|
| .NET 8.0 SDK | `brew install dotnet@8` (keg-only) | `dotnet --version` |
| Godot Mono | Download .NET build from godotengine.org/download/archive | `godot --version` (must show `mono`) |
| Export templates | Download `.tpz` from same archive page | Check `~/Library/Application Support/Godot/export_templates/<version>/macos.zip` |
| Signing identity | Xcode/Developer portal | `security find-identity -v -p codesigning \| grep "Developer ID"` |
| Notarization creds | `xcrun notarytool store-credentials` | `xcrun notarytool history --keychain-profile "<profile>"` |
| gh CLI | `brew install gh` | `gh auth status` |

### .NET 8.0 environment (keg-only)

Every shell command that uses `dotnet` or `godot` needs:

```bash
export PATH="/opt/homebrew/opt/dotnet@8/bin:$PATH"
export DOTNET_ROOT="/opt/homebrew/opt/dotnet@8/libexec"
```

### Godot Mono installation pitfalls

- **Always use the full path** `/Applications/Godot_mono.app/Contents/MacOS/Godot` — a symlink at `/usr/local/bin/godot` causes `.NET: Assemblies not found` because GodotSharp lives at `Contents/Resources/GodotSharp/`, not next to the binary.
- Export templates directory name must match version exactly: `~/Library/Application Support/Godot/export_templates/4.4.1.stable.mono/`

## Workflow

### 1. Build .NET assemblies

```bash
cd <project_dir>
dotnet build -c Release
```

For Godot projects, this populates `.godot/mono/temp/bin/ExportRelease/`.

### 2. Import resources

`--headless --import` hangs on macOS. Instead:

```bash
timeout 60 /Applications/Godot_mono.app/Contents/MacOS/Godot --editor
```

This opens the editor GUI briefly to populate `.godot/imported/`. Verify:

```bash
ls .godot/imported/ | wc -l  # should be > 0
```

### 3. Disable built-in codesign and export

Edit `export_presets.cfg`: set `codesign/codesign=0` (revert after export).

```bash
/Applications/Godot_mono.app/Contents/MacOS/Godot --headless --export-release "macOS" ../Exports/MacOS/Output.zip
```

**Revert** `codesign/codesign=1` immediately after export.

Add static files if needed:

```bash
cd <project_dir>
zip -r ../Exports/MacOS/Output.zip Assets Text Lua
```

### 4. Sign, notarize, and staple

Extract, sign, notarize using `scripts/sign_and_notarize.sh`:

```bash
mkdir -p signing && cd signing
unzip ../Output.zip
~/.claude/skills/godot-macos-release/scripts/sign_and_notarize.sh \
  MyGame.app \
  "Developer ID Application: Name (TEAMID)" \
  "notarytool-profile"
```

Or manually:

```bash
IDENTITY="Developer ID Application: Name (TEAMID)"

# Find and sign ALL Mach-O binaries (not just dylibs — createdump executables too)
find MyGame.app -type f -exec sh -c 'file "$1" | grep -q "Mach-O" && echo "$1"' _ {} \; | \
  xargs -I{} codesign --force --options runtime --timestamp --sign "$IDENTITY" {}

# Sign the app bundle
codesign --deep --force --options runtime --timestamp --sign "$IDENTITY" MyGame.app

# Verify
codesign --verify --verbose=4 MyGame.app

# Notarize
ditto -c -k --keepParent MyGame.app MyGame-notarize.zip
xcrun notarytool submit MyGame-notarize.zip --keychain-profile "notarytool-profile" --wait

# Staple
xcrun stapler staple MyGame.app
spctl --assess --type exec --verbose=4 MyGame.app  # expect "accepted, source=Notarized Developer ID"
```

### 5. Package and release

```bash
ditto -c -k --keepParent MyGame.app ../MyGame-signed.zip
# Add static files to zip if needed
zip -r ../MyGame-signed.zip Assets Text Lua

# Tag and release
git tag -a v1.0 -m "macOS signed release"
git push origin v1.0
gh release create v1.0 --title "MyGame v1.0" --notes "Signed macOS build" MyGame-signed.zip
```

## Critical gotchas

- **Sign ALL Mach-O binaries**, not just `*.dylib` — .NET runtime includes `createdump` executables that must also be signed with `--options runtime --timestamp`
- **Notarization rejects** any unsigned or non-hardened-runtime Mach-O binary in the bundle
- **`--headless --import` hangs** on macOS with Godot Mono — use `timeout 60 godot --editor` instead
- **Symlinked godot binary** breaks .NET assembly resolution — always use the full `/Applications/Godot_mono.app/Contents/MacOS/Godot` path
- **Export templates directory** name must exactly match `<version>.stable.mono` (e.g., `4.4.1.stable.mono`)
- **`codesign/codesign=0`** in `export_presets.cfg` prevents Godot from applying its own (incomplete) signing — revert after export

## Scripts

- **`scripts/sign_and_notarize.sh`** — Automated signing + notarization pipeline. Finds all Mach-O binaries, signs them inside-out, submits for notarization, staples the ticket, and verifies with Gatekeeper. Usage: `sign_and_notarize.sh <app_path> <identity> <notary_profile>`
