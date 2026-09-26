#!/bin/bash
#
# Copies the web UI out of Transmission.app into common/web/transmission, so
# Apache can serve it (common/conf/apache/transmission.conf) and it can be
# modified in this repository. See common/web/README.md.
#
# Usage: transmission-web-import.sh [/path/to/Transmission.app]
#
# Re-run after upgrading Transmission. The import refuses to run over
# uncommitted changes, so that upstream's changes always land as a reviewable
# diff on top of whatever has been customised here.

set -euo pipefail

APP="${1:-/Applications/Transmission.app}"
SRC="$APP/Contents/Resources/web"

# Resolve this script's real location (stow symlinks ~/bin here), then go up
# to common/. macOS has no readlink -f, so follow links by hand.
self="$0"
while [ -L "$self" ]; do
  target="$(readlink "$self")"
  case "$target" in
    /*) self="$target" ;;
    *) self="$(dirname "$self")/$target" ;;
  esac
done
COMMON="$(cd -P "$(dirname "$self")/.." && pwd -P)"
DEST="${TRANSMISSION_WEB_DEST:-$COMMON/web/transmission}"

if [ ! -f "$SRC/index.html" ]; then
  echo "No web UI found at $SRC. Is $APP the Transmission app?" >&2
  exit 1
fi

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"

if [ -d "$DEST" ] && git -C "$DEST" status --porcelain -- . 2>/dev/null | grep -q .; then
  echo "There are uncommitted changes under $DEST." >&2
  echo "Commit or stash them first, so the import can be reviewed as a diff." >&2
  exit 1
fi

# Replace wholesale: anything previously here is in git, and the check above
# guarantees the tree was clean, so upstream's changes show up as a plain diff.
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"
{
  echo "Transmission $VERSION"
  echo "Imported from $SRC"
  echo "On $(date '+%Y-%m-%d')"
} > "$DEST/UPSTREAM"

count="$(find "$DEST" -type f | wc -l | tr -d ' ')"
echo "Imported the Transmission $VERSION web UI ($count files) into $DEST"
if [ -d "$DEST/.git" ] || git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Review with: git -C $COMMON status web/transmission"
fi
