#!/bin/bash
# Telegram notification library for HAOS Weekly Updater
# Usage: source /telegram.sh && send_telegram "chat_id" "message"

send_telegram() {
    local chat_id="$1"
    local text="$2"
    local token="${TELEGRAM_BOT_TOKEN:-}"

    if [ -z "$token" ]; then
        echo "ERROR: TELEGRAM_BOT_TOKEN not set" >&2
        return 1
    fi

    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -d chat_id="${chat_id}" \
        -d parse_mode="Markdown" \
        -d text="$text" > /dev/null
}

send_telegram_file() {
    local chat_id="$1"
    local file_path="$2"
    local caption="${3:-}"
    local token="${TELEGRAM_BOT_TOKEN:-}"

    if [ -z "$token" ]; then
        echo "ERROR: TELEGRAM_BOT_TOKEN not set" >&2
        return 1
    fi

    curl -s -X POST "https://api.telegram.org/bot${token}/sendDocument" \
        -F chat_id="${chat_id}" \
        -F document=@"${file_path}" \
        -F caption="${caption}" > /dev/null
}