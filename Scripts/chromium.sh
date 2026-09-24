# shellcheck shell=bash
# Chromium for the browser pane: which build, where it is kept, and how it goes
# into a bundle. Sourced by build-app.sh; nothing here runs on its own.
#
# The Swift package carries only CEF's headers, so `swift build` and the tests
# never need any of this. What they cannot give the app is the framework itself
# (320 MB unpacked) and the helper apps Chromium starts its other processes
# from, and those are what these functions add.

# One build, pinned, because the headers in `Sources/CChromium/cef` describe it:
# a framework whose structures are laid out differently is refused at launch.
# Moving to another version means replacing those headers in the same change.
CHROMIUM_VERSION="154.0.26+ge72305f+chromium-154.0.8037.58"
# SHA-1, because that is what the CEF build index publishes for each archive.
CHROMIUM_SHA1_ARM64="d568aa34169cc605e35e42312636489202e55918"
# The languages Relay itself speaks. Chromium brings two hundred, 49 MB of them,
# and a page's error text in a language the rest of the window is not in helps
# nobody.
CHROMIUM_LOCALES=(en ru)
# The helper Chromium starts first and the variants it derives from its name,
# with the bundle identifier suffix each one takes.
CHROMIUM_HELPERS=(":" " (Alerts):.alerts" " (GPU):.gpu" " (Plugin):.plugin" " (Renderer):.renderer")
CHROMIUM_HELPER_NAME="Relay Helper"

chromium_log() {
  echo "$@" >&2
}

# Prints the directory of the unpacked distribution, downloading it first if
# this machine has not got it yet.
#
# Kept outside the checkout so that every worktree and every clean shares one
# 130 MB download.
chromium_fetch() {
  if [ "$(uname -m)" != "arm64" ]; then
    chromium_log "error: the browser pane's Chromium is pinned for Apple silicon only"
    return 1
  fi
  local platform="macosarm64"
  local sha1="$CHROMIUM_SHA1_ARM64"
  local cache="${RELAY_CHROMIUM_CACHE:-$HOME/Library/Caches/com.maketryuk.relay/chromium}"
  local name="cef_binary_${CHROMIUM_VERSION}_${platform}_minimal"
  local distribution="$cache/$name"

  if [ -d "$distribution/Release/Chromium Embedded Framework.framework" ]; then
    echo "$distribution"
    return 0
  fi

  mkdir -p "$cache"
  local archive="$cache/$name.tar.bz2"
  # `+` is a space to the CDN unless it is escaped.
  local url="https://cef-builds.spotifycdn.com/${name//+/%2B}.tar.bz2"
  chromium_log "==> Downloading Chromium $CHROMIUM_VERSION"
  curl --fail --location --retry 3 --progress-bar --output "$archive.partial" "$url"
  # Checked before it is unpacked: this archive ends up signed with Relay's
  # name on it.
  if ! echo "$sha1  $archive.partial" | shasum -a 1 -c - >/dev/null; then
    rm -f "$archive.partial"
    chromium_log "error: the Chromium download does not match its published checksum"
    return 1
  fi
  mv "$archive.partial" "$archive"
  rm -rf "$distribution.partial"
  mkdir -p "$distribution.partial"
  tar -xjf "$archive" -C "$distribution.partial" --strip-components 1
  rm -f "$archive"
  mv "$distribution.partial" "$distribution"
  echo "$distribution"
}

# chromium_embed APP HELPER_BINARY BUNDLE_ID VERSION
#
# Puts the framework and the helper apps into APP's Frameworks directory.
chromium_embed() {
  local app="$1" helper_binary="$2" bundle_id="$3" version="$4"
  local distribution
  distribution="$(chromium_fetch)" || return 1

  local frameworks="$app/Contents/Frameworks"
  local source="$distribution/Release/Chromium Embedded Framework.framework"
  local framework="$frameworks/Chromium Embedded Framework.framework"
  mkdir -p "$framework/Versions/A/Resources"

  # The versioned layout rather than the flat one CEF ships: codesign in
  # Xcode 26 refuses a framework without it (CEF's README says the same).
  cp "$source/Chromium Embedded Framework" "$framework/Versions/A/"
  cp -R "$source/Libraries" "$framework/Versions/A/"
  local resource
  for resource in "$source/Resources/"*; do
    case "$resource" in
      *.lproj) ;;
      *) cp -R "$resource" "$framework/Versions/A/Resources/" ;;
    esac
  done
  local locale
  for locale in "${CHROMIUM_LOCALES[@]}"; do
    cp -R "$source/Resources/$locale.lproj" "$framework/Versions/A/Resources/"
  done
  ln -sfn A "$framework/Versions/Current"
  ln -sfn "Versions/A/Chromium Embedded Framework" "$framework/Chromium Embedded Framework"
  ln -sfn Versions/A/Libraries "$framework/Libraries"
  ln -sfn Versions/A/Resources "$framework/Resources"

  # One executable, five bundles: Chromium finds the variant for each kind of
  # process by the name, and each needs its own Info.plist so that none of
  # them puts an icon in the Dock.
  local entry suffix id_suffix name helper
  for entry in "${CHROMIUM_HELPERS[@]}"; do
    suffix="${entry%%:*}"
    id_suffix="${entry#*:}"
    name="$CHROMIUM_HELPER_NAME$suffix"
    helper="$frameworks/$name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$helper_binary" "$helper/Contents/MacOS/$name"
    printf 'APPL????' > "$helper/Contents/PkgInfo"
    cat > "$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$bundle_id.helper$id_suffix</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
    <key>LSFileQuarantineEnabled</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
  done
}

# chromium_sign APP ENTITLEMENTS_DIR CODESIGN_FLAGS...
#
# Signs what chromium_embed added, innermost first, with the flags the app
# itself is signed with. The helpers are where Chromium's JavaScript and GPU
# code run, and under the hardened runtime that code may only write executable
# memory if the helper is entitled to.
chromium_sign() {
  local app="$1" entitlements_dir="$2"
  shift 2
  local frameworks="$app/Contents/Frameworks"
  local framework="$frameworks/Chromium Embedded Framework.framework"
  local entitlements="$entitlements_dir/chromium-helper.entitlements"

  mkdir -p "$entitlements_dir"
  cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
PLIST

  local library helper
  for library in "$framework/Versions/A/Libraries/"*.dylib; do
    codesign "$@" "$library"
  done
  codesign "$@" "$framework/Versions/A"
  for helper in "$frameworks/$CHROMIUM_HELPER_NAME"*.app; do
    codesign "$@" --entitlements "$entitlements" "$helper"
  done
}
