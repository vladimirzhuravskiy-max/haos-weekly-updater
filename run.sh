#!/bin/bash
set -euo pipefail

# Set timezone
if [ -f /data/options.json ]; then
    TIMEZONE=$(jq -r '.timezone // "Europe/Kyiv"' /data/options.json)
    export TZ="$TIMEZONE"
fi

echo "[$(date)] Starting HAOS Weekly Updater"
echo "Timezone: ${TZ:-Europe/Kyiv}"

# Start cron daemon in foreground
crond -f -L /dev/stdout &
CRON_PID=$!

# Handle signals
trap 'kill $CRON_PID; wait $CRON_PID; echo "[$(date)] Stopped"; exit 0' SIGTERM SIGINT

# Keep running
wait $CRON_PID