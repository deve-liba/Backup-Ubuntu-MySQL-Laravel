#!/bin/bash
# ==========================================================
# restore.sh - インタラクティブ リストアスクリプト
#
# 使い方:
#   ./restore.sh [-h] [config.env] [サブコマンド] [オプション]
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- ヘルプ（config.env ロード前に処理） ----
usage() {
  cat <<EOF
使い方: $(basename "$0") [オプション] [config.envのパス] [サブコマンド] [フィルタ]

  バックアップの一覧表示とリストアを行います。
  引数なしで起動するとインタラクティブモードで動作します。

オプション:
  -h, --help    このヘルプを表示して終了

サブコマンド:
  (なし)                  インタラクティブモード
  list                    バックアップ一覧を表示
  restore <ファイルパス>   指定ファイルをリストア

list フィルタオプション:
  --type   <種類>       mysql / storage / env / config / extra / files
  --env    <環境名>     production / staging / development
  --date   <日付>       YYYY-MM-DD 形式
  --search <キーワード>  ファイル名に含まれる任意の文字列

restore オプション:
  --target-db  <DB名>   MySQLリストア先DB名（省略時は config.env の DB_NAME）
  --target-dir <パス>   ファイルリストア先ディレクトリ（省略時は /）
  --mask-sql   <パス>   MySQLリストア時に実行するマスク用SQLファイルのパス
  --stop-services       リストア前後にサービスを停止・起動する (RESTORE_STOP_SERVICES)

例:
  # インタラクティブ
  $(basename "$0")
  $(basename "$0") /etc/backup/config_production.env

  # 一覧表示
  $(basename "$0") /etc/backup/config.env list
  $(basename "$0") /etc/backup/config.env list --type mysql
  $(basename "$0") /etc/backup/config.env list --type mysql --env production --date 2026-03-15
  $(basename "$0") /etc/backup/config.env list --search 20260315

  # 直接リストア
  $(basename "$0") /etc/backup/config.env restore \\
      /backup/production/mysql/production_mysql_20260315_020000.sql.gz
  $(basename "$0") /etc/backup/config.env restore \\
      /backup/production/files/production_storage_20260315_030000.tar.gz \\
      --target-dir /var/www/your-app

  # クラウドからのリストア (S3 URL またはファイル名)
  $(basename "$0") config.env restore s3://my-bucket/backup/prod/mysql/file.sql.gz
  $(basename "$0") config.env restore production_mysql_20260315_020000.sql.gz

S3 / S3 互換ストレージからのリストア:
  STORAGE_BACKEND が local 以外の場合、リモート上のバックアップも
  一覧に表示されます。リストア時は aws s3 cp 経由で直接取得します。
EOF
  exit 0
}

for arg in "$@"; do case "$arg" in -h|--help) usage ;; esac; done

CONFIG_FILE="${1:-${SCRIPT_DIR}/../config.env}"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config.env が見つかりません: $CONFIG_FILE"; exit 1; }
source "$CONFIG_FILE"

LOG_DIR="${LOG_DIR:-/var/log/backup}"
mkdir -p "$LOG_DIR"

# ---- カラー定義 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ---- ユーティリティ ----
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_DIR}/restore.log"; }
info() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
die()  { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
hr()   { printf '%0.s─' {1..70}; echo; }

# ---- バックアップ一覧取得 ----
# 引数: type_filter env_filter date_filter search_filter
# 標準出力にファイルパスを1行ずつ出力
list_backups() {
  local type_filter="${1:-}"
  local env_filter="${2:-}"
  local date_filter="${3:-}"
  local search_filter="${4:-}"

  local search_dirs=()

  # 検索ディレクトリを決定
  if [[ -n "$env_filter" ]]; then
    local d="${BACKUP_LOCAL_DIR}/${SERVICE_NAME:-*}/${env_filter}"
    [[ -d "$d" ]] && search_dirs+=("$d")
  else
    # すべてのサービス・環境を対象
    for sd in "${BACKUP_LOCAL_DIR}"/*/; do
      for ed in "$sd"*/; do
        [[ -d "$ed" ]] && search_dirs+=("$ed")
      done
    done
  fi

  [[ ${#search_dirs[@]} -eq 0 ]] && return 0

  # クラウドリモートからも取得（aws-cliが使用可能な場合）
  local cloud_list=()
  if [[ "${STORAGE_BACKEND:-local}" != "local" ]] && command -v aws &>/dev/null; then
    local remote_base="s3://${STORAGE_BUCKET}/${STORAGE_PREFIX}"
    local s3_path="$remote_base/"
    if [[ -n "$env_filter" ]]; then
      s3_path+="${SERVICE_NAME:-*}/${env_filter}/"
    fi

    local s3_opts=()
    [[ -n "${S3_ENDPOINT_URL:-}" ]] && s3_opts+=("--endpoint-url" "${S3_ENDPOINT_URL}")
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
    [[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION

    mapfile -t cloud_list < <(
      aws s3 ls "$s3_path" ${s3_opts+"${s3_opts[@]}"} --recursive 2>/dev/null \
        | grep ".gz$" | awk '{print "REMOTE:" $4}' || true
    )
  fi

  # ローカルファイルを検索
  local found=()
  for dir in "${search_dirs[@]}"; do
    while IFS= read -r -d '' file; do
      local fname
      fname=$(basename "$file")

      # 種類フィルタ
      if [[ -n "$type_filter" ]]; then
        case "$type_filter" in
          mysql)   [[ "$fname" == *"_mysql_"* ]]   || continue ;;
          storage) [[ "$fname" == *"_storage_"* ]] || continue ;;
          env)     [[ "$fname" == *"_env_"* ]]     || continue ;;
          config)  [[ "$fname" == *"_config_"* ]]  || continue ;;
          extra)   [[ "$fname" == *"_extra_"* ]]   || continue ;;
          files)   [[ "$fname" != *"_mysql_"* ]]   || continue ;;
        esac
      fi

      # 日付フィルタ（YYYY-MM-DD → YYYYMMDD）
      if [[ -n "$date_filter" ]]; then
        local date_nodash="${date_filter//-/}"
        [[ "$fname" == *"${date_nodash}"* ]] || continue
      fi

      # テキスト検索フィルタ
      if [[ -n "$search_filter" ]]; then
        echo "$fname" | grep -qi "$search_filter" || continue
      fi

      found+=("$file")
    done < <(find "$dir" -name "*.gz" -type f -print0 2>/dev/null)
  done

  # クラウドファイルも追加（ローカルに存在しないもの）
  for remote_entry in "${cloud_list[@]}"; do
    local fname="${remote_entry#REMOTE:}"
    fname=$(basename "$fname")
    # フィルタ適用（ローカルと同様）
    if [[ -n "$type_filter" ]]; then
      case "$type_filter" in
        mysql)   [[ "$fname" == *"_mysql_"* ]]   || continue ;;
        storage) [[ "$fname" == *"_storage_"* ]] || continue ;;
        env)     [[ "$fname" == *"_env_"* ]]     || continue ;;
        config)  [[ "$fname" == *"_config_"* ]]  || continue ;;
        extra)   [[ "$fname" == *"_extra_"* ]]   || continue ;;
        files)   [[ "$fname" != *"_mysql_"* ]]   || continue ;;
      esac
    fi
    [[ -n "$date_filter" ]] && [[ "$fname" != *"${date_filter//-/}"* ]] && continue
    [[ -n "$search_filter" ]] && ! echo "$fname" | grep -qi "$search_filter" && continue
    found+=("${remote_entry}")
  done

  # 降順ソート（新しい順）
  if [[ ${#found[@]} -gt 0 ]]; then
    printf '%s\n' "${found[@]}" | sort -r
  fi
}

# ---- 番号付き一覧の表示 ----
# 引数: ファイルリスト（改行区切り）
display_list() {
  local -a files=("$@")
  local count=${#files[@]}

  if [[ $count -eq 0 ]]; then
    warn "バックアップファイルが見つかりませんでした。"
    return 1
  fi

  echo ""
  printf "${BOLD}%-4s  %-20s  %-12s  %-12s  %-14s  %-8s  %s${NC}\n" \
      "No." "日時" "サービス" "環境" "種類" "サイズ" "ファイル名"
    hr
  
    local i=1
    for file in "${files[@]}"; do
      local is_remote=false
      local fname size fservice fenv ftype fdatetime fdate ftime
  
      if [[ "$file" == REMOTE:* ]]; then
        is_remote=true
        fname=$(basename "${file#REMOTE:}")
        size="[cloud]"
      else
        fname=$(basename "$file")
        size=$(du -sh "$file" 2>/dev/null | cut -f1 || echo "?")
      fi
  
      # ファイル名からメタ情報を抽出
      # 旧形式: {env}_{type}_{YYYYMMDD}_{HHMMSS}.{ext}
      # 新形式: {service}_{env}_{type}_{YYYYMMDD}_{HHMMSS}.{ext}
      local part_count
      part_count=$(echo "$fname" | tr '_' '\n' | wc -l)
  
      if [[ $part_count -ge 5 ]]; then
        # 新形式とみなす
        fservice=$(echo "$fname" | cut -d'_' -f1)
        fenv=$(echo "$fname" | cut -d'_' -f2)
      else
        # 旧形式
        fservice="-"
        fenv=$(echo "$fname" | cut -d'_' -f1)
      fi
  
      fdate=$(echo "$fname" | grep -oE '[0-9]{8}' | head -1 || echo "")
      ftime=$(echo "$fname" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1 | cut -d'_' -f2 || echo "")
  
      if [[ -n "$fdate" && -n "$ftime" ]]; then
        fdatetime="${fdate:0:4}-${fdate:4:2}-${fdate:6:2} ${ftime:0:2}:${ftime:2:2}"
      else
        fdatetime="不明"
      fi
  
      # 種類の判定
      if [[ "$fname" == *"_mysql_"* ]];   then ftype="MySQL";
      elif [[ "$fname" == *"_storage_"* ]]; then ftype="Storage";
      elif [[ "$fname" == *"_env_"* ]];    then ftype=".env";
      elif [[ "$fname" == *"_config_"* ]]; then ftype="Config";
      elif [[ "$fname" == *"_extra_"* ]];  then ftype="Extra";
      else ftype="不明"; fi
  
      $is_remote && ftype="${ftype} ☁"
  
      printf "${CYAN}%-4s${NC}  %-20s  %-12s  %-12s  %-14s  %-8s  %s\n" \
        "$i" "$fdatetime" "$fservice" "$fenv" "$ftype" "$size" "$fname"
  
      ((i++))
    done

  echo ""
  info "合計: ${count} 件"
}

# ---- MySQL リストア ----
restore_mysql() {
  local backup_file="$1"
  local target_db="${2:-$DB_NAME}"
  local mask_sql_file="${3:-}"
  local stop_services="${4:-false}"
  local TEMP_FILE=""

  log "MySQL リストア開始: $(basename "$backup_file") → DB:${target_db} (mask_sql=${mask_sql_file}, stop_services=${stop_services})"

  warn "データベース '${target_db}' を上書きします。続行しますか？ [y/N]: "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "キャンセルしました。"; return 0; }

  # 一時ファイルの準備（リモートの場合）
  if [[ "$backup_file" == REMOTE:* ]]; then
    TEMP_FILE=$(mktemp "/tmp/restore_mysql_XXXXXX.sql.gz")
  fi

  # サービス停止
  local stopped_services=()
  if [[ "$stop_services" == "true" && -n "${RESTORE_STOP_SERVICES:-}" ]]; then
    for svc in $RESTORE_STOP_SERVICES; do
      info "サービス停止中: $svc"
      if systemctl stop "$svc" 2>/dev/null; then
        stopped_services+=("$svc")
      else
        warn "サービス $svc の停止に失敗しました（権限不足または存在しません）"
      fi
    done
  fi

  echo "リストア中..."

  local restore_cmd="MYSQL_PWD=\"${DB_PASS}\" mysql --host=\"${DB_HOST}\" --port=\"${DB_PORT:-3306}\" --user=\"${DB_USER}\" \"${target_db}\""

  if [[ "$backup_file" == REMOTE:* ]]; then
    local remote_file="${backup_file#REMOTE:}"
    local remote_full_path="s3://${STORAGE_BUCKET}/${remote_file}"
    local s3_opts=()
    [[ -n "${S3_ENDPOINT_URL:-}" ]] && s3_opts+=("--endpoint-url" "${S3_ENDPOINT_URL}")
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
    [[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION

    log "S3 からダウンロード中: ${remote_full_path}"
    if ! aws s3 cp "${remote_full_path}" - ${s3_opts+"${s3_opts[@]}"} > "${TEMP_FILE}" 2>>"${LOG_DIR}/restore.log"; then
      rm -f "${TEMP_FILE}"
      die "S3 からのダウンロードに失敗しました: ${remote_full_path}"
    fi
    use_file="${TEMP_FILE}"
  else
    use_file="$backup_file"
  fi

  echo "リストア中..."
  if ! gunzip -c "$use_file" | eval "$restore_cmd" 2>>"${LOG_DIR}/restore.log"; then
    [[ -f "${TEMP_FILE:-}" ]] && rm -f "${TEMP_FILE}"
    echo ""
    warn "MySQL リストアに失敗しました。権限不足の可能性があります (DROP command denied 等)。"
    warn "バックアップユーザーに GRANT ALL PRIVILEGES ON \`${target_db}\`.* が付与されているか確認してください。"
    die "詳細は ${LOG_DIR}/restore.log を確認してください。"
  fi

  [[ -f "${TEMP_FILE:-}" ]] && rm -f "${TEMP_FILE}"

  # マスク処理用SQLの実行
  if [[ -n "$mask_sql_file" ]]; then
    if [[ -f "$mask_sql_file" ]]; then
      info "マスクSQL実行中: $mask_sql_file"
      MYSQL_PWD="${DB_PASS}" mysql --host="${DB_HOST}" --port="${DB_PORT:-3306}" --user="${DB_USER}" "${target_db}" < "$mask_sql_file" 2>>"${LOG_DIR}/restore.log" \
        || warn "マスクSQLの実行中にエラーが発生しました"
    else
      warn "マスクSQLファイルが見つかりません: $mask_sql_file"
    fi
  fi

  # サービス起動
  for svc in "${stopped_services[@]}"; do
    info "サービス起動中: $svc"
    systemctl start "$svc" || warn "サービス $svc の起動に失敗しました"
  done

  info "✅ MySQL リストア完了: $(basename "$backup_file") → ${target_db}"
  log "MySQL リストア完了: $(basename "$backup_file") → ${target_db}"
}

# ---- ファイルリストア ----
restore_files() {
  local backup_file="$1"
  local restore_dir="${2:-/}"
  local TEMP_FILE=""

  log "ファイルリストア開始: $(basename "$backup_file") → ${restore_dir}"

  # 一時ファイルの準備（リモートの場合）
  if [[ "$backup_file" == REMOTE:* ]]; then
    TEMP_FILE=$(mktemp "/tmp/restore_files_XXXXXX.tar.gz")
    
    local remote_file="${backup_file#REMOTE:}"
    local remote_full_path="s3://${STORAGE_BUCKET}/${remote_file}"
    local s3_opts=()
    [[ -n "${S3_ENDPOINT_URL:-}" ]] && s3_opts+=("--endpoint-url" "${S3_ENDPOINT_URL}")
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
    [[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION

    log "S3 からダウンロード中: ${remote_full_path}"
    if ! aws s3 cp "${remote_full_path}" - ${s3_opts+"${s3_opts[@]}"} > "${TEMP_FILE}" 2>>"${LOG_DIR}/restore.log"; then
      rm -f "${TEMP_FILE}"
      die "S3 からのダウンロードに失敗しました: ${remote_full_path}"
    fi
    backup_file="${TEMP_FILE}"
  fi

  echo ""
  echo "含まれるファイル（先頭20件）:"
  tar tzf "$backup_file" 2>/dev/null | head -20
  echo ""

  warn "上記を '${restore_dir}' に展開します。続行しますか？ [y/N]: "
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    [[ -n "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
    info "キャンセルしました。"
    return 0
  fi

  echo "展開中..."
  if ! tar xzf "$backup_file" -C "$restore_dir"; then
    [[ -n "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
    die "ファイルリストアに失敗しました。"
  fi

  [[ -n "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"

  info "✅ ファイルリストア完了: $(basename "$backup_file") → ${restore_dir}"
  log "ファイルリストア完了: $(basename "$backup_file") → ${restore_dir}"
}

# ---- ファイル選択してリストア ----
select_and_restore() {
  local -a files=("$@")

  display_list "${files[@]}"
  [[ ${#files[@]} -eq 0 ]] && return 0

  echo -n "リストアするファイル番号を入力 (0=キャンセル): "
  read -r selection

  [[ "$selection" == "0" ]] && { info "キャンセルしました。"; return 0; }
  [[ "$selection" =~ ^[0-9]+$ ]] || die "無効な入力です: $selection"
  [[ "$selection" -ge 1 && "$selection" -le ${#files[@]} ]] \
    || die "番号が範囲外です (1-${#files[@]})"

  local selected="${files[$((selection - 1))]}"
  local fname
  fname=$(basename "${selected#REMOTE:}")

  info "選択: $fname"

  if [[ "$fname" == *"_mysql_"* ]]; then
    echo -n "リストア先DB名 (Enter で '${DB_NAME}'): "
    read -r target_db
    
    local mask_sql_file=""
    if [[ -n "${MASK_SQL_FILE:-}" ]]; then
      echo -n "マスク用SQLを実行しますか？ (ファイル: ${MASK_SQL_FILE}) [y/N]: "
      read -r mask_confirm
      if [[ "$mask_confirm" =~ ^[Yy]$ ]]; then
        mask_sql_file="${MASK_SQL_FILE}"
      fi
    fi

    if [[ -z "$mask_sql_file" ]]; then
      echo -n "実行するマスク用SQLファイルのパス (不要なら空のままEnter): "
      read -r mask_sql_path
      mask_sql_file="$mask_sql_path"
    fi

    local stop_services="false"
    if [[ -n "${RESTORE_STOP_SERVICES:-}" ]]; then
      echo -n "リストア前後にサービスを停止しますか？ (対象: ${RESTORE_STOP_SERVICES}) [y/N]: "
      read -r stop_confirm
      [[ "$stop_confirm" =~ ^[Yy]$ ]] && stop_services="true"
    fi

    restore_mysql "$selected" "${target_db:-$DB_NAME}" "$mask_sql_file" "$stop_services"
  elif [[ "$fname" == *"_env_"* ]]; then
    echo -n "展開先ディレクトリ (Enter で '${APP_DIR}'): "
    read -r restore_dir
    restore_files "$selected" "${restore_dir:-$APP_DIR}"
  elif [[ "$fname" == *"_storage_"* ]]; then
    echo -n "展開先ディレクトリ (Enter で '${APP_DIR}'): "
    read -r restore_dir
    restore_files "$selected" "${restore_dir:-$APP_DIR}"
  else
    echo -n "展開先ディレクトリ (Enter で '/'): "
    read -r restore_dir
    restore_files "$selected" "${restore_dir:-/}"
  fi
}

# ---- インタラクティブモード ----
interactive_mode() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║      バックアップ リストアツール             ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo -e "${DIM}設定: ${CONFIG_FILE}${NC}"
  echo ""

  # ---- STEP 1: 種類選択 ----
  echo -e "${BOLD}[STEP 1] リストアの種類:${NC}"
  echo "  1) MySQL データベース"
  echo "  2) ストレージファイル (storage/app)"
  echo "  3) .env ファイル"
  echo "  4) サーバー設定 (nginx, php 等)"
  echo "  5) 全種類"
  echo -n "選択 [1-5]: "
  read -r type_choice

  local type_filter=""
  case "$type_choice" in
    1) type_filter="mysql" ;;
    2) type_filter="storage" ;;
    3) type_filter="env" ;;
    4) type_filter="config" ;;
    5) type_filter="" ;;
    *) die "無効な選択です: $type_choice" ;;
  esac

  # ---- STEP 2: 環境フィルタ ----
  echo ""
  echo -e "${BOLD}[STEP 2] 環境でフィルタリング:${NC}"
  echo "  1) すべての環境"

  local envs=()
  for d in "${BACKUP_LOCAL_DIR}"/*/; do
    [[ -d "$d" ]] && envs+=("$(basename "$d")")
  done

  local ei=2
  for e in "${envs[@]}"; do
    echo "  ${ei}) $e"
    ((ei++))
  done
  echo -n "選択 [1-$((ei-1))]: "
  read -r env_choice

  local env_filter=""
  if [[ "$env_choice" != "1" ]]; then
    local env_idx=$((env_choice - 2))
    env_filter="${envs[$env_idx]:-}"
  fi

  # ---- STEP 3: 絞り込み（任意）----
  echo ""
  echo -e "${BOLD}[STEP 3] 絞り込み（任意）:${NC}"
  echo -n "  日付フィルター (YYYY-MM-DD、スキップはEnter): "
  read -r date_filter

  echo -n "  検索キーワード (スキップはEnter): "
  read -r search_filter

  # ---- バックアップ一覧取得 ----
  echo ""
  echo "バックアップファイルを検索中..."
  mapfile -t backup_files < <(list_backups "$type_filter" "$env_filter" "$date_filter" "$search_filter")

  select_and_restore "${backup_files[@]}"
}

# ---- CLIモード ----
cli_list() {
  local type_filter="" env_filter="" date_filter="" search_filter=""

  shift 2  # $1=config, $2="list" を消費
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)   type_filter="${2:-}";   shift 2 ;;
      --env)    env_filter="${2:-}";    shift 2 ;;
      --date)   date_filter="${2:-}";   shift 2 ;;
      --search) search_filter="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  mapfile -t backup_files < <(list_backups "$type_filter" "$env_filter" "$date_filter" "$search_filter")
  display_list "${backup_files[@]}"
}

cli_restore() {
  # 引数: $1=config $2="restore" $3=ファイルパス [$4..]=オプション
  local backup_file="${3:-}"
  [[ -n "$backup_file" ]] || die "ファイルパスを指定してください\n使い方: $(basename "$0") -h"

  local target_db="${DB_NAME}"
  local target_dir="/"
  local mask_sql_file="${MASK_SQL_FILE:-}"
  local stop_services="false"

  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-db)     target_db="${2:-$DB_NAME}"; shift 2 ;;
      --target-dir)    target_dir="${2:-/}";       shift 2 ;;
      --mask-sql)      mask_sql_file="${2:-}";     shift 2 ;;
      --stop-services) stop_services="true";       shift 1 ;;
      *) shift ;;
    esac
  done

  if [[ "$backup_file" == s3://* ]]; then
    # S3 URL (s3://bucket/path/to/file) の正規化
    # 指定されたバケットが config.env の STORAGE_BUCKET と異なる場合、一時的に STORAGE_BUCKET を上書き
    local bucket_name="${backup_file#s3://}"
    bucket_name="${bucket_name%%/*}"
    if [[ "$bucket_name" != "$STORAGE_BUCKET" ]]; then
      warn "指定されたバケット (${bucket_name}) が設定 (${STORAGE_BUCKET}) と異なります。指定されたバケットを使用します。"
      STORAGE_BUCKET="$bucket_name"
    fi

    local path_only="${backup_file#s3://*/}"
    backup_file="REMOTE:${path_only}"
  elif [[ "$backup_file" == REMOTE:* ]]; then
    # 既に REMOTE: 形式の場合はそのまま（パスがバケット内プレフィックス以降であることを期待）
    :
  else
    # ローカルファイルの存在確認
    if [[ ! -f "$backup_file" ]]; then
      # ローカルで見つからない場合、ファイル名のみならクラウドから検索を試みる
      if [[ "$backup_file" != */* ]]; then
        info "ローカルファイルが見つかりません。クラウド上のファイルを検索しています: $backup_file"
        local found_cloud
        found_cloud=$(list_backups "" "" "" "$backup_file" | grep "^REMOTE:" | head -1 || true)
        if [[ -n "$found_cloud" ]]; then
          backup_file="$found_cloud"
          info "クラウド上のファイルが見つかりました: ${backup_file#REMOTE:}"
        else
          die "ファイルが見つかりません: $backup_file"
        fi
      else
        die "ファイルが見つかりません: $backup_file"
      fi
    fi
  fi

  local fname
  fname=$(basename "${backup_file#REMOTE:}")
  if [[ "$fname" == *"_mysql_"* ]]; then
    restore_mysql "$backup_file" "$target_db" "$mask_sql_file" "$stop_services"
  else
    restore_files "$backup_file" "$target_dir"
  fi
}

# ---- エントリーポイント ----
case "${2:-}" in
  list)    cli_list "$@" ;;
  restore) cli_restore "$@" ;;
  "")      interactive_mode ;;
  *)       usage ;;
esac
