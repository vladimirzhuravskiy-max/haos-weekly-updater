#!/bin/bash
set -euo pipefail

# Set timezone
if [ -f /data/options.json ]; then
    TIMEZONE=$(jq -r '.timezone // "Europe/Kyiv"' /data/options.json)
    export TZ="$TIMEZONE"
    # IMPORTANT: dcron (crond) IGNORES the $TZ env var and schedules jobs by
    # /etc/localtime, which defaults to UTC in the HA base image. Without this
    # symlink "0 8 * * 2" would actually fire at 08:00 UTC (= 11:00 Kyiv).
    if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || true
    fi
fi

echo "[$(date)] Starting HAOS Weekly Updater"
echo "Timezone: ${TZ:-Europe/Kyiv}"
echo "Localtime: $(readlink -f /etc/localtime 2>/dev/null || echo 'n/a')"

# On-demand run: switching run_on_start from false to true executes the update
# script once immediately (state is remembered in /data, so leaving the option
# enabled does not re-run the update on every container restart). Handy for a
# manual run or to verify a freshly deployed version without waiting for cron.
if [ -f /data/options.json ]; then
    RUN_ON_START=$(jq -r '.run_on_start // false' /data/options.json)
    STATE_FILE="/data/.run_on_start_state"
    PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "unset")
    if [ "$RUN_ON_START" = "true" ] && [ "$PREV_STATE" != "true" ]; then
        echo "run_on_start switched to true — starting update-script.sh"
        (/update-script.sh &) || true
    fi
    echo "$RUN_ON_START" > "$STATE_FILE" 2>/dev/null || true
fi

# Start cron daemon in foreground
crond -f -L /dev/stdout &
CRON_PID=$!

# Handle signals
trap 'kill $CRON_PID; wait $CRON_PID; echo "[$(date)] Stopped"; exit 0' SIGTERM SIGINT

# Keep running
wait $CRON_PID