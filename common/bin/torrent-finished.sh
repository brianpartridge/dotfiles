#!/bin/bash
#
# Transmission entry point. Set this file as the script to call when a
# download completes (Transmission > Preferences > Transfers > Management).
#
# Transmission launches the script with a minimal environment, so this wrapper:
#   - puts Homebrew on PATH so the right ruby and unrar are found
#   - captures all output to ~/logs/torrent-finished.out, including failures
#     that happen before the Ruby script gets as far as its own logging

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/bin:$PATH"

LOG_DIR="$HOME/logs"
OUT="$LOG_DIR/torrent-finished.out"
MAX_BYTES=$((5 * 1024 * 1024))

mkdir -p "$LOG_DIR"
if [ -f "$OUT" ] && [ "$(stat -f %z "$OUT" 2>/dev/null || stat -c %s "$OUT")" -gt "$MAX_BYTES" ]; then
  mv -f "$OUT" "$OUT.1"
fi
exec >> "$OUT" 2>&1

echo "=== $(date '+%Y-%m-%d %H:%M:%S') start: ${TR_TORRENT_NAME:-<no TR_TORRENT_NAME>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ruby "$DIR/torrent-finished.rb"
status=$?
echo "=== $(date '+%Y-%m-%d %H:%M:%S') exit $status"
exit $status
