#!/bin/bash
# Archive -> patch BuildMachineOSBuild -> export -> upload ASTROSPIKE to TestFlight.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

KEY_ID="8APDGY74BZ"
ISSUER="7642a25e-aca7-402d-8b7d-de18dfef1756"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
STABLE_OS_BUILD="${1:-${SHIP_RELEASED_OS_BUILD:-25F80}}"

SCHEME="ASTROSPIKE"
PROJECT="ASTROSPIKE.xcodeproj"
BUILD_DIR="$REPO/build"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

BUILD_NUM=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
echo "=== Preparing TestFlight upload for $SCHEME build $BUILD_NUM ==="

# Force /usr/bin before Homebrew so rsync/openrsync doesn't break export
export PATH=/usr/bin:$PATH

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

echo "=== Regenerating Xcode project ==="
xcodegen generate

echo "=== Archiving $SCHEME ==="
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER"

PLIST="$ARCHIVE/Products/Applications/$SCHEME.app/Info.plist"
echo "BuildMachineOSBuild before: $(/usr/libexec/PlistBuddy -c 'Print :BuildMachineOSBuild' "$PLIST" 2>/dev/null || echo 'none')"
/usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild $STABLE_OS_BUILD" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :BuildMachineOSBuild string $STABLE_OS_BUILD" "$PLIST"
echo "BuildMachineOSBuild after:  $(/usr/libexec/PlistBuddy -c 'Print :BuildMachineOSBuild' "$PLIST")"

echo "=== Exporting IPA ==="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$REPO/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER"

IPA="$EXPORT_DIR/$SCHEME.ipa"
if [ ! -f "$IPA" ]; then
  echo "ERROR: IPA not found at $IPA" >&2
  exit 1
fi

echo "=== Uploading build $BUILD_NUM to TestFlight ==="
xcrun altool --upload-app --type ios \
  -f "$IPA" \
  --apiKey "$KEY_ID" \
  --apiIssuer "$ISSUER"

echo "=== Successfully uploaded build $BUILD_NUM to TestFlight ==="
