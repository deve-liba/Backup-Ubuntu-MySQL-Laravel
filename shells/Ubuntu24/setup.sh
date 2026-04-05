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
  依存パッケージの確認、AWS CLIの設定、Cronジョブの登録を一括で実行します。

オプション:
  -h, --help    このヘルプを表示して終了

引数:
  [config.envのパス]   設定ファイルのパス（省略時: ./config.env）

例:
  $(basename "$0")                              # ./config.env を使用
  $(basename "$0") /path/to/config.env          # 設定ファイルを指定
  $(basename "$0") /path/to/config_staging.env  # staging環境をセットアップ

対応ストレージバックエンド:
  s3, wasabi, sakura, idrive, local
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
  # 完了時に案内するためにフラグを立てる
  SET_CHMOD_600=true
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
  local pkg="$1"
  if command -v apt-get &>/dev/null; then
    info "apt-get で $pkg をインストールしています..."
    apt-get update &>/dev/null || true
    if command -v sudo &>/dev/null && [[ $EUID -ne 0 ]]; then
      sudo apt-get install -y "$pkg" || true
    else
      apt-get install -y "$pkg" || true
    fi
  elif command -v yum &>/dev/null; then
    info "yum で $pkg をインストールしています..."
    if command -v sudo &>/dev/null && [[ $EUID -ne 0 ]]; then
      sudo yum install -y "$pkg" || true
    else
      yum install -y "$pkg" || true
    fi
  elif command -v apk &>/dev/null; then
    info "apk で $pkg をインストールしています..."
    if command -v sudo &>/dev/null && [[ $EUID -ne 0 ]]; then
      sudo apk add --no-cache "$pkg" || true
    else
      apk add --no-cache "$pkg" || true
    fi
  else
    warn "パッケージマネージャが見つかりません。手動でインストールしてください: $pkg"
  fi
}

check_cmd() {
  local cmd="$1"; shift
  local pkgs=()
  local is_critical="false"

  # 残りの引数を解析
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "true" || "$1" == "false" ]]; then
      is_critical="$1"
    else
      pkgs+=("$1")
    fi
    shift
  done

  # パッケージ名が指定されていない場合はコマンド名を使用
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    pkgs=("$cmd")
  fi

  if command -v "$cmd" &>/dev/null; then
    info "$cmd: OK ($(command -v "$cmd"))"
  else
    warn "$cmd が見つかりません。インストールを試みます..."
    for pkg in "${pkgs[@]}"; do
      install_pkg "$pkg"
      if command -v "$cmd" &>/dev/null; then
        info "$cmd: インストール成功"
        return 0
      fi
    done

    if [[ "$is_critical" == "true" ]]; then
      error "$cmd のインストールに失敗しました。このパッケージは必須です。"
    else
      warn "$cmd のインストールに失敗しました。機能が制限される可能性があります。"
    fi
  fi
}

check_cmd mysqldump mysql-client mariadb-client true
check_cmd gzip gzip true
check_cmd tar tar true
check_cmd curl curl true

# aws-cli (localバックエンド以外で必要)
if [[ "${STORAGE_BACKEND:-local}" != "local" ]]; then
  if command -v aws &>/dev/null; then
    info "aws-cli: OK ($(aws --version | head -1))"
  else
    warn "aws-cli が見つかりません。インストールを検討してください。"
    warn "参考: https://docs.aws.amazon.com/ja_jp/cli/latest/userguide/getting-started-install.html"
    # 自動インストールは環境によって手順が異なるため、警告に留めるか
    # あるいは主要なOS向けに試行する
    if command -v apt-get &>/dev/null; then
        install_pkg "awscli"
    fi
    command -v aws &>/dev/null && info "aws-cli: インストール成功" || warn "aws-cli の自動インストールに失敗しました。手動でインストールしてください。"
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

# ---- クラウドストレージ設定案内 ----
if [[ "${STORAGE_BACKEND:-local}" != "local" ]]; then
  step "クラウドストレージ設定 (${STORAGE_BACKEND})"

  info "AWS CLI (aws s3) を使用して同期を行います。"
  info "config.env に以下の環境変数が設定されているか確認してください:"
  info "  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION"
  if [[ -n "${S3_ENDPOINT_URL:-}" ]]; then
    info "  S3_ENDPOINT_URL: ${S3_ENDPOINT_URL}"
  fi

  # 接続テスト
  info "ストレージ接続テスト..."
  S3_OPTS=()
  [[ -n "${S3_ENDPOINT_URL:-}" ]] && S3_OPTS+=("--endpoint-url" "${S3_ENDPOINT_URL}")
  
  # 環境変数を一時的にエクスポートしてテスト
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"

  # バケットの存在確認
  if aws s3 ls "s3://${STORAGE_BUCKET}/" "${S3_OPTS[@]}" &>/dev/null; then
    info "接続テスト: OK (バケット ${STORAGE_BUCKET} は存在します)"
  else
    if [[ "${CREATE_BUCKET:-n}" == "y" ]]; then
      info "バケット ${STORAGE_BUCKET} が見つからないため、新規作成を試みます..."
      if aws s3 mb "s3://${STORAGE_BUCKET}/" "${S3_OPTS[@]}"; then
        info "バケットの作成に成功しました。"
      else
        error "バケットの作成に失敗しました。認証情報や権限を確認してください。"
      fi
    else
      warn "バケット ${STORAGE_BUCKET} が見つかりません。接続テストに失敗しました。"
      warn "config.env で CREATE_BUCKET=y を設定するか、手動でバケットを作成してください。"
    fi
  fi
fi

# ---- MySQL バックアップユーザー案内 ----
step "MySQL バックアップユーザー設定"
info "権限設定の案内はセットアップ完了後にまとめて表示します。"

# バイナリログチェック
BIN_LOG=$(mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_USER}" -p"${DB_PASS}" \
  -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | grep -i "log_bin" | awk '{print $2}' || echo "UNKNOWN")

if [[ "$BIN_LOG" == "ON" ]]; then
  info "バイナリログ: 有効（PITRが利用可能）"
else
  warn "バイナリログが無効です。有効にする手順はセットアップ完了後に表示します。"
fi

# ---- Cron 設定 ----
step "Cron ジョブ設定"

CRON_FILE="/etc/cron.d/backup-${SERVICE_NAME:-$ENVIRONMENT}-${ENVIRONMENT}"
if [[ -d "/etc/cron.d" ]]; then
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
else
  warn "/etc/cron.d が見つかりません。Cron ジョブの自動設定をスキップしました。"
  info "手動設定の詳細はセットアップ完了後に表示します。"
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

# ---- 完了メッセージ ----
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN}  セットアップ完了${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# 手動対応が必要な事項のまとめ
MANUAL_TASKS=()

# 設定ファイルのパーミッション
if [[ "${SET_CHMOD_600:-false}" == "true" ]]; then
  MANUAL_TASKS+=("1. 設定ファイルのセキュリティ設定")
  MANUAL_TASKS+=("   機密情報保護のため、config.env のパーミッションを 600 に変更してください。")
  MANUAL_TASKS+=("   chmod 600 ${CONFIG_FILE}")
  MANUAL_TASKS+=("")
fi

# MySQL ユーザー権限
MANUAL_TASKS+=("2. MySQL バックアップユーザー権限設定")
MANUAL_TASKS+=("   以下のSQLをMySQLで実行して、権限を持つユーザーを作成してください:")
MANUAL_TASKS+=("   CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';")
MANUAL_TASKS+=("   GRANT SELECT, RELOAD, LOCK TABLES, REPLICATION CLIENT, SHOW VIEW, EVENT, TRIGGER ON *.* TO '${DB_USER}'@'%';")
MANUAL_TASKS+=("   GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';")
[[ -n "${TEST_DB_NAME:-}" ]] && MANUAL_TASKS+=("   GRANT ALL PRIVILEGES ON \`${TEST_DB_NAME}\`.* TO '${DB_USER}'@'%';")
MANUAL_TASKS+=("   FLUSH PRIVILEGES;")
MANUAL_TASKS+=("")

# バイナリログ (PITR)
if [[ "$BIN_LOG" != "ON" ]]; then
  MANUAL_TASKS+=("3. バイナリログ (PITR) の有効化 (推奨)")
  MANUAL_TASKS+=("   mysqld.cnf に以下を追記し、MySQLを再起動してください:")
  MANUAL_TASKS+=("   log_bin = /var/log/mysql/mysql-bin.log")
  MANUAL_TASKS+=("   expire_logs_days = 7")
  MANUAL_TASKS+=("   binlog_format = ROW")
  MANUAL_TASKS+=("")
fi

# TLS/SSL エラー (ERROR 2026) 対応
MANUAL_TASKS+=("4. TLS/SSL エラー (ERROR 2026) への対応 (必要に応じて)")
MANUAL_TASKS+=("   MySQL/MariaDB 接続時に TLS/SSL エラーが出る場合は、~/.my.cnf に設定を追記してください。")
MANUAL_TASKS+=("   MySQL: [client]")
MANUAL_TASKS+=("          ssl-mode=DISABLED")
MANUAL_TASKS+=("   MariaDB: [client]")
MANUAL_TASKS+=("            ssl=0")
MANUAL_TASKS+=("")

# Cron ジョブ (自動設定がスキップされた場合)
if [[ ! -d "/etc/cron.d" ]]; then
  MANUAL_TASKS+=("5. Cron ジョブの手動設定")
  MANUAL_TASKS+=("   ホスト側または別のコンテナで以下の設定を行ってください:")
  MANUAL_TASKS+=("   ${CRON_MYSQL} ${SCRIPT_DIR}/scripts/backup_mysql.sh ${CONFIG_FILE}")
  MANUAL_TASKS+=("   ${CRON_FILES} ${SCRIPT_DIR}/scripts/backup_files.sh ${CONFIG_FILE}")
  MANUAL_TASKS+=("   ${CRON_SYNC} ${SCRIPT_DIR}/scripts/backup_sync.sh ${CONFIG_FILE}")
  MANUAL_TASKS+=("")
fi

# 手動対応事項の表示
if [[ ${#MANUAL_TASKS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}!!! 重要: セットアップ後に手動で対応が必要な事項があります !!!${NC}"
  echo "------------------------------------------------------------"
  for task in "${MANUAL_TASKS[@]}"; do
    echo -e "$task"
  done
  echo "------------------------------------------------------------"
  echo ""
fi

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
