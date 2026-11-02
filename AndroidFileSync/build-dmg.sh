#!/bin/bash

# Build a signed AndroidFileSync DMG. Local Network privacy on macOS needs an
# Apple-issued identity to reliably recognise the same app across updates.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="AndroidFileSync"
BUILD_DIR="build"
AFS_SIGNING_IDENTITY="${AFS_CODESIGN_IDENTITY:-}"
if [ -z "$AFS_SIGNING_IDENTITY" ]; then
    AFS_IDENTITIES=$(security find-identity -v -p codesigning)
    AFS_SIGNING_IDENTITY=$(printf '%s\n' "$AFS_IDENTITIES" | awk -F '"' '/"Developer ID Application:/ { print $2; exit }')
    if [ -z "$AFS_SIGNING_IDENTITY" ]; then
        AFS_SIGNING_IDENTITY=$(printf '%s\n' "$AFS_IDENTITIES" | awk -F '"' '/"Apple Development:/ { print $2; exit }')
    fi
fi

if [ -z "$AFS_SIGNING_IDENTITY" ] || [ "$AFS_SIGNING_IDENTITY" = "-" ]; then
    echo "❌ An Apple-issued signing certificate is required to package this app."
    echo "Local Network permission is unreliable for unsigned or ad hoc signed builds."
    echo "Add an Apple Development certificate in Xcode → Settings → Accounts → Manage Certificates,"
    echo "or set AFS_CODESIGN_IDENTITY to your Developer ID Application certificate."
    exit 1
fi

ADB_SOURCE="$APP_NAME/Resources/adb"
if [ ! -f "$ADB_SOURCE" ]; then
    echo "❌ Bundled ADB is missing: $ADB_SOURCE"
    exit 1
fi

echo "🔨 Building $APP_NAME..."

# Stage outside Documents/iCloud so Finder and file providers can't reattach
# resource forks or FinderInfo between cleanup and codesigning.
mkdir -p "$BUILD_DIR"
AFS_PACKAGE_ROOT=$(mktemp -d /private/tmp/afs-package.XXXXXX)
cleanup_package() {
    AFS_PACKAGE_EXIT_CODE=$?
    if [ "$AFS_PACKAGE_EXIT_CODE" -eq 0 ]; then
        rm -rf "$AFS_PACKAGE_ROOT"
    else
        echo "❌ Packaging failed; staging preserved at $AFS_PACKAGE_ROOT" >&2
    fi
}
trap cleanup_package EXIT
DMG_DIR="$AFS_PACKAGE_ROOT/dmg"
mkdir -p "$DMG_DIR"

# Compile an intermediate bundle. Sign the completed staging bundle below,
# after embedding and signing ADB, so no later copy invalidates the app seal.
xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$AFS_PACKAGE_ROOT/DerivedData" \
    -destination 'platform=macOS' \
    ARCHS="x86_64 arm64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

AFS_BUILT_APP="$AFS_PACKAGE_ROOT/DerivedData/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$AFS_BUILT_APP" ]; then
    echo "❌ Build failed - app not found at $AFS_BUILT_APP"
    exit 1
fi

APP_PATH="$DMG_DIR/$APP_NAME.app"
ditto --norsrc --noextattr --noqtn --noacl "$AFS_BUILT_APP" "$APP_PATH"

# Copy bundled ADB to app Resources
echo "📦 Bundling ADB executable..."
mkdir -p "$APP_PATH/Contents/Resources"
cp -X "$ADB_SOURCE" "$APP_PATH/Contents/Resources/"
chmod +x "$APP_PATH/Contents/Resources/adb"
find "$APP_PATH" -type f -name '._*' -delete
xattr -cr "$APP_PATH"

# Give the helper and responsible app the same stable Apple-issued identity.
AFS_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
echo "🔏 Signing with $AFS_SIGNING_IDENTITY..."
codesign --force --options runtime --timestamp \
    --identifier "$AFS_BUNDLE_ID.adb" --sign "$AFS_SIGNING_IDENTITY" \
    "$APP_PATH/Contents/Resources/adb"
# The helper's Mach-O signature is embedded in the binary. Remove filesystem
# metadata once more immediately before sealing the containing app.
xattr -cr "$APP_PATH"
codesign --force --options runtime --timestamp \
    --entitlements "$APP_NAME/AndroidFileSync.entitlements" \
    --sign "$AFS_SIGNING_IDENTITY" "$APP_PATH"

# Reject unsigned, ad hoc, untrusted, or damaged bundles before creating a DMG.
codesign --verify --strict --verbose=2 -R '=anchor apple generic' "$APP_PATH/Contents/Resources/adb"
codesign --verify --deep --strict --verbose=2 -R '=anchor apple generic' "$APP_PATH"

# Create symbolic link to Applications
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
echo "📦 Creating DMG..."
DMG_NAME="$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$BUILD_DIR/$DMG_NAME"

echo "DMG created successfully"

