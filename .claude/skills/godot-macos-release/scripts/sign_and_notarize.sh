#!/usr/bin/env bash
# Sign, notarize, and staple a macOS .app bundle
# Usage: sign_and_notarize.sh <app_path> <identity> <notary_profile>
# Example: sign_and_notarize.sh OpenCiv3.app "Developer ID Application: Name (TEAMID)" "notarytool-profile"
set -euo pipefail

APP_PATH="${1:?Usage: sign_and_notarize.sh <app_path> <identity> <notary_profile>}"
IDENTITY="${2:?Missing signing identity}"
NOTARY_PROFILE="${3:?Missing notarytool keychain profile name}"

echo "==> Finding all Mach-O binaries in ${APP_PATH}..."
BINARIES=()
while IFS= read -r -d '' file; do
    if file "$file" | grep -q "Mach-O"; then
        BINARIES+=("$file")
    fi
done < <(find "$APP_PATH" -type f -print0)

echo "==> Found ${#BINARIES[@]} Mach-O binaries"

echo "==> Signing nested binaries (inside-out)..."
for bin in "${BINARIES[@]}"; do
    echo "    Signing: $bin"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bin"
done

echo "==> Signing app bundle..."
codesign --deep --force --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --verbose=4 "$APP_PATH"

echo "==> Creating notarization zip..."
NOTARIZE_ZIP="${APP_PATH%.app}-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization (this may take 5-15 minutes)..."
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Gatekeeper assessment..."
spctl --assess --type exec --verbose=4 "$APP_PATH"

rm -f "$NOTARIZE_ZIP"
echo "==> Done! ${APP_PATH} is signed, notarized, and stapled."
