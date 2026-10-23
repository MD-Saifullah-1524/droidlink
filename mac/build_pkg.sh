#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

echo "🔢 1. Incrementing project build number with agvtool..."
xcrun agvtool next-version -all

BUILD_VERSION=$(xcrun agvtool what-version -terse)
MARKETING_VERSION="1.1"
PKG_VERSION="${MARKETING_VERSION}.${BUILD_VERSION}"

echo "📌 Version: ${MARKETING_VERSION} (Build ${BUILD_VERSION})"

echo "🔨 2. Compiling DroidLink and DroidLinkFileProvider with xcodebuild (Release)..."
rm -rf .derivedData
xcrun xcodebuild \
    -project DroidLink.xcodeproj \
    -scheme DroidLink \
    -configuration Release \
    -derivedDataPath .derivedData \
    build

BUILT_APP=".derivedData/Build/Products/Release/DroidLink.app"
PLUGIN_APPEX="$BUILT_APP/Contents/PlugIns/DroidLinkFileProvider.appex"

if [ ! -d "$PLUGIN_APPEX" ]; then
    echo "❌ Error: DroidLinkFileProvider.appex was not found in $BUILT_APP/Contents/PlugIns/"
    exit 1
fi

echo "🎨 2b. Bundling icons and resources into app bundle..."
mkdir -p "$BUILT_APP/Contents/Resources"
cp -f Sources/DroidLink/Resources/* "$BUILT_APP/Contents/Resources/" 2>/dev/null || true

echo "🔏 3. Signing app bundle with entitlements..."
SIGN_ID=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk '{print $2}')
[ -z "$SIGN_ID" ] && SIGN_ID="-"

codesign --force --sign "$SIGN_ID" -o runtime --entitlements Sources/DroidLink/DroidLink.entitlements --timestamp=none --generate-entitlement-der "$BUILT_APP"

echo "🔏 3b. Verifying code signature..."
codesign -vvv --deep --strict "$BUILT_APP"

echo "📦 4. Building macOS Installer Package (DroidLink.pkg v${PKG_VERSION})..."
rm -rf .pkg_staging
mkdir -p .pkg_staging/Applications
cp -R "$BUILT_APP" .pkg_staging/Applications/

rm -f DroidLink.pkg
xcrun pkgbuild \
    --root .pkg_staging \
    --identifier com.droidlink.app \
    --version "$PKG_VERSION" \
    DroidLink.pkg

rm -rf .pkg_staging

# Keep root DroidLink.app in sync
rm -rf DroidLink.app DroidLinkCall.app DroidLinkMessages.app
cp -R "$BUILT_APP" DroidLink.app

echo ""
echo "=========================================================="
echo "✅ DroidLink.pkg generated successfully!"
echo "📍 Location: $DIR/DroidLink.pkg"
echo "🏷️  Version:  v${PKG_VERSION} (Build ${BUILD_VERSION})"
echo "⚡ FileProvider Extension: Embedded & Signed with App Group"
echo "=========================================================="
echo "To install or update, double-click DroidLink.pkg or run:"
echo "   sudo installer -pkg \"$DIR/DroidLink.pkg\" -target /"
echo "=========================================================="
