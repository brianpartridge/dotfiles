#!/bin/bash

set -e

LOG="/Users/theater/logs/tvrss-job.log"
SNITCHID="6a30de3ccc"

# Use the rbenv Ruby, not the macOS system Ruby.
export PATH="$HOME/.rbenv/shims:/usr/local/bin:$PATH"

{
  date
  echo "Starting Job"
  /Users/theater/bin/tvrss.rb
  echo "Job Complete"
} > "$LOG"
curl "https://nosnch.in/$SNITCHID"
echo "Monitoring Service Notified" >> "$LOG"

