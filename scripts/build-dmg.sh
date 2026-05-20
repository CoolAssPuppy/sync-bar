#!/bin/bash
#
# Build a distributable, notarized, Sparkle-signed DMG for SyncBar.
#
# Prerequisites:
#   1. Xcode Archive + Developer ID export of "SyncBar.app" (the .app must
#      already be signed with Developer ID and notarized+stapled).
#   2. `brew install create-dmg`
#   3. A `notarytool` keychain profile stored via:
#        xcrun notarytool store-credentials <profile-name> --apple-id ... --team-id ... --password ...
#   4. Sparkle `sign_update` tool at ~/bin/sparkle/sign_update (see scripts/SPARKLE.md).
#   5. Doppler access to SPARKLE_PRIVATE_KEY in the sync-bar project (signing key).
#
# Optional: drop a 1320x800 background.tiff and a VolumeIcon.icns into
# dmg-assets/ to brand the DMG window. Without them a plain DMG is built.
#
# Usage:
#   ./scripts/build-dmg.sh <path-to-SyncBar.app> <version> <notarytool-profile>
#
# Output:
#   dist/SyncBar-<version>.dmg            (signed, notarized, stapled)
#   dist/SyncBar-<version>.sparkle.txt    (edSignature + length for appcast)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?Usage: $0 <path-to-SyncBar.app> <version> <notarytool-profile>}"
VERSION="${2:?Usage: $0 <path-to-SyncBar.app> <version> <notarytool-profile>}"
NOTARY_PROFILE="${3:?Usage: $0 <path-to-SyncBar.app> <version> <notarytool-profile>}"

APP_NAME="SyncBar"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$HOME/bin/sparkle/sign_update}"
# The shared Strategic Nerds Sparkle private key (base64 EdDSA) is stored in
# Doppler, not the keychain, so any machine with Doppler access can release.
DOPPLER_PROJECT="${DOPPLER_PROJECT:-sync-bar}"
DOPPLER_CONFIG="${DOPPLER_CONFIG:-prd}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Prashant Sridharan (955GSY56UT)}"

BACKGROUND="$REPO_ROOT/dmg-assets/background.tiff"
VOLUME_ICON="$REPO_ROOT/dmg-assets/VolumeIcon.icns"
DMG_OUT="$REPO_ROOT/dist/$APP_NAME-$VERSION.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App not found at $APP_PATH"
  exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "Error: create-dmg not installed. Run: brew install create-dmg"
  exit 1
fi

if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "Error: Sparkle sign_update not found at $SIGN_UPDATE"
  echo "Install it (see scripts/SPARKLE.md) or set SPARKLE_SIGN_UPDATE to its path."
  exit 1
fi

if ! command -v doppler >/dev/null 2>&1; then
  echo "Error: doppler CLI not found. Install: brew install dopplerhq/cli/doppler"
  exit 1
fi

mkdir -p "$REPO_ROOT/dist"
rm -f "$DMG_OUT"

echo "Building DMG for $APP_NAME v$VERSION..."
echo "  App:    $APP_PATH"
echo "  Output: $DMG_OUT"
echo ""

# Window coords assume a 1320x800 (2x retina) background -> 660x400 window.
CREATE_DMG_ARGS=(
  --volname "$APP_NAME"
  --window-pos 200 120
  --window-size 660 400
  --icon-size 90
  --icon "$APP_NAME.app" 377 184
  --app-drop-link 595 184
  --hide-extension "$APP_NAME.app"
  --no-internet-enable
  --hdiutil-quiet
)
if [[ -f "$BACKGROUND" ]]; then
  CREATE_DMG_ARGS+=(--background "$BACKGROUND")
else
  echo "Note: $BACKGROUND missing — building an unbranded DMG window."
fi
if [[ -f "$VOLUME_ICON" ]]; then
  CREATE_DMG_ARGS+=(--volicon "$VOLUME_ICON")
fi

create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_OUT" "$APP_PATH"

echo ""
echo "DMG built: $DMG_OUT"
echo ""

echo "Codesigning DMG with: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_OUT"

echo "Notarizing DMG (this can take several minutes)..."
xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait

echo ""
echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_OUT"

echo ""
echo "Verifying notarization..."
xcrun stapler validate "$DMG_OUT"
spctl -a -t open --context context:primary-signature -v "$DMG_OUT"

echo ""
echo "Signing DMG with Sparkle (key from Doppler $DOPPLER_PROJECT/$DOPPLER_CONFIG)..."
SPARKLE_OUT="${DMG_OUT%.dmg}.sparkle.txt"
SPARKLE_PRIVATE_KEY="$(doppler secrets get SPARKLE_PRIVATE_KEY --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG" --plain)"
if [[ -z "$SPARKLE_PRIVATE_KEY" ]]; then
  echo "Error: SPARKLE_PRIVATE_KEY not found in Doppler $DOPPLER_PROJECT/$DOPPLER_CONFIG"
  exit 1
fi
SPARKLE_KEY_FILE="$(mktemp)"
chmod 600 "$SPARKLE_KEY_FILE"
trap 'rm -f "$SPARKLE_KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG_OUT" | tee "$SPARKLE_OUT"
rm -f "$SPARKLE_KEY_FILE"
trap - EXIT

echo ""
echo "============================================================"
echo "Release artifacts for v$VERSION"
echo "============================================================"
echo "  DMG:          $DMG_OUT"
echo "  Sparkle info: $SPARKLE_OUT"
