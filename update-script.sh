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
echo "→ Checking addon updates..."
ADDONS_UPDATED=0
ADDONS_FAILED=0

for addon in $(ha addons list --format json 2>/dev/null | jq -r '.[] | select(.update_available == true) | .slug'); do
    echo "  Updating addon: $addon"
    if ha addons update "$addon" 2>&1 | tail -5; then
        UPDATED+=("Addon: $addon")
        ((ADDONS_UPDATED++))
    else
        FAILED+=("Addon: $addon")
        ((ADDONS_FAILED++))
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

# 3. Update HAOS
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

# 4. Reboot if needed
if [ $NEED_REBOOT -eq 1 ]; then
    echo "→ Rebooting HAOS..."
    ha host reboot
    # Note: script will be killed by reboot, message sent before reboot
fi

END_TIME=$(date +%s)
DURATION=$(format_duration $((END_TIME - START_TIME)))

# 5. Build and send report
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

MESSAGE="🏠 **HAOS Weekly Update Report** — $DATE_STR

⏱ **Duration:** $DURATION
🖥 **Host:** $HOSTNAME"

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