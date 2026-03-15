#!/bin/bash
# ==========================================================
# test_restore.sh - テストDBへのリストアリハーサル
# 使い方: ./test_restore.sh [config.envのパス]
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/../config.env}"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config.env が見つかりません: $CONFIG_FILE"; exit 1; }
source "$CONFIG_FILE"

# ---- 設定 ----
LOG_DIR="${LOG_DIR:-/var/log/backup}"
BACKUP_DIR="${BACKUP_LOCAL_DIR}/${SERVICE_NAME:-$ENVIRONMENT}/${ENVIRONMENT}/mysql"
TEST_DB="${TEST_DB_NAME:-}"

# テストDB用の接続情報（未設定の場合は本番用をフォールバックとして使用）
TEST_HOST="${TEST_DB_HOST:-$DB_HOST}"
TEST_PORT="${TEST_DB_PORT:-${DB_PORT:-3306}}"
TEST_USER="${TEST_DB_USER:-$DB_USER}"
TEST_PASS="${TEST_DB_PASS:-$DB_PASS}"

# テストDBが設定されていない場合は終了
if [[ -z "$TEST_DB" ]]; then
  echo "INFO: TEST_DB_NAME が未設定のため、テストリストアをスキップします。"
  exit 0
fi

# ---- ユーティリティ ----
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "${LOG_DIR}/test_restore.log"
}

notify() {
  "${SCRIPT_DIR}/notify.sh" "$CONFIG_FILE" "$1" "$2" "$3"
}

on_error() {
  local exit_code=$?
  log "ERROR: テストリストア失敗 (終了コード: $exit_code)"
  notify "テストリストア失敗" "テスト用DB (${TEST_DB}) へのリストア中にエラーが発生しました。ログを確認してください: ${LOG_DIR}/test_restore.log" "ERROR"
  unset MYSQL_PWD
  exit $exit_code
}
trap on_error ERR

# ---- メイン ----
log "=== テストリストア開始 ==="

# 最新のバックアップファイルを取得
LATEST_BACKUP=$(ls -t "${BACKUP_DIR}/${SERVICE_NAME:-$ENVIRONMENT}_${ENVIRONMENT}_mysql_"*.sql.gz 2>/dev/null | head -n 1 || true)

if [[ -z "$LATEST_BACKUP" ]]; then
  log "ERROR: バックアップファイルが見つかりません"
  notify "テストリストア失敗" "バックアップファイルが見つからないため、テストリストアをスキップしました。" "ERROR"
  exit 1
fi

log "使用するバックアップ: $(basename "$LATEST_BACKUP")"

# テストDBのクリアと作成
log "テストDBの再作成: ${TEST_DB}"
export MYSQL_PWD="${TEST_PASS}"
mysql -h "${TEST_HOST}" -P "${TEST_PORT}" -u "${TEST_USER}" \
  -e "DROP DATABASE IF EXISTS \`${TEST_DB}\`; CREATE DATABASE \`${TEST_DB}\`;"

# リストア実行
log "リストア実行中..."
gunzip -c "${LATEST_BACKUP}" | mysql -h "${TEST_HOST}" -P "${TEST_PORT}" -u "${TEST_USER}" "${TEST_DB}"

# 簡単な検証（テーブルが存在するか）
TABLE_COUNT=$(mysql -h "${TEST_HOST}" -P "${TEST_PORT}" -u "${TEST_USER}" -D "${TEST_DB}" -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${TEST_DB}';")

if [[ "$TABLE_COUNT" -gt 0 ]]; then
  log "テストリストア成功: ${TABLE_COUNT} 個のテーブルを確認しました"
  # 成功時はあえて通知しない（うるさいため）、または成功ログのみ
else
  log "ERROR: リストアされましたがテーブルが見つかりません"
  notify "テストリストア失敗" "リストアは完了しましたが、テスト用DB (${TEST_DB}) 内にテーブルが見つかりません。" "ERROR"
  unset MYSQL_PWD
  exit 1
fi

unset MYSQL_PWD
log "=== テストリストア完了 ==="
