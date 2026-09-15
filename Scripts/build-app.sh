#!/usr/bin/env bash
# Builds Relay.app with the session daemon embedded as a helper executable.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Relay"
BUNDLE_ID="com.maketryuk.relay"
# Read from the Swift source so there is exactly one place to bump.
VERSION="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' "$ROOT/Sources/RelayProtocol/RelayVersion.swift" | head -1)"
VERSION="${VERSION:-0.0.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product Relay
swift build -c "$CONFIGURATION" --product relay-daemon
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Relay" "$APP/Contents/MacOS/Relay"
# The daemon ships inside the bundle so a released app never picks up a stale
# binary from a developer's build directory.
cp "$BIN_PATH/relay-daemon" "$APP/Contents/MacOS/relay-daemon"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits resource bundles (SwiftTerm ships one) next to the binaries.
for bundle in "$BIN_PATH"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>NSHumanReadableCopyright</key><string>Relay</string>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# Launchers such as Raycast and Spotlight expect a classic bundle; PkgInfo is
# cheap and its absence makes some of them skip the app entirely.
printf 'APPL????' > "$APP/Contents/PkgInfo"

# macOS keys privacy permissions to the code signature. An ad-hoc signature
# changes with every build, so each rebuild looked like a brand new app and the
# folder-access prompts came back. A real certificate has a stable identity, so
# the grant sticks.
IDENTITY="${RELAY_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Apple Development" \
    | sed -E 's/.*"(.*)"/\1/')"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> Signing as: $IDENTITY"
  # Nested binaries first, then the bundle, which is what --deep did badly.
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/relay-daemon"
  # SwiftPM resource bundles hold no executable code and codesign refuses them
  # outright ("bundle format unrecognized"); the outer signature seals them as
  # ordinary resources, which is what they are.
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "==> Signing (ad-hoc — macOS will re-ask for permissions after each build)"
  echo "    Set RELAY_CODESIGN_IDENTITY, or install an Apple Development certificate."
  codesign --force --sign - "$APP/Contents/MacOS/relay-daemon" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

# Tell Launch Services about the freshly written bundle so launchers pick up
# metadata changes without waiting for a rescan.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

# The archive a release carries, and the one the in-app updater downloads.
# `ditto` rather than `zip`, because `zip` drops the symlinks and extended
# attributes a signed bundle is made of, and the copy fails verification on the
# other side.
ARCHIVE="$BUILD_DIR/Relay.app.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> Done: $APP"
echo "    Archive:  $ARCHIVE"
echo "    Install it with: ./Scripts/install.sh"
