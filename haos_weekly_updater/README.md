# HAOS Weekly Updater Add-on

> **AI-generated project.** Цей аддон був написаний з використанням штучного інтелекту (OpenAI Codex) як інструменту допомоги в розробці.

Автоматичне оновлення Home Assistant OS, Core, аддонів та інтеграцій (HACS) щотижня у вівторок о 8:00 ранку з повідомленням у Telegram.

## Особливості

- ✅ Оновлення аддонів (всі, що мають доступні оновлення)
- ✅ Оновлення інтеграцій через HA API (`update.*` entities, крім Core/OS/Supervisor/аддонів/прошивок)
- ✅ Оновлення HA Core
- ✅ Оновлення HAOS (з автоматичним перезавантаженням)
- ✅ Telegram-звіт: що оновлено, що не вдалося, час виконання
- ✅ Логування в `/data/update-YYYY-MM-DD.log`
- ✅ Автоочищення логів старших за 30 днів
- ✅ Cron-розклад: `0 8 * * 2` (вівторок 8:00 Kyiv — dcron ігнорує `$TZ`, тому в `run.sh` виставляється `/etc/localtime`)
- ✅ `run_on_start: true` — ручний запуск оновлення (перемикач: увімкнення → один прогін, без повторів при рестартах)
- ✅ `ha refresh-updates` перед перевіркою — актуальні версії з GitHub
- ✅ Робота в контейнері — виживає при оновленні HAOS

## Встановлення

### 1. Скопіюйте аддон на HAOS

**Варіант А: через File Editor (Samba/SSH)**
```bash
# На HAOS (через SSH або Terminal addon)
mkdir -p /addons/haos_weekly_updater
# Скопіюйте всі файли з цього репозиторію в /addons/haos_weekly_updater/
```

**Варіант Б: через git (якщо є доступ)**
```bash
cd /addons
git clone <your-repo> haos_weekly_updater
```

### 2. Додайте локальний репозиторій у HA

1. Settings → Add-ons → Add-on Store
2. ⋮ (три крапки) → Repositories
3. Додайте: `/addons` (або повний шлях до папки з аддонами)
4. Save → Refresh

### 3. Встановіть аддон

1. Знайдіть "HAOS Weekly Updater" в списку (Local add-ons)
2. Install
3. Налаштуйте Configuration (див. нижче)
4. Увімкніть: "Start on boot", "Watchdog", "Show in sidebar"
5. Start

## Конфігурація (Configuration)

```yaml
telegram_bot_token: "123456789:ABC-DEF..."    # BotFather token
telegram_chat_id: "-1001234567890"             # Chat ID (група/канал)
admin_chat_id: "-1001234567891"                # Опціонально: для алертів при помилках
timezone: "Europe/Kyiv"                        # Часовий пояс для cron
log_retention_days: 30                         # Скільки днів зберігати логи
```

**Секрети** — винесіть у `/config/secrets.yaml`:
```yaml
telegram_bot_token: "123456789:ABC-DEF..."
telegram_chat_id: "-1001234567890"
admin_chat_id: "-1001234567891"
```

І в конфігу аддона:
```yaml
telegram_bot_token: "!secret telegram_bot_token"
telegram_chat_id: "!secret telegram_chat_id"
admin_chat_id: "!secret admin_chat_id"
```

## Як отримати Chat ID

1. Напишіть боту `@userinfobot` або `@getmyid_bot`
2. Або перешліть повідомлення від групи боту `@RawDataBot`
3. Chat ID виглядає як `-1001234567890` (групи) або `123456789` (приватні чати)

## Ручний запуск

```bash
# Через HA CLI
ha addons execute haos_weekly_updater /update-script.sh

# Або зайдіть в контейнер
ha addons exec haos_weekly_updater /bin/bash
# всередині:
/update-script.sh
```

## Логи

- **HA UI**: Settings → Add-ons → HAOS Weekly Updater → Log
- **Файли**: `/data/update-YYYY-MM-DD.log` (на HAOS)
- **Автоочищення**: щодня о 03:00 видаляються логи старші за 30 днів

## Формат повідомлення в Telegram

```
🏠 **HAOS Weekly Update Report** — 2026-10-19 08:00:15

⏱ **Duration:** 00:02:34
🖥 **Host:** homeassistant

✅ **Оновлено (3):**
• Addon: mosquito-broker (5.2.1 → 5.3.0)
• Addon: file-editor (5.4.0 → 5.5.1)
• HA Core (2026.10.1 → 2026.10.2)

❌ **Проблеми (1):**
• HAOS: update failed — "insufficient disk space"

🔄 **Дія:** HAOS перезавантажено автоматично

📋 **Деталі:** `/data/update-2026-10-19.log`
```

## Архітектура

```
haos_weekly_updater/
├── config.yaml          # конфіг аддона
├── Dockerfile           # base: ghcr.io/home-assistant/amd64-base:latest
├── run.sh               # entrypoint: crond + signal handling
├── update-script.sh     # основна логіка оновлення
├── telegram.sh          # бібліотека для Telegram
└── crontab              # розклад: 0 8 * * 2 (вівторок) + daily cleanup
```

## Вирішення проблем

| Проблема | Рішення |
|----------|---------|
| "ha: command not found" | `hassio_api: true` + `hassio_role: admin` у config.yaml; `ha` додатково зсилений у `/usr/bin` (dcron дає cron-джобам мінімальний PATH) |
| "401 unauthorized" від `ha` або `/core/api` | Токен читається з `/run/s6/container_environment/SUPERVISOR_TOKEN` (CMD не успадковує env контейнера); для проксі HA API потрібен заголовок `Authorization: Bearer`, а не `X-Supervisor-Token` |
| Cron не запускається | `ha apps logs 762d1bf8_haos_weekly_updater` і шукайте `failed parsing crontab` (dcron відкидає ВЕСЬ crontab, якщо в ньому є рядок `PATH=...`); вивід cron-джобів не потрапляє у лог контейнера — дивіться `/data/update-YYYY-MM-DD.log` і Telegram-звіт |
| `ha addons list --format json` → unknown flag | У CLI 5.5.0 немає `addons list`/`--format`: використовуйте `ha available-updates --raw-json` |
| Telegram не працює | Перевірте token/chat_id, чи є інтернет у контейнері |
| Диск переповнений | Зменшіть `log_retention_days`, перевірте `/data` |

## Оновлення аддона

1. Внесіть зміни у файли
2. Збільште `version` у `config.yaml`
3. Перезапустіть аддон (HA зробить rebuild)

## Ліцензія

MIT — вільно використовуйте та модифікуйте.