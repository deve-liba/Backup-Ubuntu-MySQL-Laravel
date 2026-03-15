#!/bin/bash
# ==========================================================
# test_notify.sh - 通知テスト用スクリプト
# 使い方: ./test_notify.sh [config.env のパス]
# ==========================================================
set -euo pipefail

usage() {
  cat <<EOF
使い方: $(basename "$0") [config.envのパス]

  設定されている通知手段（Slack, Email, SendGrid）をテストします。
  OK（成功）と ERROR（失敗）の両方のパターンを送信します。

引数:
  [config.envのパス]   設定ファイルのパス（省略時: スクリプトの親ディレクトリの config.env）

EOF
  exit 0
}

for arg in "$@"; do case "$arg" in -h|--help) usage ;; esac; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/../config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env が見つかりません: $CONFIG_FILE"
  echo "まずは scripts/setup_env.sh で設定を作成してください。"
  exit 1
fi

source "$CONFIG_FILE"

echo "=== 通知テスト開始 ==="
echo "設定ファイル: $CONFIG_FILE"
echo "環境: ${ENVIRONMENT:-未設定}"
echo ""

# notify.sh の存在確認
NOTIFY_SH="${SCRIPT_DIR}/notify.sh"
if [[ ! -x "$NOTIFY_SH" ]]; then
  echo "ERROR: $NOTIFY_SH が見つからないか、実行権限がありません。"
  exit 1
fi

# 通知設定の確認
echo "--- 通知設定の確認 ---"
[[ -n "${WEBHOOK_URL:-}" ]] && echo "Slack/Mattermost Webhook: 設定済み" || echo "Slack/Mattermost Webhook: 未設定"
[[ -n "${NOTIFY_EMAIL:-}" ]] && echo "通知用メールアドレス: ${NOTIFY_EMAIL}" || echo "通知用メールアドレス: 未設定"
[[ -n "${SENDGRID_API_KEY:-}" ]] && echo "SendGrid API: 設定済み" || echo "SendGrid API: 未設定"
echo "----------------------"
echo ""

# 1. OK パターンのテスト
echo "[1/2] 成功通知 (OK) のテストを送信中..."
"$NOTIFY_SH" "$CONFIG_FILE" "通知テスト (成功)" "これは通知テスト用の成功メッセージです。" "OK"
echo "送信完了（各サービスの出力は notify.sh 内で抑制されています）"
echo ""

# 2. ERROR パターンのテスト
echo "[2/2] 失敗通知 (ERROR) のテストを送信中..."
"$NOTIFY_SH" "$CONFIG_FILE" "通知テスト (失敗)" "これは通知テスト用のエラーメッセージです。" "ERROR"
echo "送信完了"

echo ""
echo "=== 通知テスト完了 ==="
echo "実際に通知が届いているか、各サービスを確認してください。"
