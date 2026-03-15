#!/bin/bash
# ==========================================================
# backup_mysql.sh - MySQL バックアップスクリプト
# 使い方: ./backup_mysql.sh [-h] [config.env のパス]
# ==========================================================
set -euo pipefail

usage() {
  cat <<EOF
使い方: $(basename "$0") [オプション] [config.envのパス]

  MySQL データベースをバックアップします。
  バックアップファイルは .sql.gz 形式で保存されます。

オプション:
  -h, --help    このヘルプを表示して終了

引数:
  [config.envのパス]   設定ファイルのパス（省略時: スクリプトの親ディレクトリの config.env）

動作:
  - mysqldump --single-transaction でオンラインバックアップ
  - gzip 圧縮して保存
  - KEEP_GENERATIONS 世代を超えた古いファイルを削除
  - Slack / メール通知（設定時のみ）

例:
  $(basename "$0")
  $(basename "$0") /etc/backup/config_production.env
EOF
  exit 0
}

for arg in "$@"; do case "$arg" in -h|--help) usage ;; esac; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/../config.env}"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config.env が見つかりません: $CONFIG_FILE"; exit 1; }
source "$CONFIG_FILE"

# ---- 設定 ----
LOG_DIR="${LOG_DIR:-/var/log/backup}"
BACKUP_DIR="${BACKUP_LOCAL_DIR}/${SERVICE_NAME:-$ENVIRONMENT}/${ENVIRONMENT}/mysql"
DATE=$(date +%Y%m%d_%H%M%S)
FILENAME="${SERVICE_NAME:-$ENVIRONMENT}_${ENVIRONMENT}_mysql_${DATE}.sql.gz"
BACKUP_PATH="${BACKUP_DIR}/${FILENAME}"

# ---- ユーティリティ ----
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "${LOG_DIR}/mysql.log"
}

notify() {
  "${SCRIPT_DIR}/notify.sh" "$CONFIG_FILE" "$1" "$2" "$3"
}

on_error() {
  log "ERROR: バックアップ失敗 (終了コード: $?)"
  notify "MySQL バックアップ失敗" "MySQL backup failed on $(hostname) at $(date). Check ${LOG_DIR}/mysql_error.log for details." "ERROR"
  exit 1
}
trap on_error ERR

# ---- メイン ----
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

log "=== MySQL バックアップ開始 ==="
log "サービス名: ${SERVICE_NAME:-$ENVIRONMENT}"
log "環境    : ${ENVIRONMENT}"
log "データベース: ${DB_NAME} @ ${DB_HOST}:${DB_PORT:-3306}"
log "出力先  : ${BACKUP_PATH}"

# バックアップ実行
mysqldump \
  --host="${DB_HOST}" \
  --port="${DB_PORT:-3306}" \
  --user="${DB_USER}" \
  --password="${DB_PASS}" \
  --single-transaction \
  --routines \
  --triggers \
  --hex-blob \
  --add-drop-database \
  --comments \
  "${DB_NAME}" \
  2>"${LOG_DIR}/mysql_error.log" \
  | gzip -9 > "${BACKUP_PATH}"

# 結果確認
if [[ ! -s "${BACKUP_PATH}" ]]; then
  log "ERROR: バックアップファイルが空です"
  rm -f "${BACKUP_PATH}"
  exit 1
fi

FILESIZE=$(du -sh "${BACKUP_PATH}" | cut -f1)
log "バックアップ成功: ${FILENAME} (${FILESIZE})"
notify "MySQL バックアップ完了" "MySQL backup completed: ${FILENAME} (${FILESIZE})" "OK"

# ---- 世代管理 ----
log "世代管理: ${KEEP_GENERATIONS} 世代を保持"
ls -t "${BACKUP_DIR}/${SERVICE_NAME:-$ENVIRONMENT}_${ENVIRONMENT}_mysql_"*.sql.gz 2>/dev/null \
  | tail -n "+$((KEEP_GENERATIONS + 1))" \
  | while read -r old_file; do
      log "削除: $(basename "$old_file")"
      rm -f "$old_file"
    done

CURRENT_COUNT=$(ls -1 "${BACKUP_DIR}/${SERVICE_NAME:-$ENVIRONMENT}_${ENVIRONMENT}_mysql_"*.sql.gz 2>/dev/null | wc -l)
log "保存中のバックアップ数: ${CURRENT_COUNT}"
log "=== MySQL バックアップ完了 ==="
