#!/bin/bash
# ==========================================================
# setup.sh - バックアップシステム セットアップスクリプト
# ==========================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}--- $1 ---${NC}"; }

usage() {
  cat <<EOF
使い方: $(basename "$0") [オプション] [config.envのパス]

  バックアップシステムのセットアップを行います。
  依存パッケージの確認、rcloneリモートの設定、Cronジョブの登録を一括で実行します。

オプション:
  -h, --help    このヘルプを表示して終了

引数:
  [config.envのパス]   設定ファイルのパス（省略時: ./config.env）

例:
  $(basename "$0")                              # ./config.env を使用
  $(basename "$0") /path/to/config.env          # 設定ファイルを指定
  $(basename "$0") /path/to/config_staging.env  # staging環境をセットアップ

対応ストレージバックエンド:
  b2, wasabi, s3, sakura, gdrive, gworkspace, azure, gcs, idrive, local
EOF
  exit 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# オプション解析
for arg in "$@"; do
  case "$arg" in -h|--help) usage ;; esac
done

CONFIG_FILE="${1:-${SCRIPT_DIR}/config.env}"

# ---- 設定ファイルチェック ----
if [[ ! -f "$CONFIG_FILE" ]]; then
  if [[ -f "${SCRIPT_DIR}/scripts/setup_env.sh" ]]; then
    warn "config.env が見つかりません。対話型設定スクリプトを開始します。"
    bash "${SCRIPT_DIR}/scripts/setup_env.sh"
    # setup_env.sh が成功したかチェック
    if [[ ! -f "$CONFIG_FILE" ]]; then
      error "config.env の作成に失敗したか、中断されました。"
    fi
    source "$CONFIG_FILE"
  elif [[ -f "${SCRIPT_DIR}/config.env.example" ]]; then
    warn "config.env が見つかりません。config.env.example をコピーします。"
    cp "${SCRIPT_DIR}/config.env.example" "$CONFIG_FILE"
    warn "config.env を編集してから再度実行してください。"
    warn "  vi ${CONFIG_FILE}"
    exit 1
  else
    error "config.env が見つかりません: $CONFIG_FILE"
  fi
fi

source "$CONFIG_FILE"

# ---- 設定ファイルのパーミッションチェック ----
step "設定ファイルセキュリティチェック"
if [[ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "000")" != "600" ]]; then
  warn "$CONFIG_FILE のパーミッションが 600 ではありません（推奨: 600）"
  warn "機密情報（パスワード等）が含まれているため、パーミッションの変更を推奨します。"
  read -p "パーミッションを 600 に変更しますか？ (y/n): " confirm
  if [[ "$confirm" == "y" ]]; then
    chmod 600 "$CONFIG_FILE"
    info "パーミッションを 600 に変更しました。"
  fi
else
  info "設定ファイルのパーミッション: 600 (OK)"
fi

echo -e "\n${BOLD}========================================${NC}"
echo -e "${BOLD} バックアップシステム セットアップ${NC}"
echo -e "${BOLD}========================================${NC}"
info "環境: ${ENVIRONMENT}"
info "サービス: ${SERVICE_NAME:-$ENVIRONMENT}"
info "設定: ${CONFIG_FILE}"

# ---- 依存関係チェック＆インストール ----
step "依存関係チェック"

install_pkg() {
  if command -v apt-get &>/dev/null; then
    apt-get install -y "$1" &>/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y "$1" &>/dev/null
  else
    warn "パッケージマネージャが見つかりません。手動でインストールしてください: $1"
  fi
}

check_cmd() {
  local cmd="$1"; local pkg="${2:-$1}"
  if command -v "$cmd" &>/dev/null; then
    info "$cmd: OK ($(command -v "$cmd"))"
  else
    warn "$cmd が見つかりません。インストールを試みます..."
    install_pkg "$pkg"
    command -v "$cmd" &>/dev/null && info "$cmd: インストール済み" || warn "$cmd のインストールに失敗しました"
  fi
}

check_cmd mysqldump mysql-client
check_cmd gzip gzip
check_cmd tar tar
check_cmd curl curl

# rclone（localバックエンド以外で必要）
if [[ "${STORAGE_BACKEND:-local}" != "local" ]]; then
  if command -v rclone &>/dev/null; then
    info "rclone: OK ($(rclone version | head -1))"
  else
    info "rclone をインストールしています..."
    curl https://rclone.org/install.sh | bash
    command -v rclone &>/dev/null && info "rclone: インストール済み" || error "rclone のインストールに失敗しました"
  fi
fi

# ---- ディレクトリ作成 ----
step "ディレクトリ作成"

mkdir -p "${BACKUP_LOCAL_DIR}/${ENVIRONMENT}/mysql"
mkdir -p "${BACKUP_LOCAL_DIR}/${ENVIRONMENT}/files"
mkdir -p "${LOG_DIR:-/var/log/backup}"

# 権限設定（バックアップディレクトリを保護）
chmod 700 "${BACKUP_LOCAL_DIR}" 2>/dev/null || true
chmod 700 "${LOG_DIR:-/var/log/backup}" 2>/dev/null || true

info "バックアップディレクトリ: ${BACKUP_LOCAL_DIR}/${ENVIRONMENT}/"
info "ログディレクトリ: ${LOG_DIR:-/var/log/backup}/"

# ---- スクリプトの実行権限 ----
step "スクリプト権限設定"
chmod +x "${SCRIPT_DIR}/scripts/"*.sh
info "scripts/*.sh に実行権限を付与しました"

# ---- rclone リモート設定 ----
if [[ "${STORAGE_BACKEND:-local}" != "local" ]]; then
  step "rclone リモート設定 (${STORAGE_BACKEND})"

  case "$STORAGE_BACKEND" in
    b2)
      info "Backblaze B2 リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" b2 \
        account "${B2_KEY_ID}" \
        key "${B2_APP_KEY}" || warn "rclone設定に失敗しました。手動で設定してください: rclone config"
      ;;
    wasabi)
      info "Wasabi リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" s3 \
        provider Wasabi \
        access_key_id "${AWS_ACCESS_KEY_ID}" \
        secret_access_key "${AWS_SECRET_ACCESS_KEY}" \
        endpoint "s3.${AWS_REGION}.wasabisys.com" \
        region "${AWS_REGION}" || warn "rclone設定に失敗しました"
      ;;
    s3)
      info "AWS S3 リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" s3 \
        provider AWS \
        access_key_id "${AWS_ACCESS_KEY_ID}" \
        secret_access_key "${AWS_SECRET_ACCESS_KEY}" \
        region "${AWS_REGION}" || warn "rclone設定に失敗しました"
      ;;
    sakura)
      info "さくらオブジェクトストレージ リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" s3 \
        provider Other \
        access_key_id "${AWS_ACCESS_KEY_ID}" \
        secret_access_key "${AWS_SECRET_ACCESS_KEY}" \
        endpoint "${SAKURA_ENDPOINT:-https://s3.isk01.sakurastorage.jp}" \
        force_path_style true || warn "rclone設定に失敗しました"
      ;;
    gdrive)
      info "Google Drive リモートを設定します（ブラウザ認証が必要です）"
      rclone config create "${STORAGE_REMOTE_NAME}" drive || warn "rclone設定に失敗しました"
      ;;
    gworkspace)
      info "Google Workspace (共有ドライブ) リモートを設定します（ブラウザ認証が必要です）"
      if [[ -n "${GWORKSPACE_DRIVE_ID:-}" ]]; then
        rclone config create "${STORAGE_REMOTE_NAME}" drive \
          team_drive "${GWORKSPACE_DRIVE_ID}" || warn "rclone設定に失敗しました"
      else
        rclone config create "${STORAGE_REMOTE_NAME}" drive || warn "rclone設定に失敗しました"
        warn "GWORKSPACE_DRIVE_ID が未設定です。共有ドライブIDをconfig.envに設定してください。"
      fi
      ;;
    azure)
      info "Azure Blob Storage リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" azureblob \
        account "${AZURE_ACCOUNT}" \
        key "${AZURE_KEY}" || warn "rclone設定に失敗しました"
      ;;
    gcs)
      info "Google Cloud Storage リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" "google cloud storage" \
        service_account_file "${GCS_SERVICE_ACCOUNT_JSON}" || warn "rclone設定に失敗しました"
      ;;
    idrive)
      info "IDrive e2 リモートを設定します: ${STORAGE_REMOTE_NAME}"
      rclone config create "${STORAGE_REMOTE_NAME}" s3 \
        provider IDrive \
        access_key_id "${IDRIVE_ACCESS_KEY:-}" \
        secret_access_key "${IDRIVE_SECRET_KEY:-}" \
        endpoint "${IDRIVE_ENDPOINT:-}" || warn "rclone設定に失敗しました"
      ;;
    *)
      warn "未対応のストレージバックエンド: ${STORAGE_BACKEND}"
      ;;
  esac

  # 接続テスト
  info "ストレージ接続テスト..."
  if rclone ls "${STORAGE_REMOTE_NAME}:${STORAGE_BUCKET}/" &>/dev/null; then
    info "接続テスト: OK"
  else
    warn "接続テストに失敗しました。設定を確認してください。"
    warn "  rclone ls ${STORAGE_REMOTE_NAME}:${STORAGE_BUCKET}/"
  fi
fi

# ---- MySQL バックアップユーザー案内 ----
step "MySQL バックアップユーザー設定"
info "以下のSQLをMySQLで実行してバックアップ専用ユーザーを作成してください:"
echo ""
echo "  CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
echo "  GRANT SELECT, RELOAD, LOCK TABLES, REPLICATION CLIENT, SHOW VIEW, EVENT, TRIGGER ON *.* TO '${DB_USER}'@'localhost';"
if [[ -n "${TEST_DB_NAME:-}" ]]; then
  echo "  GRANT ALL PRIVILEGES ON \`${TEST_DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
fi
echo "  FLUSH PRIVILEGES;"
echo ""

# バイナリログチェック
BIN_LOG=$(mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_USER}" -p"${DB_PASS}" \
  -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | grep -i "log_bin" | awk '{print $2}' || echo "UNKNOWN")

if [[ "$BIN_LOG" == "ON" ]]; then
  info "バイナリログ: 有効（PITRが利用可能）"
else
  warn "バイナリログが無効です。PITRを有効にするには mysqld.cnf に以下を追記してください:"
  echo "  log_bin = /var/log/mysql/mysql-bin.log"
  echo "  expire_logs_days = 7"
  echo "  binlog_format = ROW"
fi

# ---- Cron 設定 ----
step "Cron ジョブ設定"

CRON_FILE="/etc/cron.d/backup-${SERVICE_NAME:-$ENVIRONMENT}-${ENVIRONMENT}"
cat > "${CRON_FILE}" <<EOF
# Auto-generated by setup.sh: Backup cron for ${SERVICE_NAME:-$ENVIRONMENT} (${ENVIRONMENT})
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# MySQL バックアップ
${CRON_MYSQL} root ${SCRIPT_DIR}/scripts/backup_mysql.sh ${CONFIG_FILE} >> ${LOG_DIR:-/var/log/backup}/mysql.log 2>&1

# ファイル バックアップ
${CRON_FILES} root ${SCRIPT_DIR}/scripts/backup_files.sh ${CONFIG_FILE} >> ${LOG_DIR:-/var/log/backup}/files.log 2>&1

# クラウド 同期
${CRON_SYNC} root ${SCRIPT_DIR}/scripts/backup_sync.sh ${CONFIG_FILE} >> ${LOG_DIR:-/var/log/backup}/sync.log 2>&1

# テストDB リストアチェック
${CRON_TEST_RESTORE:-0 5 * * *} root ${SCRIPT_DIR}/scripts/test_restore.sh ${CONFIG_FILE} >> ${LOG_DIR:-/var/log/backup}/test_restore.log 2>&1
EOF

chmod 644 "${CRON_FILE}"
info "Cron 設定: ${CRON_FILE}"
info "  MySQL  : ${CRON_MYSQL}"
info "  Files  : ${CRON_FILES}"
info "  Sync   : ${CRON_SYNC}"
if [[ -n "${TEST_DB_NAME:-}" ]]; then
  info "  Test   : ${CRON_TEST_RESTORE:-0 5 * * *} (Target: ${TEST_DB_NAME})"
fi

# ---- Logrotate 設定 ----
step "Logrotate 設定"

LOGROTATE_FILE="/etc/logrotate.d/backup-${SERVICE_NAME:-$ENVIRONMENT}-${ENVIRONMENT}"
if [[ -d "/etc/logrotate.d" ]]; then
  cat > "${LOGROTATE_FILE}" <<EOF
${LOG_DIR:-/var/log/backup}/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 root root
}
EOF
  chmod 644 "${LOGROTATE_FILE}"
  info "Logrotate 設定: ${LOGROTATE_FILE}"
else
  warn "/etc/logrotate.d が見つからないため、Logrotate の設定をスキップしました。"
fi

# ---- サービス側世代管理の案内 ----
if [[ "${USE_SERVICE_VERSIONING:-false}" == "true" ]]; then
  step "サービス側世代管理 (有効)"
  if [[ "${STORAGE_BACKEND:-}" == "gdrive" || "${STORAGE_BACKEND:-}" == "gworkspace" ]]; then
    info "Google Drive/Workspace のバージョン履歴を利用します。"
    info "ローカル・クラウドの世代自動削除はスキップされます。"
    warn "Drive側の保持世代数はGoogle側の設定（100バージョンまで）に依存します。"
    warn "Drive容量を超えた場合、古いバージョンは自動削除されます。容量に注意してください。"
  fi
else
  if [[ "${STORAGE_BACKEND:-}" == "gdrive" || "${STORAGE_BACKEND:-}" == "gworkspace" ]]; then
    info "USE_SERVICE_VERSIONING=false のため、スクリプト側で世代管理を行います。"
    info "サービス側のバージョン履歴を使う場合は config.env で USE_SERVICE_VERSIONING=true に設定してください。"
  fi
fi

# ---- 完了メッセージ ----
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN}  セットアップ完了${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
info "手動テスト:"
echo "  ${SCRIPT_DIR}/scripts/backup_mysql.sh ${CONFIG_FILE}"
echo "  ${SCRIPT_DIR}/scripts/backup_files.sh ${CONFIG_FILE}"
echo "  ${SCRIPT_DIR}/scripts/backup_sync.sh ${CONFIG_FILE}"
echo ""
info "リストア（インタラクティブ）:"
echo "  ${SCRIPT_DIR}/scripts/restore.sh ${CONFIG_FILE}"
echo ""
info "バックアップ一覧:"
echo "  ${SCRIPT_DIR}/scripts/restore.sh ${CONFIG_FILE} list"
echo "  ${SCRIPT_DIR}/scripts/restore.sh ${CONFIG_FILE} list --type mysql"
echo "  ${SCRIPT_DIR}/scripts/restore.sh ${CONFIG_FILE} list --date 2026-03-15"
