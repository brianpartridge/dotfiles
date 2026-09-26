#!/bin/bash
#
# Deploys the Transmission web UI kept in common/web/transmission to the
# Mac's Apache document root, where common/conf/apache/transmission.conf
# expects it. Run after changing the UI. See common/web/README.md.
#
# Usage: transmission-web-deploy.sh
#   TRANSMISSION_WEB_DEST overrides the destination
#   (default /Library/WebServer/Documents/transmission/web).

set -euo pipefail

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
SRC="$COMMON/web/transmission"
DEST="${TRANSMISSION_WEB_DEST:-/Library/WebServer/Documents/transmission/web}"
PARENT="$(dirname "$DEST")"

if [ ! -f "$SRC/index.html" ]; then
  echo "No web UI at $SRC" >&2
  exit 1
fi

if [ ! -d "$PARENT" ] || [ ! -w "$PARENT" ]; then
  echo "Cannot write to $PARENT. Create it once, owned by you:" >&2
  echo "  sudo mkdir -p $PARENT && sudo chown ${USER:-$(id -un)} $PARENT" >&2
  exit 1
fi

# Stage next to the destination and swap, so Apache never serves a half-copied tree.
rm -rf "$DEST.new" "$DEST.old"
mkdir -p "$DEST.new"
cp -R "$SRC/." "$DEST.new/"
{
  echo "Deployed $(date '+%Y-%m-%d %H:%M:%S')"
  git -C "$COMMON" log -1 --format='From commit %h (%s)' -- web/transmission 2>/dev/null || true
  if git -C "$COMMON" status --porcelain -- web/transmission 2>/dev/null | grep -q .; then
    echo "With uncommitted local changes"
  fi
} > "$DEST.new/DEPLOYED"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
rm -rf "$DEST.old"

count="$(find "$DEST" -type f | wc -l | tr -d ' ')"
echo "Deployed $count files to $DEST"

# Quick check when Apache is on this machine; informational only.
if command -v curl >/dev/null 2>&1 && [ "$DEST" = "/Library/WebServer/Documents/transmission/web" ]; then
  web="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost/transmission/web/ || true)"
  rpc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST http://localhost/transmission/rpc || true)"
  echo "http://localhost/transmission/web/ -> ${web:-no answer} (want 200)"
  echo "http://localhost/transmission/rpc  -> ${rpc:-no answer} (want 409: Transmission answered through the proxy)"
fi
