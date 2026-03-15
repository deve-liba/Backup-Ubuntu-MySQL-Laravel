#!/bin/bash
# ==========================================================
# backup_sync.sh - クラウドストレージ同期スクリプト
# ローカルバックアップを設定されたクラウドストレージに同期
# 使い方: ./backup_sync.sh [-h] [config.env のパス]
# ==========================================================
set -euo pipefail

usage() {
  cat <<EOF
使い方: $(basename "$0") [オプション] [config.envのパス]

  ローカルのバックアップファイルをクラウドストレージへ同期します。
  STORAGE_BACKEND=local の場合はスキップされます。

オプション:
  -h, --help    このヘルプを表示して終了

引数:
  [config.envのパス]   設定ファイルのパス（省略時: スクリプトの親ディレクトリの config.env）

動作:
  - rclone sync でローカル → クラウドへ同期
  - USE_SERVICE_VERSIONING=true の場合（gdrive/gworkspace）:
      rclone copy を使用（同期元で削除されてもクラウド側は削除しない）
  - USE_SERVICE_VERSIONING=false: rclone sync（クラウド側もローカルと同一に保つ）

対応バックエンド: b2, wasabi, s3, sakura, gdrive, gworkspace, azure, gcs, idrive

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
LOCAL_DIR="${BACKUP_LOCAL_DIR}/${SERVICE_NAME:-$ENVIRONMENT}/${ENVIRONMENT}"

# ---- ユーティリティ ----
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "${LOG_DIR}/sync.log"
}

notify() {
  "${SCRIPT_DIR}/notify.sh" "$CONFIG_FILE" "$1" "$2" "$3"
}

on_error() {
  log "ERROR: クラウド同期失敗 (終了コード: $?)"
  notify "クラウド同期失敗" "Cloud sync failed on $(hostname) at $(date). Check ${LOG_DIR}/rclone.log for details." "ERROR"
  exit 1
}
trap on_error ERR

# ---- ローカルのみの場合はスキップ ----
if [[ "${STORAGE_BACKEND:-local}" == "local" ]]; then
  log "STORAGE_BACKEND=local のためクラウド同期をスキップします"
  exit 0
fi

command -v rclone &>/dev/null || { log "ERROR: rclone がインストールされていません"; exit 1; }

mkdir -p "$LOG_DIR"

# ---- リモートパス構築 ----
REMOTE_PATH="${STORAGE_REMOTE_NAME}:${STORAGE_BUCKET}/${STORAGE_PREFIX}/${SERVICE_NAME:-$ENVIRONMENT}/${ENVIRONMENT}"

log "=== クラウド同期開始 ==="
log "サービス名: ${SERVICE_NAME:-$ENVIRONMENT}"
log "環境     : ${ENVIRONMENT}"
log "バックエンド: ${STORAGE_BACKEND}"
log "ローカル  : ${LOCAL_DIR}"
log "リモート  : ${REMOTE_PATH}"

# ---- ローカルのファイル数確認 ----
# find を使用して .gz ファイルの数を確認（ディレクトリの深さ制限なし）
LOCAL_COUNT=$(find "${LOCAL_DIR}" -name "*.gz" -type f 2>/dev/null | wc -l)
log "ローカルファイル数: ${LOCAL_COUNT}"

if [[ $LOCAL_COUNT -eq 0 ]]; then
  log "同期対象ファイルがありません"
  exit 0
fi

# ---- rclone 同期実行 ----
# USE_SERVICE_VERSIONING=true かつ gdrive/gworkspace の場合:
#   rclone copy を使用（ローカルで削除されてもクラウド側は削除せず、Drive側のバージョン履歴に委ねる）
# それ以外:
#   rclone sync（クラウド側をローカルと完全一致に保つ）
# 削除を伴う同期の場合は --delete-before を推奨（容量節約のため）

USE_SVC_VER="${USE_SERVICE_VERSIONING:-false}"
BACKEND="${STORAGE_BACKEND:-local}"

RCLONE_EXTRA_OPTS=()
if [[ "$USE_SVC_VER" == "true" && ( "$BACKEND" == "gdrive" || "$BACKEND" == "gworkspace" ) ]]; then
  log "USE_SERVICE_VERSIONING=true: rclone copy を使用（Drive側のバージョン履歴を保持）"
  RCLONE_CMD="copy"
else
  log "rclone sync を使用（ローカルとクラウドを同期）"
  RCLONE_CMD="sync"
  RCLONE_EXTRA_OPTS+=("--delete-before")
fi

rclone "${RCLONE_CMD}" "${LOCAL_DIR}" "${REMOTE_PATH}" \
  "${RCLONE_EXTRA_OPTS[@]}" \
  --transfers 4 \
  --checkers 8 \
  --retries 3 \
  --low-level-retries 10 \
  --stats 0 \
  --log-file "${LOG_DIR}/rclone.log" \
  --log-level INFO

# ---- 結果確認 ----
REMOTE_COUNT=$(rclone ls "${REMOTE_PATH}" 2>/dev/null | wc -l || echo "0")
REMOTE_SIZE=$(rclone size "${REMOTE_PATH}" 2>/dev/null \
  | grep "Total size:" | awk '{print $3, $4}' 2>/dev/null || echo "不明")

log "同期完了: リモートファイル数 ${REMOTE_COUNT}, 合計サイズ ${REMOTE_SIZE}"
# 成功時の通知は任意。通常は静かに。
# notify "クラウド同期完了" "Cloud sync completed (${STORAGE_BACKEND}). Remote files: ${REMOTE_COUNT} (${REMOTE_SIZE})" "OK"

log "=== クラウド同期完了 ==="
