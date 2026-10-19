#!/bin/bash
set -euo pipefail

# Load options
if [ ! -f /data/options.json ]; then
    echo "ERROR: /data/options.json not found"
    exit 1
fi

TELEGRAM_BOT_TOKEN=$(jq -r '.telegram_bot_token // ""' /data/options.json)
TELEGRAM_CHAT_ID=$(jq -r '.telegram_chat_id // ""' /data/options.json)
ADMIN_CHAT_ID=$(jq -r '.admin_chat_id // ""' /data/options.json)

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "ERROR: telegram_bot_token and telegram_chat_id must be set in options"
    exit 1
fi

LOG_FILE="/data/update-$(date +%F).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Supervisor token is injected by the Supervisor (hassio_api: true)
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN:-}"

echo "=== HAOS Weekly Update $(date) ==="

UPDATED=()
FAILED=()
NEED_REBOOT=0

# Function to send Telegram message
send_telegram() {
    local chat_id="$1"
    local text="$2"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${chat_id}" \
        -d parse_mode="Markdown" \
        -d text="$text" > /dev/null
}

# Function to format duration
format_duration() {
    local seconds=$1
    printf '%02d:%02d:%02d' $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
}

START_TIME=$(date +%s)

# 1. Update Add-ons
echo "→ Refreshing app stores (git pull)..."
REFRESH_OUT=$(timeout 120 ha refresh-updates 2>&1 || true)
if echo "$REFRESH_OUT" | grep -qi "success"; then
    echo "  Stores refreshed"
else
    echo "  WARNING: refresh-updates output: $(echo "$REFRESH_OUT" | tr -d '\n' | head -c 300)"
fi

echo "→ Checking addon updates..."
ADDONS_UPDATED=0
ADDONS_FAILED=0

for addon in $(ha addons list --format json 2>/dev/null | jq -r '.[] | select(.update_available == true) | .slug'); do
    echo "  Updating addon: $addon"
    if ha addons update "$addon" 2>&1 | tail -5; then
        UPDATED+=("Addon: $addon")
        ADDONS_UPDATED=$((ADDONS_UPDATED + 1))
    else
        FAILED+=("Addon: $addon")
        ADDONS_FAILED=$((ADDONS_FAILED + 1))
    fi
done

if [ $ADDONS_UPDATED -eq 0 ] && [ $ADDONS_FAILED -eq 0 ]; then
    echo "  No addon updates available"
fi

# 2. Update HA Core
echo "→ Checking HA Core update..."
CORE_INFO=$(ha core info --format json 2>/dev/null || echo '{}')
if echo "$CORE_INFO" | jq -e '.update_available == true' > /dev/null; then
    CURRENT=$(echo "$CORE_INFO" | jq -r '.version // "unknown"')
    LATEST=$(echo "$CORE_INFO" | jq -r '.version_latest // "unknown"')
    echo "  Updating HA Core: $CURRENT -> $LATEST"
    if ha core update 2>&1 | tail -5; then
        UPDATED+=("HA Core ($CURRENT -> $LATEST)")
    else
        FAILED+=("HA Core ($CURRENT -> $LATEST)")
    fi
else
    echo "  HA Core is up to date"
fi

# 3. Update integrations (HACS and other update.* entities)
# Access to the HA API goes through the Supervisor proxy:
#   http://supervisor/core/api/... + X-Supervisor-Token
# (allowed because this add-on has homeassistant_api: true)
echo "→ Checking integration updates..."
HA_API="http://supervisor/core/api"
INTEGRATIONS_UPDATED=0
INTEGRATIONS_FAILED=0

# Read pending integration updates. Explicitly skipped (they are handled above):
#   - HA Core / HAOS / Supervisor (steps 2 and 4)
#   - add-on updates (step 1, they come with entity_picture=/api/hassio/...)
#   - device firmware (OTA of ESPHome/Zigbee devices is not touched)
echo "  DIAG: SUPERVISOR_TOKEN len=${#SUPERVISOR_TOKEN}, SUPERVISOR_HOST=${SUPERVISOR_HOST:-unset}"
echo "  DIAG: ha ping -> $(timeout 30 ha ping 2>&1 | tr -d '\n' | head -c 200)"

HTTP_CODE=$(curl -s -o /tmp/ha_states.json -w '%{http_code}' --max-time 60 \
    -H "X-Supervisor-Token: ${SUPERVISOR_TOKEN:-}" \
    "$HA_API/states" 2>/dev/null || echo '000')
echo "  DIAG: GET $HA_API/states -> HTTP $HTTP_CODE, bytes=$(wc -c < /tmp/ha_states.json 2>/dev/null || echo 0)"
head -c 300 /tmp/ha_states.json 2>/dev/null; echo

PENDING_INTEGRATIONS=$(jq -c '
    [ .[]
      | select(.entity_id | startswith("update."))
      | select(.state == "on")
      | select(.entity_id | test("^update\\.(home_assistant_core|home_assistant_operating_system|supervisor|observer)") | not)
      | select((.attributes.entity_picture // "") | contains("/api/hassio/") | not)
      | select((.attributes.device_class // "") != "firmware")
      | {
          entity: .entity_id,
          name: (.attributes.friendly_name // .entity_id),
          installed: (.attributes.installed_version // "?"),
          latest: (.attributes.latest_version // "?")
        }
    ]' /tmp/ha_states.json 2>/dev/null || echo 'ERROR')

if [ "$PENDING_INTEGRATIONS" = "ERROR" ] || ! echo "$PENDING_INTEGRATIONS" | jq -e 'type == "array"' > /dev/null 2>&1; then
    echo "  ERROR: cannot read HA states via supervisor proxy"
    FAILED+=("Інтеграції: не вдалося отримати список станів Home Assistant API")
else
    PENDING_COUNT=$(echo "$PENDING_INTEGRATIONS" | jq 'length')
    echo "  Found $PENDING_COUNT integration update(s)"

    if [ "$PENDING_COUNT" -gt 0 ]; then
        echo "$PENDING_INTEGRATIONS" | jq -r '.[] | "  - \(.name) (\(.installed) -> \(.latest)) [\(.entity)]"'

        while IFS=$'\t' read -r ENTITY NAME INSTALLED LATEST; do
            [ -z "$ENTITY" ] && continue
            echo "  Updating integration: $NAME ($INSTALLED -> $LATEST)"

            HTTP_CODE=$(curl -s -o /tmp/ha_install_resp.json -w '%{http_code}' --max-time 60 \
                -H "X-Supervisor-Token: ${SUPERVISOR_TOKEN:-}" \
                -H "Content-Type: application/json" \
                -d "{\"entity_id\": \"$ENTITY\"}" \
                "$HA_API/services/update/install" 2>/dev/null || echo '000')

            if [ "$HTTP_CODE" = "200" ]; then
                UPDATED+=("Інтеграція: $NAME ($INSTALLED -> $LATEST)")
                INTEGRATIONS_UPDATED=$((INTEGRATIONS_UPDATED + 1))
                # give Home Assistant time to apply the update before the next one
                sleep 5
            else
                echo "    HTTP $HTTP_CODE: $(head -c 300 /tmp/ha_install_resp.json 2>/dev/null)"
                FAILED+=("Інтеграція: $NAME (HTTP $HTTP_CODE)")
                INTEGRATIONS_FAILED=$((INTEGRATIONS_FAILED + 1))
            fi
        done < <(echo "$PENDING_INTEGRATIONS" | jq -r '.[] | [.entity, .name, .installed, .latest] | @tsv')
    else
        echo "  No integration updates available"
    fi
fi

# 4. Update HAOS
echo "→ Checking HAOS update..."
OS_INFO=$(ha os info --format json 2>/dev/null || echo '{}')
if echo "$OS_INFO" | jq -e '.update_available == true' > /dev/null; then
    CURRENT=$(echo "$OS_INFO" | jq -r '.version // "unknown"')
    LATEST=$(echo "$OS_INFO" | jq -r '.version_latest // "unknown"')
    echo "  Updating HAOS: $CURRENT -> $LATEST"
    if ha os update 2>&1 | tail -5; then
        UPDATED+=("HAOS ($CURRENT -> $LATEST)")
        NEED_REBOOT=1
    else
        FAILED+=("HAOS ($CURRENT -> $LATEST)")
    fi
else
    echo "  HAOS is up to date"
fi

# 5. Reboot if needed
if [ $NEED_REBOOT -eq 1 ]; then
    echo "→ Rebooting HAOS..."
    ha host reboot
    # Note: script will be killed by reboot, message sent before reboot
fi

END_TIME=$(date +%s)
DURATION=$(format_duration $((END_TIME - START_TIME)))

# 6. Build and send report
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

MESSAGE="🏠 **HAOS Weekly Update Report** — $DATE_STR

⏱ **Duration:** $DURATION
🖥 **Host:** $HOSTNAME"

if [ "$INTEGRATIONS_UPDATED" -gt 0 ] || [ "$INTEGRATIONS_FAILED" -gt 0 ]; then
    MESSAGE="$MESSAGE
🧩 **Інтеграції:** оновлено $INTEGRATIONS_UPDATED, помилок $INTEGRATIONS_FAILED"
fi

if [ ${#UPDATED[@]} -gt 0 ]; then
    MESSAGE="$MESSAGE

✅ **Оновлено (${#UPDATED[@]}):**"
    for item in "${UPDATED[@]}"; do
        MESSAGE="$MESSAGE
• $item"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    MESSAGE="$MESSAGE

❌ **Проблеми (${#FAILED[@]}):**"
    for item in "${FAILED[@]}"; do
        MESSAGE="$MESSAGE
• $item"
    done
fi

if [ $NEED_REBOOT -eq 1 ]; then
    MESSAGE="$MESSAGE

🔄 **Дія:** HAOS перезавантажено автоматично"
fi

if [ ${#UPDATED[@]} -eq 0 ] && [ ${#FAILED[@]} -eq 0 ]; then
    MESSAGE="$MESSAGE

ℹ️ Оновлень не знайдено — все актуально"
fi

MESSAGE="$MESSAGE

📋 **Деталі:** \`$LOG_FILE\`"

# Send to main chat
send_telegram "$TELEGRAM_CHAT_ID" "$MESSAGE"

# Send to admin chat if different and there were failures
if [ -n "$ADMIN_CHAT_ID" ] && [ "$ADMIN_CHAT_ID" != "$TELEGRAM_CHAT_ID" ] && [ ${#FAILED[@]} -gt 0 ]; then
    send_telegram "$ADMIN_CHAT_ID" "⚠️ **HAOS Update Alert** — ${#FAILED[@]} problem(s) detected
$MESSAGE"
fi

echo "=== Update completed $(date) ==="