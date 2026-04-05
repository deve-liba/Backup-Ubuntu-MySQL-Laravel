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
  - aws s3 sync でローカル → クラウドへ同期

対応バックエンド: s3, wasabi, sakura, idrive

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
  notify "クラウド同期失敗" "Cloud sync failed on $(hostname) at $(date). Check ${LOG_DIR}/sync.log for details." "ERROR"
  exit 1
}
trap on_error ERR

# ---- AWS 認証設定 ----
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
[[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION

# ---- ローカルのみの場合はスキップ ----
if [[ "${STORAGE_BACKEND:-local}" == "local" ]]; then
  log "STORAGE_BACKEND=local のためクラウド同期をスキップします"
  exit 0
fi

command -v aws &>/dev/null || { log "ERROR: aws-cli がインストールされていません"; exit 1; }

mkdir -p "$LOG_DIR"

# ---- リモートパス構築 ----
# S3 互換ストレージの場合はエンドポイントを指定
S3_OPTS=()
if [[ -n "${S3_ENDPOINT_URL:-}" ]]; then
  S3_OPTS+=("--endpoint-url" "${S3_ENDPOINT_URL}")
fi

REMOTE_PATH="s3://${STORAGE_BUCKET}/${STORAGE_PREFIX}/${SERVICE_NAME:-$ENVIRONMENT}/${ENVIRONMENT}"

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

# ---- aws s3 sync 実行 ----
# クラウド側をローカルと完全一致に保つ（--delete）
log "aws s3 sync を使用（ローカルとクラウドを同期）"

aws s3 sync "${LOCAL_DIR}" "${REMOTE_PATH}" \
  ${S3_OPTS+"${S3_OPTS[@]}"} \
  --delete \
  >> "${LOG_DIR}/sync.log" 2>&1

# ---- 結果確認 ----
# aws s3 ls で確認
REMOTE_COUNT=$(aws s3 ls "${REMOTE_PATH}/" ${S3_OPTS+"${S3_OPTS[@]}"} --recursive 2>/dev/null | grep ".gz$" | wc -l || echo "0")
REMOTE_SIZE=$(aws s3 ls "${REMOTE_PATH}/" ${S3_OPTS+"${S3_OPTS[@]}"} --recursive --human-readable --summarize 2>/dev/null \
  | grep "Total Size:" | cut -d: -f2- | sed 's/^[[:space:]]*//' || echo "不明")

log "同期完了: リモートファイル数 ${REMOTE_COUNT}, 合計サイズ ${REMOTE_SIZE}"
# 成功時の通知は任意。通常は静かに。
# notify "クラウド同期完了" "Cloud sync completed (${STORAGE_BACKEND}). Remote files: ${REMOTE_COUNT} (${REMOTE_SIZE})" "OK"

log "=== クラウド同期完了 ==="
