#!/bin/bash

# Build script for AndroidFileSync
# Creates a distributable DMG file

set -e

APP_NAME="AndroidFileSync"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"
RELEASE_DIR="$BUILD_DIR/Release"

echo "🔨 Building $APP_NAME..."

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR"

# Clear extended attributes from source files
echo "🧹 Clearing extended attributes..."
xattr -cr .

# Build the app in Release mode (skip code signing for distribution)
xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

# Find the built app
APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Build failed - app not found"
    exit 1
fi

echo "✅ Build successful: $APP_PATH"

# Copy bundled ADB to app Resources
ADB_SOURCE="$APP_NAME/Resources/adb"
if [ -f "$ADB_SOURCE" ]; then
    echo "📦 Bundling ADB executable..."
    mkdir -p "$APP_PATH/Contents/Resources"
    cp "$ADB_SOURCE" "$APP_PATH/Contents/Resources/"
    chmod +x "$APP_PATH/Contents/Resources/adb"
    echo "✅ ADB bundled in app"
else
    echo "⚠️ Warning: ADB not found at $ADB_SOURCE - users will need ADB installed"
fi

# Copy app to DMG staging folder
cp -R "$APP_PATH" "$DMG_DIR/"

# Create symbolic link to Applications
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
echo "📦 Creating DMG..."
DMG_NAME="$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$BUILD_DIR/$DMG_NAME"

echo ""
echo "✅ DMG created: $BUILD_DIR/$DMG_NAME"
echo ""
echo "📤 Next steps:"
echo "   1. Go to your GitHub repo → Releases → Create new release"
echo "   2. Upload: $BUILD_DIR/$DMG_NAME"
echo "   3. Add release notes"
echo "   4. Publish!"
echo ""
echo "👥 Users can then:"
echo "   1. Download the DMG"
echo "   2. Drag app to Applications"
echo "   3. Right-click → Open (first time only)"
