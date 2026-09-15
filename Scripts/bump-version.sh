#!/usr/bin/env bash
# Moves RelayVersion.current on, which is the only place the version is written.
#
# The last component is a build counter rather than a bug count: it goes up for
# every published build and resets when the minor moves. Nobody has to decide
# whether a day's work "deserves" a version, which is a question about nothing.
set -euo pipefail

PART="${1:-build}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/Sources/RelayProtocol/RelayVersion.swift"

CURRENT="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' "$FILE" | head -1)"
[ -n "$CURRENT" ] || { echo "Could not read the current version from $FILE" >&2; exit 1; }

CORE="${CURRENT%%-*}"
SUFFIX=""
[ "$CORE" != "$CURRENT" ] && SUFFIX="${CURRENT#*-}"
IFS=. read -r MAJOR MINOR BUILD <<<"$CORE"

case "$PART" in
  build)
    if [ -n "$SUFFIX" ]; then
      # Still a candidate for a version that has not shipped. Counting the build
      # forward would step over that version as though it had.
      NUMBER="${SUFFIX//[!0-9]/}"
      NAME="${SUFFIX//[0-9]/}"
      NEXT="$CORE-$NAME$(( ${NUMBER:-0} + 1 ))"
    else
      NEXT="$MAJOR.$MINOR.$(( BUILD + 1 ))"
    fi
    ;;
  release)
    # Drops the candidate suffix: this is the version it was a candidate for.
    [ -n "$SUFFIX" ] || { echo "$CURRENT is already a release" >&2; exit 1; }
    NEXT="$CORE"
    ;;
  minor) NEXT="$MAJOR.$(( MINOR + 1 )).0" ;;
  major) NEXT="$(( MAJOR + 1 )).0.0" ;;
  *)
    echo "Usage: $(basename "$0") [build|release|minor|major]" >&2
    exit 1
    ;;
esac

# Anchored on the declaration so nothing else in the file can match.
sed -i '' "s/static let current = \".*\"/static let current = \"$NEXT\"/" "$FILE"
echo "$CURRENT -> $NEXT"
