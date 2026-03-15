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
│   ├── test_notify.sh      通知テスト用スクリプト（新規）
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
| `SERVICE_NAME`                                | サービス名（英数字、ハイフン、アンダースコア）                 |
| `ENVIRONMENT`                                 | 環境名（production / staging / development） |
| `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASS` | MySQL接続情報                               |
| `APP_DIR`                                     | Laravelアプリのルートパス                        |
| `STORAGE_BACKEND`                             | バックアップ先ストレージ (s3/wasabi/sakura/idrive/local) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | AWS S3 / S3 互換ストレージの認証情報           |
| `STORAGE_BUCKET`                              | ストレージのバケット名                    |
| `S3_ENDPOINT_URL`                             | S3 互換ストレージのエンドポイント (任意)        |
| `WEBHOOK_URL`                                 | Slack/Mattermost 通知用 Webhook            |
| `SENDGRID_API_KEY`                            | SendGrid API キー（メール用）                   |
| `TEST_DB_NAME`                                | テスト用DB名（リストア検証用）                        |
| `MASK_SQL_FILE`                               | マスク用SQLファイルのパス（任意）                      |
| `RESTORE_STOP_SERVICES`                       | リストア時に停止・起動するサービス（任意）                   |

### 2. インストールとスケジュール登録

```bash
sudo bash setup.sh
```

すでに `config.env` を作成済みの場合は、その内容に基づいて以下の処理が行われます：

- 依存パッケージのチェック（mysqldump, gzip, tar, curl）
- aws-cli のチェック（未インストールの場合の案内）
- バックアップ・ログディレクトリの作成
- Cron ジョブの設定（`/etc/cron.d/backup-{サービス名}-{環境名}`）
- テスト用データベースの権限設定案内

### 3. 動作テスト

```bash
# 各スクリプトを手動実行してエラーがないか確認
bash scripts/backup_mysql.sh config.env
bash scripts/backup_files.sh config.env
bash scripts/backup_sync.sh config.env

# 通知テスト
bash scripts/test_notify.sh config.env

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
- **サービス制御**: `RESTORE_STOP_SERVICES` に指定したサービス（例: `nginx`, `php-fpm`
  ）をリストア開始前に停止し、完了後に自動起動します。不整合の防止や安全な切り替えが可能です。

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

コスト優先なら **Wasabi** や **IDrive e2**、国内保管なら **さくらのオブジェクトストレージ** が有力候補です。
詳細な費用試算は `cost_calculator.html` をブラウザで開いてください。

---

### Wasabi

**設定値:** `STORAGE_BACKEND=wasabi`

| 項目     | 内容                                        |
|--------|-------------------------------------------|
| 保管コスト  | $0.0069/GB/月（約¥1.0/GB）                    |
| アップロード | 無料                                        |
| ダウンロード | **無料**（回数・容量制限なし）                         |
| 公式URL  | https://wasabi.com/cloud-storage-pricing/ |

**特徴:** ダウンロードが完全無料なため、リストアテストを頻繁に行う場合や大容量のリストアが想定される場合に有利。ただし **90日最低保管ポリシー** があり、90日未満で削除したファイルも90日分の料金が発生するため、頻繁に世代削除する運用では割高になる可能性あり。
S3 互換エンドポイント（例: `https://s3.ap-northeast-1.wasabisys.com`）を `S3_ENDPOINT_URL` に設定して使用します。

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
公式 CLI (`aws s3`) を直接使用します。

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
S3 互換エンドポイントを `S3_ENDPOINT_URL` に設定して使用します。

---

### さくらのオブジェクトストレージ

**設定値:** `STORAGE_BACKEND=sakura`

| 項目     | 内容                                                       |
|--------|----------------------------------------------------------|
| 保管コスト  | ¥2.2/GB/月                                                |
| アップロード | 無料                                                       |
| ダウンロード | ¥20/GB                                                   |
| 公式URL  | https://cloud.sakura.ad.jp/specification/object-storage/ |

**特徴:** 国内データセンター（大阪/石狩）でのデータ保管。**円建てのため為替リスクがゼロ**。個人情報や機密データを国外に出したくない要件に適している。S3互換APIあり。
エンドポイント（`https://s3.isk01.sakurastorage.jp`）を `S3_ENDPOINT_URL` に設定して使用します。

---

## Docker 環境での Cron 利用

多くの PHP Docker イメージ（`php:8.x-fpm` など）にはデフォルトで cron がインストールされておらず、`/etc/cron.d`
も存在しません。Docker 環境でバックアップを自動実行するには、以下のいずれかの方法を推奨します。

### 方法 1: ホスト側の Cron を利用する（推奨）

ホストマシン（Ubuntu等）の cron から `docker exec` を介してスクリプトを実行します。これが最も管理しやすく確実です。

`/etc/cron.d/backup-myapp` (ホスト側) の例:

```bash
# MySQL バックアップ
0 2 * * * root docker exec -t php /var/www/scripts/backup_mysql.sh /var/www/config.env
# ファイル バックアップ
0 3 * * * root docker exec -t php /var/www/scripts/backup_files.sh /var/www/config.env
# クラウド 同期
0 4 * * * root docker exec -t php /var/www/scripts/backup_sync.sh /var/www/config.env
```

### 方法 2: 別途 Cron コンテナを用意する

バックアップ実行専用のコンテナ（例: `apt install cron` 済みの Debian イメージ）を用意し、そこから実行します。

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

# なし

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

## トラブルシューティング

### TLS/SSL エラー (ERROR 2026)

MySQL/MariaDB への接続時に以下のエラーが発生する場合があります：

```text
ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain
```

これは、サーバー側の証明書が自己署名である場合や、クライアント側で正しく検証できない場合に発生します。
信頼できるネットワーク内であれば、SSLを無効化することで回避できます。

#### 推奨される対応策

`~/.my.cnf`（実行ユーザーのホームディレクトリ）に以下の設定を追記してください。
**MySQL または MariaDB のバージョンにより書き方が異なるので注意してください。**

**MySQL 5.7 / 8.0+ の場合:**

```ini
[client]
ssl-mode=DISABLED
```

**MariaDB の場合:**

```ini
[client]
ssl=0
```

設定後、再度バックアップスクリプト等を実行してエラーが解消されるか確認してください。

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
