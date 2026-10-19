#!/bin/bash
set -euo pipefail

# Set timezone
if [ -f /data/options.json ]; then
    TIMEZONE=$(jq -r '.timezone // "Europe/Kyiv"' /data/options.json)
    export TZ="$TIMEZONE"
    # IMPORTANT: dcron (crond) IGNORES the $TZ env var and schedules jobs by
    # /etc/localtime, which defaults to UTC in the HA base image. Without this
    # symlink "0 8 * * 1" would actually fire at 08:00 UTC (= 11:00 Kyiv).
    if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    fi
fi

echo "[$(date)] Starting HAOS Weekly Updater"
echo "Timezone: ${TZ:-Europe/Kyiv}"
echo "Localtime: $(readlink -f /etc/localtime 2>/dev/null || echo 'n/a')"

# Start cron daemon in foreground
crond -f -L /dev/stdout &
CRON_PID=$!

# Handle signals
trap 'kill $CRON_PID; wait $CRON_PID; echo "[$(date)] Stopped"; exit 0' SIGTERM SIGINT

# Keep running
wait $CRON_PID