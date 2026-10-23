#!/bin/bash
#
# Deploys the Transmission web UI kept in home-server/web/transmission to the
# Mac's Apache document root, where home-server/conf/apache/transmission.conf
# expects it. Run after changing the UI. See home-server/web/README.md.
#
# Usage: transmission-web-deploy.sh
#   TRANSMISSION_WEB_DEST overrides the destination
#   (default /Library/WebServer/Documents/transmission/web).

set -euo pipefail

# Resolve this script's real location (stow symlinks ~/bin here), then go up
# to home-server/. macOS has no readlink -f, so follow links by hand.
self="$0"
while [ -L "$self" ]; do
  target="$(readlink "$self")"
  case "$target" in
    /*) self="$target" ;;
    *) self="$(dirname "$self")/$target" ;;
  esac
done
PACKAGE="$(cd -P "$(dirname "$self")/.." && pwd -P)"
SRC="$PACKAGE/web/transmission"
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
  git -C "$PACKAGE" log -1 --format='From commit %h (%s)' -- web/transmission 2>/dev/null || true
  if git -C "$PACKAGE" status --porcelain -- web/transmission 2>/dev/null | grep -q .; then
    echo "With uncommitted local changes"
  fi
} > "$DEST.new/DEPLOYED"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
rm -rf "$DEST.old"

count="$(find "$DEST" -type f | wc -l | tr -d ' ')"
echo "Deployed $count files to $DEST"

# The dashboard's CGI endpoint goes to Apache's stock CGI directory.
CGI_SRC="$PACKAGE/web/cgi/transfers-api.rb"
CGI_DIR="${TRANSFERS_CGI_DIR:-/Library/WebServer/CGI-Executables}"
if [ -w "$CGI_DIR" ]; then
  cp "$CGI_SRC" "$CGI_DIR/transfers-api.rb.new" && chmod 755 "$CGI_DIR/transfers-api.rb.new" && mv -f "$CGI_DIR/transfers-api.rb.new" "$CGI_DIR/transfers-api.rb"
  echo "Deployed transfers-api.rb to $CGI_DIR"
elif [ -d "$CGI_DIR" ]; then
  echo "Not deployed: $CGI_DIR is not writable. Once: sudo chown $(id -un) $CGI_DIR, or now: sudo install -m 755 $CGI_SRC $CGI_DIR/"
fi

# Quick check when Apache is on this machine; informational only.
if command -v curl >/dev/null 2>&1 && [ "$DEST" = "/Library/WebServer/Documents/transmission/web" ]; then
  web="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost/transmission/web/ || true)"
  rpc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST http://localhost/transmission/rpc || true)"
  echo "http://localhost/transmission/web/ -> ${web:-no answer} (want 200)"
  echo "http://localhost/transmission/rpc  -> ${rpc:-no answer} (want 409: Transmission answered through the proxy)"
fi
