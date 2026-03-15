#!/bin/bash
# ==========================================================
# notify.sh - 通知共通スクリプト
# 使い方: ./notify.sh [config.envのパス] [タイトル] [メッセージ] [状態: OK|ERROR]
# ==========================================================
set -euo pipefail

CONFIG_FILE="${1:-}"
TITLE="${2:-通知}"
MESSAGE="${3:-内容なし}"
STATUS="${4:-OK}"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "WARN: 設定ファイルが見つかりません: $CONFIG_FILE"
fi

ENVIRONMENT="${ENVIRONMENT:-unknown}"
HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# ---- Slack / Mattermost (Webhook) ----
notify_webhook() {
  [[ -z "${WEBHOOK_URL:-}" ]] && return
  local url="${WEBHOOK_URL:-}"
  local color="good"
  local emoji="✅"
  if [[ "$STATUS" == "ERROR" ]]; then
    color="danger"
    emoji="❌"
  fi

  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "fallback": "${emoji} [${ENVIRONMENT}] ${TITLE}",
      "color": "${color}",
      "pretext": "${emoji} *[${ENVIRONMENT}] ${TITLE}*",
      "fields": [
        { "title": "Status", "value": "${STATUS}", "short": true },
        { "title": "Host", "value": "${HOSTNAME}", "short": true },
        { "title": "Time", "value": "${DATE}", "short": false },
        { "title": "Message", "value": "${MESSAGE}", "short": false }
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$url" > /dev/null || true
}

# ---- Standard Email (mail command) ----
notify_email() {
  [[ -z "${NOTIFY_EMAIL:-}" ]] && return
  # SendGrid が設定されている場合はスキップ（二重通知防止）
  [[ -n "${SENDGRID_API_KEY:-}" ]] && return
  
  command -v mail &>/dev/null || return
  
  local full_msg
  full_msg=$(cat <<EOF
[${STATUS}] ${TITLE}
-------------------------
Environment: ${ENVIRONMENT}
Host: ${HOSTNAME}
Date: ${DATE}

Message:
${MESSAGE}
EOF
)
  echo "$full_msg" | mail -s "[${STATUS}] [${ENVIRONMENT}] ${TITLE}" "${NOTIFY_EMAIL}" || true
}

# ---- SendGrid API ----
notify_sendgrid() {
  [[ -z "${SENDGRID_API_KEY:-}" ]] && return
  [[ -z "${SENDGRID_FROM_EMAIL:-}" ]] && return
  [[ -z "${NOTIFY_EMAIL:-}" ]] && return

  local subject="[${STATUS}] [${ENVIRONMENT}] ${TITLE}"
  local body
  body=$(cat <<EOF
[${STATUS}] ${TITLE}<br>
-------------------------<br>
Environment: ${ENVIRONMENT}<br>
Host: ${HOSTNAME}<br>
Date: ${DATE}<br>
<br>
Message:<br>
${MESSAGE}
EOF
)

  curl -s -X POST \
    --url https://api.sendgrid.com/v3/mail/send \
    --header "Authorization: Bearer ${SENDGRID_API_KEY}" \
    --header 'Content-Type: application/json' \
    --data "{
      \"personalizations\": [{\"to\": [{\"email\": \"${NOTIFY_EMAIL}\"}]}],
      \"from\": {\"email\": \"${SENDGRID_FROM_EMAIL}\"},
      \"subject\": \"${subject}\",
      \"content\": [{\"type\": \"text/html\", \"value\": \"${body}\"}]
    }" > /dev/null || true
}

# 実行
notify_webhook
notify_sendgrid
notify_email
