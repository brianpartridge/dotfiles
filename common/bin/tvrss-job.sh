#!/bin/bash

set -e

LOG="/Users/theater/logs/tvrss-job.log"
SNITCHID="6a30de3ccc"

# Necessary because the script needs the homebrew version of ruby, not ruby 2.0
export PATH="/usr/local/bin:$PATH"

date > $LOG
echo "Starting Job" >> $LOG
/Users/theater/bin/tvrss.rb >> $LOG
echo "Job Complete" >> $LOG
curl https://nosnch.in/$SNITCHID
echo "Monitoring Service Notified" >> $LOG

