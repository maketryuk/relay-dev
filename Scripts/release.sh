#!/usr/bin/env bash
# Turns the current source into the two files a release is made of: the archive
# the in-app updater downloads, and a disk image a person downloads.
#
# Both are signed with Developer ID and notarised. Anything less is an app that
# only opens on the machine that built it: a development certificate is not a
# distribution certificate, and macOS refuses the difference rather than
# warning about it.
#
#   ./Scripts/release.sh            build and notarise into build/release
#   ./Scripts/release.sh --publish  and create the GitHub release from them
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUBLISH=0
for argument in "$@"; do
  case "$argument" in
    --publish) PUBLISH=1 ;;
    *) echo "error: unknown argument $argument" >&2; exit 1 ;;
  esac
done

VERSION="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' Sources/RelayProtocol/RelayVersion.swift | head -1)"
if [ -z "$VERSION" ]; then
  echo "error: could not read the version from Sources/RelayProtocol/RelayVersion.swift" >&2
  exit 1
fi

APP="$ROOT/build/Relay.app"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Relay-$VERSION.app.zip"
IMAGE="$OUT/Relay-$VERSION.dmg"
NOTES="$OUT/notes-$VERSION.md"
PROFILE="${RELAY_NOTARY_PROFILE:-relay-notary}"

# --- What has to be true before anything is built ------------------------

# The artefact has to correspond to a commit; "what exactly did we ship" is not
# a question a working copy can answer.
if [ "${RELAY_ALLOW_DIRTY:-0}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree has uncommitted changes" >&2
  echo "       Commit them, or set RELAY_ALLOW_DIRTY=1 to build one anyway." >&2
  exit 1
fi

IDENTITY="${RELAY_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # `|| true` because not finding one is the case this script exists to explain,
  # and under `set -o pipefail` an empty grep would exit before it could.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" \
    | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [ -z "$IDENTITY" ]; then
  echo "error: no Developer ID Application certificate in the keychain" >&2
  echo "       Xcode → Settings → Accounts → your team → Manage Certificates →" >&2
  echo "       + → Developer ID Application. Only the account holder can create one." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" --limit 1 >/dev/null 2>&1; then
  echo "error: no notarisation credentials stored as \"$PROFILE\"" >&2
  echo "       Store them once with an App Store Connect API key:" >&2
  echo "       xcrun notarytool store-credentials \"$PROFILE\" \\" >&2
  echo "         --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>" >&2
  exit 1
fi

# A release with no notes tells nobody anything.
release_notes() {
  awk -v heading="## $VERSION" '
    index($0, heading) == 1 { capturing = 1; next }
    capturing && /^## / { exit }
    capturing { print }
  ' CHANGELOG.md
}

if [ -z "$(release_notes | tr -d '[:space:]')" ]; then
  echo "error: CHANGELOG.md has no section for $VERSION" >&2
  echo "       Rename the Unreleased heading to it before cutting the release." >&2
  exit 1
fi

echo "==> Releasing $VERSION as: $IDENTITY"
rm -rf "$OUT"
mkdir -p "$OUT"
release_notes > "$NOTES"

# --- The application -----------------------------------------------------

RELAY_SIGN_FOR_DISTRIBUTION=1 RELAY_CODESIGN_IDENTITY="$IDENTITY" ./Scripts/build-app.sh release

notarise() {
  local file="$1"
  local log="$OUT/notary-$(basename "$file").json"
  echo "==> Notarising $(basename "$file") — Apple takes a minute or two"
  if ! xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$log"; then
    local submission
    submission="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$log" | head -1)"
    echo "error: notarisation failed" >&2
    [ -n "$submission" ] && \
      echo "       xcrun notarytool log $submission --keychain-profile $PROFILE" >&2
    exit 1
  fi
}

# Apple is given the archive the build already produced; the ticket it issues is
# then stapled into the bundle, so a first launch with no network still passes.
notarise "$ROOT/build/Relay.app.zip"
xcrun stapler staple "$APP"

# Re-made after stapling: the ticket lives inside the bundle, and the archive
# built before it does not carry one.
ditto -c -k --keepParent "$APP" "$ARCHIVE"

# --- The disk image ------------------------------------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Relay.app"
# The drag-to-install gesture everyone already knows.
ln -s /Applications "$STAGE/Applications"

echo "==> Building $(basename "$IMAGE")"
hdiutil create \
  -volname "Relay $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$IMAGE" >/dev/null

codesign --force --timestamp --sign "$IDENTITY" "$IMAGE"
notarise "$IMAGE"
xcrun stapler staple "$IMAGE"

# --- What a stranger's Mac will make of them -----------------------------

echo "==> Checking what Gatekeeper sees"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$IMAGE"

echo "==> Done"
echo "    Archive: $ARCHIVE"
echo "    Image:   $IMAGE"
echo "    Notes:   $NOTES"

# --- Publishing ----------------------------------------------------------

if [ "$PUBLISH" != "1" ]; then
  echo
  echo "Nothing has been published. When the release is wanted:"
  echo "  git tag v$VERSION && git push origin v$VERSION"
  echo "  ./Scripts/release.sh --publish"
  exit 0
fi

if ! git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "error: there is no tag v$VERSION to hang the release on" >&2
  echo "       git tag v$VERSION && git push origin v$VERSION" >&2
  exit 1
fi

echo "==> Publishing v$VERSION"
gh release create "v$VERSION" \
  --title "$VERSION" \
  --notes-file "$NOTES" \
  "$ARCHIVE" \
  "$IMAGE"
