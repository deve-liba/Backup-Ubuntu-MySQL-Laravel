# バックアップシステム セットアップガイド

Ubuntu + MySQL + PHP + Laravel 向けの自動バックアップ／リストアシステムです。

---

## ファイル構成

```
backup-system/
├── config.env.example      設定ファイルテンプレート
├── setup.sh                セットアップスクリプト
├── scripts/
│   ├── backup_mysql.sh     MySQL バックアップ
│   ├── backup_files.sh     ファイルバックアップ（storage / .env / サーバー設定）
│   ├── backup_sync.sh      クラウドストレージ同期
│   ├── notify.sh           共通通知基盤（Slack/Mattermost/Email/SendGrid）
│   ├── test_restore.sh     テスト用DBへの自動リストア検証
│   ├── setup_env.sh        対話型設定ファイル作成（config.env）
│   └── restore.sh          リストア（インタラクティブ対応）
├── cost_calculator.html    ストレージコスト試算ツール（ブラウザで開く）
├── BACKUP_EVALUATION_REPORT.md  バックアップシステム 評価レポート（新規）
└── README.md               このファイル
```

---

## システム評価
本バックアップシステムの設計、機能、安全性についての包括的な評価レポートを公開しています。
導入検討や運用設計の参考にしてください。

👉 [**バックアップシステム 評価レポート (BACKUP_EVALUATION_REPORT.md)**](./BACKUP_EVALUATION_REPORT.md)

---

## クイックスタート

### 1. セットアップ実行

設定ファイル（`config.env`）がない状態で `setup.sh` を実行すると、自動的に対話型設定スクリプトが起動します。

```bash
cd backup-system
sudo bash setup.sh
```

**手動で設定ファイルを作成する場合:**

対話型スクリプトを直接実行して `config.env` を作成することも可能です。

```bash
bash scripts/setup_env.sh
```

または、テンプレートをコピーして直接編集します。

```bash
cp config.env.example config.env
vi config.env
```

**最低限設定が必要な項目:**

| 項目                                            | 説明                                      |
|-----------------------------------------------|-----------------------------------------|
| `SERVICE_NAME`                                | サービス名（英数字、ハイフン、アンダースコア） |
| `ENVIRONMENT`                                 | 環境名（production / staging / development） |
| `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASS` | MySQL接続情報                               |
| `APP_DIR`                                     | Laravelアプリのルートパス                        |
| `STORAGE_BACKEND`                             | バックアップ先ストレージ                            |
| `STORAGE_REMOTE_NAME` / `STORAGE_BUCKET`      | rcloneリモート名・バケット                        |
| `WEBHOOK_URL`                                 | Slack/Mattermost 通知用 Webhook             |
| `SENDGRID_API_KEY`                            | SendGrid API キー（メール用）                  |
| `TEST_DB_NAME`                                | テスト用DB名（リストア検証用）                   |
| `MASK_SQL_FILE`                               | マスク用SQLファイルのパス（任意）                |
| `RESTORE_STOP_SERVICES`                       | リストア時に停止・起動するサービス（任意）         |

### 2. インストールとスケジュール登録

```bash
sudo bash setup.sh
```

すでに `config.env` を作成済みの場合は、その内容に基づいて以下の処理が行われます：

- 依存パッケージのチェック（mysqldump, gzip, tar, curl）
- rclone のインストール（未インストールの場合）
- rclone リモートの設定（ストレージバックエンドに応じて）
- バックアップ・ログディレクトリの作成
- Cron ジョブの設定（`/etc/cron.d/backup-{サービス名}-{環境名}`）
- テスト用データベースの権限設定案内

### 3. 動作テスト

```bash
# 各スクリプトを手動実行してエラーがないか確認
bash scripts/backup_mysql.sh config.env
bash scripts/backup_files.sh config.env
bash scripts/backup_sync.sh config.env

# バックアップ一覧で作成されたか確認
bash scripts/restore.sh config.env list
```

---

## バックアップ仕様

### バックアップ対象

| 種類       | 内容                                                 | スクリプト           |
|----------|----------------------------------------------------|-----------------|
| MySQL    | 全テーブル・ルーティン・トリガー（`mysqldump --single-transaction`） | backup_mysql.sh |
| ストレージ    | `storage/app/` 配下のアップロードファイル等                      | backup_files.sh |
| .env     | Laravelの環境設定ファイル                                   | backup_files.sh |
| サーバー設定   | nginx, php 等の設定ディレクトリ                              | backup_files.sh |
| 追加ディレクトリ | `EXTRA_BACKUP_DIRS` で指定したディレクトリ                    | backup_files.sh |

### バックアップファイル命名規則

```
{サービス名}_{環境}_{種類}_{YYYYMMDD}_{HHMMSS}.{拡張子}

例:
  my-app_production_mysql_20260315_020000.sql.gz
  my-app_production_storage_20260315_030000.tar.gz
  my-app_production_env_20260315_030000.tar.gz
  my-app_production_config_etc_nginx_20260315_030000.tar.gz
```

### ディレクトリ構造

```
/backup/
└── {サービス名}/
    └── production/
        ├── mysql/
        │   └── {サービス名}_production_mysql_*.sql.gz
        └── files/
            ├── {サービス名}_production_storage_*.tar.gz
            ├── {サービス名}_production_env_*.tar.gz
            └── {サービス名}_production_config_*.tar.gz
```

---

## リストア手順

### インタラクティブモード（推奨）

```bash
bash scripts/restore.sh config.env
```

対話形式でステップを進めます：

1. リストアの種類を選択（MySQL / Storage / .env / Config / 全種類）
2. 環境でフィルタリング
3. 日付・キーワードで絞り込み（任意）
4. 番号付き一覧から選択
5. 確認後リストア実行

### コマンドラインモード

```bash
# 全バックアップ一覧
bash scripts/restore.sh config.env list

# 絞り込み例
bash scripts/restore.sh config.env list --type mysql
bash scripts/restore.sh config.env list --env production
bash scripts/restore.sh config.env list --date 2026-03-15
bash scripts/restore.sh config.env list --type mysql --env production --date 2026-03-15
bash scripts/restore.sh config.env list --search "20260315"

# 直接リストア（確認プロンプトあり）
bash scripts/restore.sh config.env restore \
  /backup/production/mysql/production_mysql_20260315_020000.sql.gz

# オプション指定の例
bash scripts/restore.sh config.env restore \
  /backup/production/mysql/production_mysql_20260315_020000.sql.gz \
  --mask-sql scripts/mask_data.sql \
  --stop-services
```

### MySQL リストア（手動）

```bash
# フルリストア
gunzip < /backup/production/mysql/production_mysql_20260315_020000.sql.gz \
  | mysql -u root -p your_database
```

### データマスクとサービス制御（運用）

本番データをローカル環境や検証環境に復元する際、以下の機能が利用可能です：

- **データマスク**: `MASK_SQL_FILE` で指定したSQLファイルをリストア完了直後に実行します。メールアドレスの難読化や個人情報の削除に利用できます。
    - サンプルファイル `scripts/mask_data.sql.example` を参考に、プロジェクトに合わせたSQLを作成してください。
- **サービス制御**: `RESTORE_STOP_SERVICES` に指定したサービス（例: `nginx`, `php-fpm`）をリストア開始前に停止し、完了後に自動起動します。不整合の防止や安全な切り替えが可能です。

インタラクティブモードでは、これらを実行するかどうかの確認プロンプトが表示されます。

---

### バイナリログを使ったポイントインタイムリカバリ（PITR）

```bash
# バイナリログを使った復旧
mysqlbinlog /var/log/mysql/mysql-bin.000001 \
  --start-datetime="2026-03-15 02:00:00" \
  --stop-datetime="2026-03-15 10:30:00" \
  | mysql -u root -p
```

---

## 対応ストレージサービス

### 選択ガイド

コスト優先なら **Backblaze B2** または **Wasabi** が最有力候補です。
詳細な費用試算は `cost_calculator.html` をブラウザで開いてください。

---

### Backblaze B2

**設定値:** `STORAGE_BACKEND=b2`

| 項目     | 内容                                              |
|--------|-------------------------------------------------|
| 保管コスト  | $0.006/GB/月（約¥0.9/GB）                           |
| アップロード | 無料                                              |
| ダウンロード | $0.01/GB（1GB/日まで無料）                             |
| 公式URL  | https://www.backblaze.com/cloud-storage/pricing |

**特徴:** 最安クラスのコスト。S3互換APIあり（rclone対応）。毎日1GBまでのダウンロードが無料なので、定期的なリストアテストも実質無料で行える。世界最大規模のストレージプロバイダーの一つ。

---

### Wasabi

**設定値:** `STORAGE_BACKEND=wasabi`

| 項目     | 内容                                        |
|--------|-------------------------------------------|
| 保管コスト  | $0.0069/GB/月（約¥1.0/GB）                    |
| アップロード | 無料                                        |
| ダウンロード | **無料**（回数・容量制限なし）                         |
| 公式URL  | https://wasabi.com/cloud-storage-pricing/ |

**特徴:** ダウンロードが完全無料なため、リストアテストを頻繁に行う場合や大容量のリストアが想定される場合に有利。ただし *
*90日最低保管ポリシー** があり、90日未満で削除したファイルも90日分の料金が発生するため、頻繁に世代削除する運用では割高になる可能性あり。

---

### AWS S3 Standard

**設定値:** `STORAGE_BACKEND=s3`

| 項目     | 内容                                 |
|--------|------------------------------------|
| 保管コスト  | $0.023/GB/月（約¥3.5/GB）              |
| アップロード | 無料                                 |
| ダウンロード | $0.09/GB（約¥13.5/GB）                |
| 公式URL  | https://aws.amazon.com/s3/pricing/ |

**特徴:**
業界標準のストレージ。コストは最も高いが、信頼性・可用性・エコシステムは最高峰。IAM、CloudWatch、Lambdaとの連携が容易。すでにAWSを利用している場合は移行コストがほぼゼロ。PUT/GETリクエストにも課金あり。

---

### IDrive e2

**設定値:** `STORAGE_BACKEND=idrive`

| 項目     | 内容                                        |
|--------|-------------------------------------------|
| 保管コスト  | $0.004/GB/月（約¥0.6/GB）                     |
| アップロード | 無料                                        |
| ダウンロード | $0.004/GB（約¥0.6/GB）                       |
| 公式URL  | https://www.idrive.com/object-storage-e2/ |

**特徴:** S3互換APIで最安クラスのコスト。知名度は低めだが、バックアップ用途に特化しており、コスト最優先の場合に有力。

---

### Azure Blob Storage（Cool tier）

**設定値:** `STORAGE_BACKEND=azure`

| 項目     | 内容                                                               |
|--------|------------------------------------------------------------------|
| 保管コスト  | $0.010/GB/月（約¥1.5/GB）                                            |
| アップロード | 無料                                                               |
| ダウンロード | $0.01/GB（約¥1.5/GB）                                               |
| 公式URL  | https://azure.microsoft.com/ja-jp/pricing/details/storage/blobs/ |

**特徴:** Microsoftのクラウドストレージ。Office 365やAzure ADとの親和性が高い。Cool tierはバックアップなどの低頻度アクセスに最適化。

---

### Google Cloud Storage（Nearline）

**設定値:** `STORAGE_BACKEND=gcs`

| 項目     | 内容                                       |
|--------|------------------------------------------|
| 保管コスト  | $0.010/GB/月（約¥1.5/GB）                    |
| アップロード | 無料                                       |
| ダウンロード | $0.01/GB（約¥1.5/GB）                       |
| 公式URL  | https://cloud.google.com/storage/pricing |

**特徴:** GoogleのクラウドストレージのNearlineクラスは月1回以下のアクセス向け。GCPを利用している場合に選択肢となる。BigQueryやCloud
Functionsとの連携が容易。

---

### さくらのオブジェクトストレージ

**設定値:** `STORAGE_BACKEND=sakura`

| 項目     | 内容                                                       |
|--------|----------------------------------------------------------|
| 保管コスト  | ¥2.2/GB/月                                                |
| アップロード | 無料                                                       |
| ダウンロード | ¥20/GB                                                   |
| 公式URL  | https://cloud.sakura.ad.jp/specification/object-storage/ |

**特徴:** 国内データセンター（大阪/石狩）でのデータ保管。**円建てのため為替リスクがゼロ**
。個人情報や機密データを国外に出したくない要件に適している。S3互換APIあり。

---

### Google Drive（Google One）

**設定値:** `STORAGE_BACKEND=gdrive`（rclone経由）

| 項目     | 内容                                       |
|--------|------------------------------------------|
| 保管コスト  | 月額プラン（100GB: ¥250/月、2TB: ¥1,300/月）       |
| ダウンロード | 無料                                       |
| 公式URL  | https://one.google.com/about/plans?hl=ja |

**特徴:** S3互換APIは非対応だが、rcloneでアクセス可能。コストは定額プランのため予測可能。ファイル更新時に*
*最大100バージョンのバージョン履歴**を自動保持するため、`USE_SERVICE_VERSIONING=true`
を設定するとスクリプト側の世代削除をスキップしDrive側のバージョン管理に委ねられます。

---

### Google Workspace

**設定値:** `STORAGE_BACKEND=gworkspace`（rclone経由）

| 項目     | 内容                                                                        |
|--------|---------------------------------------------------------------------------|
| 保管コスト  | Business Starter: ¥680/ユーザー/月（30GB）〜Business Standard: ¥1,360/ユーザー/月（2TB） |
| ダウンロード | 無料                                                                        |
| 公式URL  | https://workspace.google.com/intl/ja/pricing/                             |

**特徴:** 組織・チームでのGoogle Workspace契約がある場合、**共有ドライブ（Shared Drive）** に保存することでチーム全体でバックアップを管理できます。個人の
Google Drive と異なり、共有ドライブはメンバーが退職してもデータが消えません。Google Drive 同様に**最大100バージョンのバージョン履歴
**を持つため `USE_SERVICE_VERSIONING=true` が利用可能です。rclone設定時は `GWORKSPACE_DRIVE_ID`（共有ドライブのID）の指定が必要です。

---

## 通知設定

### Slack通知

`config.env` に Webhook URL を設定：

```bash
WEBHOOK_URL=https://hooks.slack.com/services/xxx/yyy/zzz
```

### メール通知

`mailコマンド` が設定済みの場合：

```bash
NOTIFY_EMAIL=admin@your-domain.com
```

---

## サービス側世代管理（Google Drive / Workspace）

`USE_SERVICE_VERSIONING=true` を設定すると、バックアップの世代管理をスクリプト側ではなく **Drive側のバージョン履歴**
に委ねます。対象バックエンドは `gdrive` / `gworkspace` のみです。

### 動作の違い

| 設定                                    | ローカル世代削除                  | クラウド同期方式                   | 世代の管理主体      |
|---------------------------------------|---------------------------|----------------------------|--------------|
| `USE_SERVICE_VERSIONING=false`（デフォルト） | あり（KEEP_GENERATIONS世代を保持） | `rclone sync`（ローカルと一致）     | スクリプト        |
| `USE_SERVICE_VERSIONING=true`         | スキップ                      | `rclone copy`（クラウド側を削除しない） | Google Drive |

### Drive側バージョン履歴の仕様

- **最大100バージョン**を保持（Googleの仕様）
- 同名ファイルをアップロードするたびにバージョンが積み上がる
- Drive の容量上限に達すると古いバージョンが自動削除される
- バージョン一覧の確認・ダウンロードは Google Drive の Web UIから可能

### 設定例

```bash
# config.env
STORAGE_BACKEND=gworkspace
GWORKSPACE_REMOTE_NAME=gworkspace
GWORKSPACE_DRIVE_ID=xxxxxxxxxxxxxxxxx   # 共有ドライブのID
USE_SERVICE_VERSIONING=true
```

### 注意点

- `USE_SERVICE_VERSIONING=true` の場合、Drive 側の世代は Drive 容量を消費します
- コスト試算ツール（cost_calculator.html）では「Drive世代管理」が有効な場合、ストレージを **最新1世代 × 1.2** で近似計算します
- Drive側からのリストアは `restore.sh list` で `REMOTE:` プレフィックスのエントリとして表示されます

---

## PITRについて（バイナリログ）

バイナリログを有効にすることで、最後のフルバックアップ以降の変更も復元可能になります。

`/etc/mysql/mysql.conf.d/mysqld.cnf` に追記：

```ini
[mysqld]
log_bin = /var/log/mysql/mysql-bin.log
expire_logs_days = 7
binlog_format = ROW
```

---

## 運用上の注意点

1. **定期的なリストアテスト**  
   月1回程度、ステージング環境で実際にリストアを試してください。バックアップは「戻せて初めて意味がある」ため。

2. **config.env のセキュリティ**  
   DBパスワードやAPIキーが含まれるため、適切にパーミッションを設定してください。
   ```bash
   chmod 600 config.env
   ```

3. **ログの確認**
   ```bash
   tail -f /var/log/backup/mysql.log
   tail -f /var/log/backup/files.log
   tail -f /var/log/backup/sync.log
   ```

4. **複数環境の管理**  
   環境ごとに `config.env` を作り分けて管理できます：
   ```bash
   bash setup.sh /path/to/config_production.env
   bash setup.sh /path/to/config_staging.env
   ```
