#!/usr/bin/env bash
# Builds Relay.app with the session daemon embedded as a helper executable, and
# the Chromium the browser pane draws with.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=Scripts/chromium.sh
source "$ROOT/Scripts/chromium.sh"

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
swift build -c "$CONFIGURATION" --product relay-browser-helper
swift build -c "$CONFIGURATION" --product relay-hook
swift build -c "$CONFIGURATION" --product relay-cli
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN_PATH/Relay" "$APP/Contents/MacOS/$EXECUTABLE"
# The daemon ships inside the bundle so a released app never picks up a stale
# binary from a developer's build directory.
cp "$BIN_PATH/relay-daemon" "$APP/Contents/MacOS/relay-daemon"
# What an agent's hook runs in a Relay terminal. Beside the daemon, which is
# where the daemon looks for it and tells its terminals it is.
cp "$BIN_PATH/relay-hook" "$APP/Contents/MacOS/relay-hook"
# The command agents run in a Relay terminal, named what they type. In a
# directory of its own because the daemon puts that directory on every
# terminal's PATH: MacOS would put the app there too, and on a file system that
# does not tell `relay` from `Relay`, typing one would start the other.
cp "$BIN_PATH/relay-cli" "$APP/Contents/Helpers/relay"

# The framework and the helper apps its processes run in. Downloaded once per
# machine, pinned and checked, by Scripts/chromium.sh.
echo "==> Embedding Chromium"
chromium_embed "$APP" "$BIN_PATH/relay-browser-helper" "$BUNDLE_ID" "$VERSION"

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

# Temporary, for the editor lab. `CodeEditLanguages` looks for its tree-sitter
# queries at `Bundle.module.resourceURL` + `"Resources/<grammar>/highlights.scm"`,
# which is the bundle root in an Xcode build and already `Resources` in a
# SwiftPM one — so the path doubles, every query fails to load, and the editor
# draws the file in plain white with nothing saying why. The links make the path
# it asks for true, and they go in before signing so the signature covers them.
# This goes when the lab does.
GRAMMARS="$APP/Contents/Resources/CodeEditLanguages_CodeEditLanguages.bundle/Resources"
if [ -d "$GRAMMARS" ]; then
  mkdir -p "$GRAMMARS/Resources"
  for grammar in "$GRAMMARS"/tree-sitter-*; do
    [ -d "$grammar" ] || continue
    ln -sfn "../$(basename "$grammar")" "$GRAMMARS/Resources/$(basename "$grammar")"
  done
fi

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
    <key>NSDocumentsFolderUsageDescription</key><string>Relay opens the files of the projects you add to it.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Relay opens the files of the projects you add to it.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Relay opens the files of the projects you add to it.</string>
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
  chromium_sign "$APP" "$BUILD_DIR/entitlements" "${SIGN_FLAGS[@]}"
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/relay-daemon"
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/relay-hook"
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/relay"
  # SwiftPM resource bundles hold no executable code and codesign refuses them
  # outright ("bundle format unrecognized"); the outer signature seals them as
  # ordinary resources, which is what they are.
  codesign "${SIGN_FLAGS[@]}" "$APP"
  codesign --verify --strict --deep "$APP"
else
  echo "==> Signing (ad-hoc — macOS will re-ask for permissions after each build)"
  echo "    Set RELAY_CODESIGN_IDENTITY, or install an Apple Development certificate."
  chromium_sign "$APP" "$BUILD_DIR/entitlements" --force --sign - >/dev/null 2>&1 || true
  codesign --force --sign - "$APP/Contents/MacOS/relay-daemon" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP/Contents/MacOS/relay-hook" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP/Contents/Helpers/relay" >/dev/null 2>&1 || true
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
