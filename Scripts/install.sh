#!/usr/bin/env bash
# Installs Relay.app into /Applications so Spotlight, Raycast and the Dock can
# find it. Launchers only index the standard application directories, which is
# why running the app straight out of build/ leaves it invisible to them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The same variable the build script reads, so `RELAY_FLAVOUR=dev` installs the
# build that variable produced rather than looking for one that was never made.
case "${RELAY_FLAVOUR:-release}" in
  dev|development) APP_NAME="Relay Dev" ;;
  release|prod|production) APP_NAME="Relay" ;;
  *) echo "error: unknown RELAY_FLAVOUR '${RELAY_FLAVOUR}' — use 'release' or 'dev'" >&2; exit 1 ;;
esac

SOURCE="$ROOT/build/$APP_NAME.app"
DESTINATION="/Applications/$APP_NAME.app"

if [ ! -d "$SOURCE" ]; then
  echo "error: $SOURCE not found — run ./Scripts/build-app.sh first" >&2
  exit 1
fi

# Only this flavour's copy: the other one is somebody's working day, and the
# two do not share a daemon, a workspace or a reason to be stopped together.
echo "==> Stopping a running copy of $APP_NAME"
pkill -f "$APP_NAME.app/Contents/MacOS/Relay" 2>/dev/null || true
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

echo "==> Installed. Open it from Spotlight or: open -a \"$APP_NAME\""
