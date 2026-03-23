# zengin-pl-api

`zengin-pl-api` は、[`zengin-pl`](https://github.com/sironekotoro/zengin-pl) を利用して、全銀コード（金融機関コード・支店コード）データを **Web API** として提供するための Perl アプリケーションです。

銀行コード・支店コードによる参照だけでなく、銀行名・支店名による検索にも対応することを想定しています。
また、将来的には Slack Slash コマンドの入口もこのアプリケーションに同居させる予定です。

## 目的

このリポジトリの主な目的は、`zengin-pl` を中核ライブラリとして利用しつつ、次のような入口を提供することです。

- Web API
- ターミナルからの `curl` 利用
- 将来的な Slack Slash コマンド連携

`zengin-pl` 自体はデータ取得・検索ロジックを担い、`zengin-pl-api` はその上に載る **薄いアダプタ層** として設計します。

## 設計方針

責務は次のように分離します。

### `zengin-pl`
- 全銀データの取得
- 銀行・支店情報の検索
- 銀行コード・支店コードによる参照

### `zengin-pl-api`
- HTTP リクエスト受付
- 入力パラメータの解釈
- `zengin-pl` の呼び出し
- JSON レスポンスの返却
- 将来的な Slack 向け整形レスポンス

`zengin-pl-api` の既定 backend は、`zengin-pl` 側の正式公開名である `Zengin::Pl` を前提とします。
`Zengin::Client` は後方互換名として扱います。

## スコープ

まずは最小構成として、以下の API を提供することを目指します。

- `GET /api/meta`
- `GET /api/banks/:bank_code`
- `GET /api/banks?name=...`
- `GET /api/banks/:bank_code/branches/:branch_code`
- `GET /api/banks/:bank_code/branches?name=...`

将来的には、以下の endpoint も追加予定です。

- `POST /slack/zengin`

## レスポンス方針

### Web API
- JSON を返す

### Slack
- Slack に見やすい整形済みテキストを返す

## レスポンス例

### メタ情報確認

`GET /api/meta`

```json
{
  "api": {
    "name": "zengin-pl-api",
    "version": null,
    "git_sha": null,
    "build_time": null
  },
  "backend": {
    "class": "Zengin::Pl",
    "version": "0.01",
    "base_url": "https://raw.githubusercontent.com/sironekotoro/zengin-data-mirror/main/data"
  },
  "data": {
    "source": {
      "kind": "zengin-data-mirror",
      "revision": null,
      "updated_at": null
    }
  }
}
```

### 銀行コード検索

`GET /api/banks/0001`

```json
{
  "bank": {
    "code": "0001",
    "name": "みずほ",
    "hira": "みずほ",
    "kana": "ミズホ",
    "roma": "mizuho"
  }
}
```

### 銀行名検索

`GET /api/banks?name=みずほ`

```json
{
  "banks": [
    {
      "code": "0001",
      "name": "みずほ",
      "hira": "みずほ",
      "kana": "ミズホ",
      "roma": "mizuho"
    }
  ]
}
```

### 支店コード検索

`GET /api/banks/0001/branches/001`

```json
{
  "bank": {
    "code": "0001",
    "name": "みずほ"
  },
  "branch": {
    "code": "001",
    "name": "東京営業部",
    "hira": "とうきよう",
    "kana": "トウキヨウ",
    "roma": "toukiyou"
  }
}
```

### 支店名検索

`GET /api/banks/0001/branches?name=東京`

```json
{
  "bank": {
    "code": "0001",
    "name": "みずほ"
  },
  "branches": [
    {
      "code": "001",
      "name": "東京営業部"
    },
    {
      "code": "078",
      "name": "東京法人営業部"
    }
  ]
}
```

## 予定する Slash コマンド仕様

将来的には、Slack から次のような入力を受け付ける想定です。

```text
/zengin みずほ
/zengin 0001
/zengin 0001 001
/zengin みずほ 001
/zengin 0001 東京
/zengin みずほ 東京
```

解釈ルールは以下を想定しています。

- 1引数: 銀行検索
- 2引数かつ第2引数が3桁数字: 支店コード検索
- 2引数かつ第2引数が文字列: 支店名検索

## 実装方針

このリポジトリでは、最初から複雑な仕組みは入れません。

### 最初は入れないもの
- DB
- 永続キャッシュ
- 管理画面
- 複雑な認証認可
- Web UI

### まず入れるもの
- 最小限の Web API
- テスト
- Docker 化
- Cloud Run などへのデプロイ前提の構成

## 想定ディレクトリ構成

```text
zengin-pl-api/
├── README.md
├── cpanfile
├── Dockerfile
├── .dockerignore
├── .gitignore
├── app.psgi
├── lib/
│   └── Zengin/
│       └── PL/
│           └── API.pm
├── t/
│   ├── 01_compile.t
│   ├── 02_api.t
│   └── 03_slack.t
├── config/
│   └── example.env
└── .github/
    └── workflows/
        └── test.yml
```

## 開発の進め方

### フェーズ1
- リポジトリ作成
- README 作成
- `cpanfile` 作成
- `app.psgi` 作成
- 銀行系 API 実装

## ローカル起動の最小手順

`zengin-pl` を別途利用可能な状態にしたうえで、最小構成の API を起動できます。

```bash
cpanm --installdeps .
cpanm ../zengin-pl
plackup -Ilib app.psgi
```

`zengin-pl` を隣接 checkout で参照する場合は、`config/example.env` を参考に `PERL5LIB` を設定してください。

アプリケーションは `PORT` 環境変数で待受ポートを受け取り、コンテナ内では `0.0.0.0` で listen する前提です。

Docker で確認する場合は、デフォルトでは `zengin-pl` を Git URL から取得するため、sibling checkout は不要です。

```bash
docker build -t zengin-pl-api:dev .
docker run --rm -p 8080:8080 -e PORT=8080 zengin-pl-api:dev
```

`Dockerfile` では以下の build arg を使えます。

```bash
docker build \
  --build-arg ZENGIN_PL_GIT_URL=https://github.com/sironekotoro/zengin-pl.git \
  --build-arg ZENGIN_PL_GIT_REF=master \
  -t zengin-pl-api:dev .
```

`ZENGIN_PL_GIT_REF` は省略可能です。省略した場合は、リモートリポジトリのデフォルトブランチを使います。

Docker build 中の `zengin-pl` は、GitHub clone 後に `cpanm --installdeps` と `cpanm` で標準的に install しています。

ローカルでの開発中に sibling checkout を使いたい場合は、Docker build ではなく通常起動で `PERL5LIB=../zengin-pl/lib` を渡す運用を想定しています。

### Docker での疎通確認例

```bash
curl http://127.0.0.1:8080/api/meta
curl http://127.0.0.1:8080/api/banks/0001
curl "http://127.0.0.1:8080/api/banks?name=みずほ"
curl http://127.0.0.1:8080/api/banks/0001/branches/001
curl "http://127.0.0.1:8080/api/banks/0001/branches?name=東京"
```

### フェーズ2
- 支店系 API 実装
- エラーレスポンス整理
- API テスト追加

### フェーズ3
- Slack endpoint 実装
- Slack 署名検証
- Slack 向け出力整形

## デプロイ方針

Perl をそのまま活かすため、Docker 化したうえで Cloud Run などのコンテナ実行環境に載せることを想定しています。

## Cloud Run デプロイ手順

初めて Cloud Run を使う場合は、まずローカル Docker で起動確認してから deploy するのが分かりやすいです。

### 事前に必要なもの

- Google アカウント
- Google Cloud プロジェクト
- Billing の有効化
- `gcloud` CLI

あわせて、次の API を有効化しておきます。

- Cloud Run API
- Artifact Registry API
- Cloud Build API

GitHub Actions から自動 deploy する場合は、これに加えて GitHub と Google Cloud の認証設定が必要です。

例:

```bash
gcloud auth login
gcloud config set project your-gcp-project
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
```

### 1. まずはローカル Docker で確認する

```bash
docker build -t zengin-pl-api:dev .
docker run --rm -p 8080:8080 -e PORT=8080 zengin-pl-api:dev
```

疎通確認:

```bash
curl http://localhost:8080/api/meta
curl http://localhost:8080/api/banks/0001
curl "http://localhost:8080/api/banks?name=みずほ"
curl http://localhost:8080/api/banks/0001/branches/001
curl "http://localhost:8080/api/banks/0001/branches?name=東京"
```

### 2. Artifact Registry を用意する

`gcloud` の初期設定後、次のように image の保存先を作成します。

```bash
export PROJECT_ID='your-gcp-project'
export REGION='asia-northeast1'
export REPOSITORY='zengin-pl-api'
export IMAGE="asia-northeast1-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/zengin-pl-api:latest"
export SERVICE='zengin-pl-api'

gcloud config set project "${PROJECT_ID}"

gcloud artifacts repositories create "${REPOSITORY}" \
  --repository-format=docker \
  --location="${REGION}"
```

すでに repository を作成済みなら、この手順は不要です。

### 3. Cloud Build で image を build する

```bash
gcloud builds submit --tag "${IMAGE}"
```

### 4. Cloud Run に deploy する

```bash
gcloud run deploy "${SERVICE}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --platform managed \
  --allow-unauthenticated
```

`--allow-unauthenticated` を付けるのは、この API をブラウザや `curl` からそのまま確認しやすくするためです。
将来的に公開範囲を制限したい場合は、この設定は見直してください。

Cloud Run では `PORT` 環境変数が自動で注入され、このコンテナはその値で `0.0.0.0` に bind する前提です。

## GitHub Actions による自動デプロイ

このリポジトリでは、[deploy workflow](/Users/sironekotoro/SynologyDrive/github/zengin-pl-api/.github/workflows/deploy.yml) により `main` への push で Cloud Run へ自動 deploy する想定です。

流れ:

1. `prove -lr t` を実行
2. Docker image を build
3. Artifact Registry へ push
4. Cloud Run へ deploy

### GitHub 側で必要な設定

WIF を使う前提では、GitHub repository の `Variables` に次を設定します。

- `WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`

この workflow では次の固定値を使います。

- project id: `zengin-pl-api`
- region: `asia-northeast1`
- Artifact Registry repository: `zengin-pl-api`
- Cloud Run service: `zengin-pl-api`

認証は `google-github-actions/auth@v3` と `google-github-actions/deploy-cloudrun@v3` を使います。

### Google Cloud 側で必要な設定

- Workload Identity Federation の provider 作成
- GitHub Actions から利用する service account 作成
- その service account に Cloud Run / Artifact Registry への deploy 権限を付与

最低でも次の権限を持つ service account を用意してください。

- Cloud Run Admin
- Artifact Registry Writer
- Service Account User

WIF の値は Google Cloud 側で作成した provider と service account の値を、そのまま GitHub Variables へ設定します。

### 暫定で Service Account Key JSON を使う場合

まずは WIF を推奨しますが、暫定で試すだけなら Service Account Key JSON を GitHub Secrets に保存して `google-github-actions/auth` の `credentials_json` を使う運用も可能です。
ただし、長期運用では WIF に寄せる方が安全です。

### /api/meta に反映される build 情報

deploy workflow では Cloud Run に次の環境変数を渡します。

- `APP_NAME=zengin-pl-api`
- `APP_VERSION=${{ github.ref_name }}`
- `APP_GIT_SHA=${{ github.sha }}`
- `APP_BUILD_TIME=<workflow 実行時刻 UTC>`

そのため、`/api/meta` で deploy 済み revision の Git SHA や build 時刻を確認できます。

### 5. デプロイ後に URL で確認する

deploy 後に表示される URL を控え、`curl` で API を確認します。

```bash
export SERVICE_URL="$(gcloud run services describe "${SERVICE}" --region "${REGION}" --format='value(status.url)')"

curl https://<cloud-run-url>/api/meta
curl "${SERVICE_URL}/api/meta"
curl "https://<cloud-run-url>/api/banks/0001"
curl "${SERVICE_URL}/api/banks/0001"
curl "${SERVICE_URL}/api/banks/0001/branches/001"
curl --get --data-urlencode "name=みずほ" \
  "${SERVICE_URL}/api/banks"
curl --get --data-urlencode "name=東京" \
  "${SERVICE_URL}/api/banks/0001/branches"
```

日本語を含む query parameter は、公開 URL に対してそのまま埋め込むのではなく URL エンコードして渡すのが安全です。
銀行名検索や支店名検索では、`curl --get --data-urlencode` を使う方法を推奨します。

```bash
curl --get --data-urlencode "name=みずほ" \
  "https://<cloud-run-url>/api/banks"

curl --get --data-urlencode "name=東京" \
  "https://<cloud-run-url>/api/banks/0001/branches"
```

直接 URL を書く場合は、`%E3...` のような URL エンコード済み文字列を使います。

```bash
curl "https://<cloud-run-url>/api/banks?name=%E3%81%BF%E3%81%9A%E3%81%BB"
curl "https://<cloud-run-url>/api/banks/0001/branches?name=%E6%9D%B1%E4%BA%AC"
```

この公開 URL は、将来 Slack endpoint を追加したときの Request URL 候補にもなります。

`/api/meta` では、`api.*` は `zengin-pl-api` 自身の情報を返し、`backend.*` と `data.source` は backend の `meta()` を取り込んで返します。
`data.source` は、今後 `revision` や `updated_at` などを拡張しやすいようにオブジェクトで返しています。

### 課金を抑えるための最小メモ

- Cloud Run は未使用時にスケールゼロできる
- `min instances` は 0 のままにする
- Artifact Registry の image 保存にも課金が発生しうる
- 不要になった Cloud Run service と Artifact Registry の image は削除する
- 検証用の tag を増やしすぎない

## ライセンス

MIT License

## 作者

[@sironekotoro](https://github.com/sironekotoro)
