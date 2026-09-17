#!/usr/bin/env bash
# Builds Relay.app with the session daemon embedded as a helper executable.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Which build this is. `RELAY_FLAVOUR=dev` assembles the one that stands beside
# the released app rather than replacing it: its own identity, its own name, its
# own data. Everything that would let the two reach each other is keyed by it,
# and the code reads the same variable, so the bundle and the app agree.
FLAVOUR="${RELAY_FLAVOUR:-release}"
case "$FLAVOUR" in
  dev|development)
    FLAVOUR="development"
    APP_NAME="Relay Dev"
    BUNDLE_ID="com.maketryuk.relay.dev"
    ICON_SOURCE="AppIconDev.icns"
    ;;
  release|prod|production)
    FLAVOUR="release"
    APP_NAME="Relay"
    BUNDLE_ID="com.maketryuk.relay"
    ICON_SOURCE="AppIcon.icns"
    ;;
  *)
    echo "error: unknown RELAY_FLAVOUR '$FLAVOUR' — use 'release' or 'dev'" >&2
    exit 1
    ;;
esac

# The file inside MacOS keeps its plain name whatever the bundle is called: it
# is what SwiftPM emits, and a space in an executable name helps nobody.
EXECUTABLE="Relay"
# Read from the Swift source so there is exactly one place to bump.
VERSION="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' "$ROOT/Sources/RelayProtocol/RelayVersion.swift" | head -1)"
VERSION="${VERSION:-0.0.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product Relay
swift build -c "$CONFIGURATION" --product relay-daemon
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Relay" "$APP/Contents/MacOS/$EXECUTABLE"
# The daemon ships inside the bundle so a released app never picks up a stale
# binary from a developer's build directory.
cp "$BIN_PATH/relay-daemon" "$APP/Contents/MacOS/relay-daemon"

# Named AppIcon inside the bundle whichever source it came from, so the plist
# does not have to know which build this is.
if [ -f "$ROOT/Resources/$ICON_SOURCE" ]; then
  cp "$ROOT/Resources/$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits resource bundles (SwiftTerm ships one) next to the binaries.
for bundle in "$BIN_PATH"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Relay's own strings are not optional furniture: the menu bar is built before
# the first window and asks for them immediately. A bundle assembled without
# them is a bundle that has to be caught here, not by whoever downloads it.
if [ ! -d "$APP/Contents/Resources/Relay_RelayUI.bundle" ]; then
  echo "error: Relay_RelayUI.bundle was not emitted into $BIN_PATH" >&2
  echo "       The app would launch with no string table at all." >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
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
#
# Developer ID first, and on a development build too: it is the certificate a
# release is signed with, and signing local builds with a different one means
# every switch between the two looks like a different app to macOS and asks for
# every permission again.
# `|| true` because no match is an answer, not a failure: under `set -o
# pipefail` an empty grep would otherwise take the whole build down with it.
find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "$1" \
    | sed -E 's/.*"(.*)"/\1/' || true
}

DISTRIBUTION="${RELAY_SIGN_FOR_DISTRIBUTION:-0}"
IDENTITY="${RELAY_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(find_identity "Developer ID Application")"
fi
if [ -z "$IDENTITY" ] && [ "$DISTRIBUTION" != "1" ]; then
  IDENTITY="$(find_identity "Apple Development")"
fi

if [ "$DISTRIBUTION" = "1" ] && [ -z "$IDENTITY" ]; then
  echo "error: distribution build needs a Developer ID Application certificate" >&2
  echo "       An Apple Development certificate signs builds for this machine only:" >&2
  echo "       every other Mac refuses them, notarisation included." >&2
  echo "       Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application" >&2
  exit 1
fi

if [ -n "$IDENTITY" ]; then
  echo "==> Signing as: $IDENTITY"
  # The hardened runtime is what notarisation requires, and it is applied to
  # development builds as well so that what is tested is what ships.
  SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
  if [ "$DISTRIBUTION" = "1" ]; then
    # A signature that outlives its certificate needs Apple to have witnessed
    # when it was made. Only for a release, because it costs a round trip to
    # Apple on every build.
    SIGN_FLAGS+=(--timestamp)
  else
    SIGN_FLAGS+=(--timestamp=none)
  fi

  # Nested binaries first, then the bundle, which is what --deep did badly.
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/relay-daemon"
  # SwiftPM resource bundles hold no executable code and codesign refuses them
  # outright ("bundle format unrecognized"); the outer signature seals them as
  # ordinary resources, which is what they are.
  codesign "${SIGN_FLAGS[@]}" "$APP"
  codesign --verify --strict --deep "$APP"
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
ARCHIVE="$BUILD_DIR/$APP_NAME.app.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> Done: $APP"
echo "    Archive:  $ARCHIVE"
echo "    Install it with: ./Scripts/install.sh"
