#!/usr/bin/env bash
# Installs Relay.app into /Applications so Spotlight, Raycast and the Dock can
# find it. Launchers only index the standard application directories, which is
# why running the app straight out of build/ leaves it invisible to them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/build/Relay.app"
DESTINATION="/Applications/Relay.app"

if [ ! -d "$SOURCE" ]; then
  echo "error: $SOURCE not found — run ./Scripts/build-app.sh first" >&2
  exit 1
fi

echo "==> Stopping a running copy"
pkill -f "Relay.app/Contents/MacOS/Relay" 2>/dev/null || true
# The daemon is deliberately left alone: it is the thing that keeps sessions
# alive, and the new build reconnects to it.

echo "==> Installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R "$SOURCE" "$DESTINATION"

# A bundle copied by the shell carries no quarantine flag, but one downloaded
# later would; clearing it keeps first launch friction-free.
xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true

echo "==> Registering with Launch Services"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  # Drop the development copy first: two bundles with the same identifier make
  # `open -a Relay` and launcher results ambiguous.
  "$LSREGISTER" -u "$SOURCE" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DESTINATION"
fi
# Nudge Spotlight so launchers that read its index see the app immediately.
mdimport "$DESTINATION" 2>/dev/null || true

echo "==> Installed. Open it from Spotlight or: open -a Relay"
