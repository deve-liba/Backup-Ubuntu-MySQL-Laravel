#!/bin/bash
# ==========================================================
# backup_files.sh - ファイルバックアップスクリプト
# 対象: Laravelストレージ / .env / サーバー設定ファイル
# 使い方: ./backup_files.sh [-h] [config.env のパス]
# ==========================================================
set -euo pipefail

usage() {
  cat <<EOF
使い方: $(basename "$0") [オプション] [config.envのパス]

  Laravelのストレージ・設定ファイル等をバックアップします。

オプション:
  -h, --help    このヘルプを表示して終了

引数:
  [config.envのパス]   設定ファイルのパス（省略時: スクリプトの親ディレクトリの config.env）

バックアップ対象（config.envで制御）:
  storage/app/   Laravelアップロードファイル等
  .env           Laravel環境設定ファイル
  CONFIG_BACKUP_DIRS  サーバー設定（nginx, php等）
  EXTRA_BACKUP_DIRS   追加の任意ディレクトリ

動作:
  - 対象ごとに個別のtar.gzファイルを作成
  - vendor/ や キャッシュ類は除外
  - KEEP_GENERATIONS 世代を超えた古いファイルを削除

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
BACKUP_DIR="${BACKUP_LOCAL_DIR}/${SERVICE_NAME:-$ENVIRONMENT}/${ENVIRONMENT}/files"
DATE=$(date +%Y%m%d_%H%M%S)
HAS_ERROR=false

# ---- ユーティリティ ----
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "${LOG_DIR}/files.log"
}

log_error() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
  echo "$msg" >&2
  echo "$msg" >> "${LOG_DIR}/files.log"
  HAS_ERROR=true
}

notify() {
  "${SCRIPT_DIR}/notify.sh" "$CONFIG_FILE" "$1" "$2" "$3"
}

# 単一ディレクトリ/ファイルをバックアップ
backup_target() {
  local type="$1"       # タイプ識別子（ファイル名に使用）
  local source="$2"     # バックアップ元パス
  local exclude="${3:-}" # 除外パターン（tarの--excludeに渡す）

  if [[ ! -e "$source" ]]; then
    log "スキップ（存在しません）: $source"
    return 0
  fi

  local FILENAME="${SERVICE_NAME:-$ENVIRONMENT}_${ENVIRONMENT}_${type}_${DATE}.tar.gz"
  local BACKUP_PATH="${BACKUP_DIR}/${FILENAME}"

  log "バックアップ: $source → $FILENAME"

  local exclude_opts=()
  if [[ -n "$exclude" ]]; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] && exclude_opts+=("--exclude=${pattern}")
    done <<< "$exclude"
  fi

  # 元のディレクトリに移動して相対パスで固める
  local source_dir
  local source_name
  source_dir=$(dirname "$source")
  source_name=$(basename "$source")

  if tar czf "$BACKUP_PATH" ${exclude_opts+"${exclude_opts[@]}"} -C "$source_dir" "$source_name" 2>"${LOG_DIR}/files_error.log"; then
    if [[ -s "$BACKUP_PATH" ]]; then
      local size
      size=$(du -sh "$BACKUP_PATH" | cut -f1)
      log "  → 完了 (${size})"
    else
      log_error "バックアップファイルが空です: $FILENAME"
      rm -f "$BACKUP_PATH"
      return 1
    fi
  else
    log_error "tar 失敗: $source"
    rm -f "$BACKUP_PATH"
    return 1
  fi

  # 世代管理
  ls -t "${BACKUP_DIR}/${SERVICE_NAME:-$ENVIRONMENT}_${ENVIRONMENT}_${type}_"*.tar.gz 2>/dev/null \
    | tail -n "+$((KEEP_GENERATIONS + 1))" \
    | while read -r old_file; do
        log "  削除: $(basename "$old_file")"
        rm -f "$old_file"
      done
}

# ---- メイン ----
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

log "=== ファイルバックアップ開始 ==="
log "サービス名: ${SERVICE_NAME:-$ENVIRONMENT}"
log "環境: ${ENVIRONMENT}"

# 1. Laravelストレージ (storage/app)
# キャッシュ/セッション/ビューキャッシュは除外
# 除外パターンは -C 後の相対パスで指定する必要がある
backup_target "storage" "${APP_DIR}/storage/app" \
  "framework/cache
framework/sessions
framework/views
logs"

# 2. .env ファイル
backup_target "env" "${APP_DIR}/.env"

# 3. サーバー設定ディレクトリ
for conf_dir in ${CONFIG_BACKUP_DIRS:-}; do
  if [[ -n "$conf_dir" && -d "$conf_dir" ]]; then
    # ディレクトリパスをアンダースコアに変換してタイプ名に使用
    type_name="config_$(echo "$conf_dir" | tr '/' '_' | sed 's/^_//')"
    backup_target "$type_name" "$conf_dir"
  fi
done

# 4. 追加ディレクトリ
for extra_dir in ${EXTRA_BACKUP_DIRS:-}; do
  if [[ -n "$extra_dir" && -d "$extra_dir" ]]; then
    type_name="extra_$(basename "$extra_dir")"
    backup_target "$type_name" "$extra_dir"
  fi
done

# ---- 結果通知 ----
if $HAS_ERROR; then
  log "=== ファイルバックアップ完了（エラーあり） ==="
  notify "ファイルバックアップ警告" "一部のファイルバックアップに失敗しました。詳細は ${LOG_DIR}/files.log を確認してください。" "ERROR"
  exit 1
else
  log "=== ファイルバックアップ完了 ==="
  # 成功時は通知しないか、必要なら追加
fi
