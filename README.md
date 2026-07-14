# Claude Code Observability Stack (個人ローカル用 / チーム展開可)

<img width="1917" height="910" alt="スクリーンショット 2026-07-08 100009" src="https://github.com/user-attachments/assets/793f2039-28e2-4635-9b99-078f54a985ef" />


> **注記**: これは個人が趣味で構築した非公式のツールです。Anthropic 公式の製品ではありません。

Claude Code / ECC (Everything Claude Code) の利用状況を、自分の PC 上の Grafana で可視化するためのスタックです。**各自が自分のローカルにそのまま構築できる**ように作られています。

## 1. 概要

- **「個人ローカルで動かす」設計**: 1 台のサーバーにチーム全員のデータを集約する構成では**ありません**。各自がこのディレクトリを自分の PC にコピー(または clone)し、自分の Claude Code 利用状況だけを自分のローカルで見る設計です。すべて `localhost` 上で動作し、外部公開は想定していません。
- **メタデータのみ (デフォルト)**: 標準では **プロンプト・レスポンス・ツール出力の中身は一切収集しません**。トークン数・コスト・セッション数などのメタデータのみを扱います。中身のロギングは明示的にオプトインした場合のみ有効になります (「7. プライバシー」参照)。**チームに配布する場合も、このデフォルトは変更しないことを強く推奨します**(オプトインすると自分のプロンプトが平文で Loki に残ります)。
- 既定で構成する 4 サービス:
  - `otel-collector` — Claude Code からの OTLP を受信し、metrics / logs / traces に振り分け
  - `prometheus` — メトリクスの保存・クエリ (保持期間 90 日)
  - `loki` — ログ/イベントの保存・クエリ (生ログは直近確認用として保持期間 7 日で自動削除。長期トレンドは Prometheus 側の数値で見る想定)
  - `grafana` — ダッシュボードでの可視化
- 任意の 5 つ目のサービス (既定では起動しない):
  - `tempo` — トレースの保存・クエリ (保持期間 7 日)。ツール入出力 (ターミナル出力) を残す「トレース取り込み」を使う場合のみ起動する。詳細は「7. プライバシー」参照

### アーキテクチャ

```
Claude Code (WSL host)
      │  OTLP/gRPC  localhost:4317
      ▼
  otel-collector  ──────────┬─────────────────────┐
      │                     │                     │
      │ metrics (:8889)     │ logs                 │ traces (任意)
      ▼                     ▼                     ▼
  Prometheus              Loki                  Tempo  ← profiles:["traces"] で任意起動
      │                     │                     │
      └────────┬────────────┴─────────────────────┘
               ▼
        Grafana (localhost:3001 ※デフォルト値)
```

Claude Code が OTLP/gRPC で `localhost:4317` に push → `otel-collector` が受信 → メトリクスは Prometheus 形式 (`:8889`) で公開し Prometheus がスクレイプ、ログは Loki の OTLP エンドポイントへ転送 → Grafana で可視化します。トレース (任意) は Tempo へ転送しますが、Tempo は既定では起動せず、Claude 側でトレース取り込みを有効にした場合のみ使います。

### ディレクトリ構成

| ファイル | 役割 |
|---|---|
| `docker-compose.yml` | サービス定義 (otel-collector / prometheus / loki / grafana、および任意の tempo)。ポートは `.env` で上書き可能。tempo は `profiles: ["traces"]` で既定では起動しない |
| `.env.example` | ポート設定のテンプレート。`cp .env.example .env` して各自のローカル環境に合わせる |
| `otel-collector-config.yaml` | OTLP 受信 (gRPC 4317 / HTTP 4318)、metrics→Prometheus (`:8889`)、logs→Loki、traces→Tempo。`add_metric_suffixes: false` でメトリクス名に `_total`/単位サフィックスを付けない |
| `prometheus/prometheus.yml` | `otel-collector:8889` をスクレイプ |
| `loki/loki-config.yaml` | Loki 3.x シングルバイナリ構成、OTLP インジェスト有効 |
| `tempo/tempo.yaml` | Tempo 単一バイナリ構成 (任意)。OTLP(gRPC) 受信、ローカル FS 保存、保持 7 日 |
| `grafana/provisioning/**` | データソース (Prometheus + Loki + Tempo) とダッシュボードプロバイダの自動プロビジョニング |
| `grafana/dashboards/claude-code.json` | ダッシュボード定義 (パネルラベルは日本語) |

localhost に公開されるポート (デフォルト値、`.env` で変更可): Grafana `3001`、Prometheus `9090`、Loki `3100`、OTLP `4317`/`4318`。トレースを有効にした場合のみ Tempo `3200` も追加。

## 2. 前提

- Docker Desktop + WSL2 が動作していること。**動作確認はこの構成のみ**です。Docker Desktop を使わない環境 (Colima / Rancher Desktop / ネイティブ Linux の Docker Engine など) では未検証なので、動かない箇所が出たら教えてください。
- 上記ポート (デフォルト `3001` / `9090` / `3100` / `4317` / `4318`) が他プロセスで使われていないこと。競合する場合は次の手順の `.env` で回避してください (Grafana のデフォルトが `3000` ではなく `3001` なのは、他の Web アプリのローカル開発サーバーが `3000` を使うケースが多いための退避です)。

  ```bash
  # 使用中ポートの確認例
  lsof -i :3001 -i :9090 -i :3100 -i :4317 -i :4318
  ```

## 3. セットアップ手順

### a. `.env` を用意する

このディレクトリで:

```bash
cp .env.example .env
# ポートが競合する場合はここで値を編集
```

### b. スタックを起動

```bash
docker compose up -d
```

### c. Claude Code のテレメトリを有効化

`~/.claude/settings.json` の `env` キー配下に以下を追加します。

```json
"CLAUDE_CODE_ENABLE_TELEMETRY": "1",
"OTEL_METRICS_EXPORTER": "otlp",
"OTEL_LOGS_EXPORTER": "otlp",
"OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
"OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
"OTEL_METRIC_EXPORT_INTERVAL": "10000",
"OTEL_LOGS_EXPORT_INTERVAL": "5000"
```

> `.env` で `OTLP_GRPC_PORT` を `4317` から変更した場合は、`OTEL_EXPORTER_OTLP_ENDPOINT` もそのポートに合わせてください。

`settings.json` 全体では以下のような形になります (既存の設定に `env` が無い場合の例):

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000"
  }
}
```

**既存の `settings.json` を壊さずマージしたい場合**は `jq` で追記できます (バックアップを取ってから実行してください):

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
jq '.env = ((.env // {}) + {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
  "OTEL_METRIC_EXPORT_INTERVAL": "10000",
  "OTEL_LOGS_EXPORT_INTERVAL": "5000"
})' ~/.claude/settings.json > /tmp/cc-settings.json && mv /tmp/cc-settings.json ~/.claude/settings.json
```

> **注意**: `env` の変更は **次回の Claude Code セッションから** 有効になります。反映させるには `claude` を再起動してください。
> プロジェクト側に `.claude/settings.json` があるとユーザー設定を上書きすることがあります。テレメトリが流れてこない場合は、開いているプロジェクトの `.claude/settings.json` / `.claude/settings.local.json` に矛盾する `env` 設定が無いか確認してください。

### d. Grafana を開く

ブラウザで <http://localhost:3001> (デフォルト値。`.env` で変更していればそのポート) を開きます。匿名 Admin (ログイン不要) で入れます。ダッシュボードは自動プロビジョニング済みです。

## 4. 動作確認

1. 全サービスが起動していることを確認:

   ```bash
   docker compose ps
   ```

   すべて `running` (ヘルスチェック対象は `healthy`) であること。

2. Claude Code を再起動し、何かセッションを 1 回実行する (メッセージを送る・ファイルを編集するなど)。

3. Prometheus のスクレイプ対象が `up` になっているか確認: <http://localhost:9090> (`.env` のポートに応じて読み替え) の `/targets`

4. メトリクスが取れているか確認:

   ```bash
   curl -s "http://localhost:9090/api/v1/query?query=claude_code_session_count"
   ```

   `"result": [ ... ]` にデータが返れば OK。

5. Collector が受信できているか確認:

   ```bash
   docker compose logs otel-collector | grep -i metrics
   ```

## 5. ダッシュボードの見方

Grafana を初めて触る人向けに、最低限これだけ分かれば読めます。

### 開き方

ブラウザで <http://localhost:3001> を開き、左メニューの **Dashboards** → **「Claude Code — 個人利用状況」** を選びます (起動時に自動登録されています)。

- **数字が出ない / 空のとき**: Claude Code を少し使うとデータが溜まります。コミット数・PR 数などのカウンタは、実際にその操作をするまで 0 のままです。

### 画面の基本操作

- **期間の変更 (右上)**: 既定は「直近 7 日」。右上の時間ピッカーで「Last 24 hours」などに変えると、各パネルの数字・グラフがその期間に追従します。ほとんどの数字は「選んだ期間の合計または推移」です。
- **自動更新**: 30 秒ごとに更新されます。右上の更新アイコンで手動更新も可能。
- **グラフの操作**: 線や棒にカーソルを合わせると内訳がツールチップで出ます。時系列グラフは**横方向にドラッグで拡大**、ダブルクリックで元に戻ります。凡例のラベルをクリックすると、その系列だけ表示/非表示を切り替えられます。

### 各セクションの意味

ダッシュボードは上から 4 つのセクションに分かれています。

| セクション | 何が見えるか |
|---|---|
| **概要 (サマリー)** | 上段の数字タイル。選択期間の合計コスト・トークン・セッション・コミット・PR・コード行数・アクティブ時間をひと目で |
| **コスト** | モデル別のコスト推移、スキル別コスト上位 10、スキル/エージェント/プラグイン別の内訳表。※棒に出る `value` は「スキルを介さない通常利用ぶん」の合計で、`value` というスキルがあるわけではありません |
| **トークン** | 入力/出力/キャッシュのトークン推移と、キャッシュ読み込み・入力トークンの合計 |
| **アクティビティ** | セッション数の推移、コード行数・コミット数の推移、コード編集の承認/拒否 |
| **イベント (Loki)** | Claude Code が出す生イベントログを時系列で表示 |

### トレース (ターミナル出力) を見る (任意)

「7. プライバシー」の手順でトレースを有効にした場合は、ダッシュボードではなく左メニューの **Explore** から見ます: データソース **Tempo** を選び、クエリ欄に `{ resource.service.name = "claude-code" }` を入れると、ツール入出力を含むトレースを検索できます。

## 6. メトリクス一覧

`add_metric_suffixes: false` のため、メトリクス名にはサフィックスが付きません。

| メトリクス名 | 内容 |
|---|---|
| `claude_code_session_count` | CLI セッションの開始回数 |
| `claude_code_cost_usage` | 推定コスト (USD)。`model` ラベルなどでモデル別に分解可能 |
| `claude_code_token_usage` | トークン使用量。`type` ラベルで `input` / `output` / `cacheRead` / `cacheCreation` を区別 |
| `claude_code_lines_of_code_count` | 追加/削除された行数 |
| `claude_code_pull_request_count` | 作成された PR 数 |
| `claude_code_commit_count` | 作成されたコミット数 |
| `claude_code_code_edit_tool_decision` | コード編集ツールの承認/拒否の判断回数 |
| `claude_code_active_time_total` | アクティブ利用時間の累計 |

### 主要ラベル

`claude_code_cost_usage` / `claude_code_token_usage` には `model` のほか、`skill_name` / `agent_name` / `plugin_name` といったラベルが付きます。これにより **ECC スキル別・エージェント別・プラグイン別のコスト内訳** を分解できます。

PromQL 例 (スキル別のトークン合計):

```promql
sum by (skill_name) (increase(claude_code_token_usage[1d]))
```

## 7. プライバシー

- **デフォルトはメタデータのみ**。プロンプト・レスポンス・ツール出力の中身は収集・保存されません。
- 中身のロギングは、収集する範囲ごとに別々の環境変数でオプトインします。**それぞれ収集される内容と保存先が異なる**ので、必要な粒度だけ有効にしてください (`~/.claude/settings.json` の `env` に追加):

  | 環境変数 | 追加で残る中身 | 保存先 |
  |---|---|---|
  | `OTEL_LOG_USER_PROMPTS=1` | ユーザープロンプトの本文 (`claude_code.user_prompt` イベント) | **Loki** (logs) |
  | `OTEL_LOG_TOOL_DETAILS=1` | ツールの**入力引数のみ** (実行したシェルコマンド・ファイルパス・検索パターンなど)。ツールの**出力は含みません** | **Loki** (logs) |
  | `OTEL_LOG_TOOL_CONTENT=1` | ツールの入力**および出力**の本文 (Bash の stdout/stderr など、いわゆる「ターミナル出力」)。1 span イベント **60KB で切り詰め** | **Tempo** (traces) — 下記「ターミナル出力をトレースで残す」参照 |

  プロンプト本文だけ残す最小構成なら、これだけ:

  ```json
  "OTEL_LOG_USER_PROMPTS": "1"
  ```

### ターミナル出力をトレースで残す (任意 / beta)

ツールの**出力**(Bash の stdout など) は logs ではなく **traces (span イベント)** として出るため、**Loki ではなく Tempo** に入ります。手順:

1. `~/.claude/settings.json` の `env` に 3 点を追加 (すべて必須):

   ```json
   "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
   "OTEL_TRACES_EXPORTER": "otlp",
   "OTEL_LOG_TOOL_CONTENT": "1"
   ```

2. Tempo を含めてスタックを起動 (`traces` プロファイル):

   ```bash
   docker compose --profile traces up -d
   ```

3. `claude` を再起動 → 何か作業 → Grafana の **Explore → データソース Tempo** で `{ resource.service.name = "claude-code" }` を検索。トレース波形の span イベントにツール入出力が入っています。

> 注意: (a) これは **beta 機能** (`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA`) で挙動が変わりうる。(b) 1 span **60KB 切り詰め**があり、長いビルドログ等は途中で切れる。(c) Loki のログパネルには出ない (トレース側)。(d) Tempo の保持は 7 日。

- **60KB 切り詰めを避けてフル解像度で残したい場合**の別経路: セッションのローカル transcript (`~/.claude/projects/<プロジェクト>/<session-id>.jsonl`。プロンプト・レスポンス・ツール入出力が無切り詰めで append-only 記録される) を otel-collector の filelog receiver で tail して Loki に流す方法があります。Claude 側の追加設定は不要ですが、機密ディレクトリを collector にマウントするため**このリポジトリのデフォルトには含めていません**(必要な人が各自で追加する想定)。

> **警告**: 上記を有効にすると、プロンプト・コマンド・ツール出力 (機密情報を含みうる中身) が Loki / Tempo に平文で保存されます。個人ローカル用途であっても、扱うデータの機微性を理解した上でのみ有効にしてください。不要になったら値を削除し、必要に応じてデータをリセット (「8. 運用」参照) してください。生ログ・トレースの保持期間はそれぞれ 7 日です。
> **配布時は特に注意**: これらのオプトインは配布物のデフォルトに含めない・README のサンプル JSON にも書かないでください。誰かが有効にした状態で `docker compose down -v` せずに環境を人に渡す、といった事故を避けるためです。

## 8. 運用

このディレクトリで実行します。

- 停止 (データは保持):

  ```bash
  docker compose down
  ```

- データも含めて完全リセット (Prometheus / Loki / Grafana のボリュームを削除):

  ```bash
  docker compose down -v
  ```

- ログを追う:

  ```bash
  docker compose logs -f otel-collector
  ```

## 9. トラブルシュート

### Grafana にメトリクスが出ない

1. `env` が反映されているか確認 (settings.json に追記後、`claude` を再起動したか)。
2. ポート `4317` (または `.env` で変更した `OTLP_GRPC_PORT`) に到達できるか確認 (下記のネットワーク注記も参照)。
3. Collector のログを確認:

   ```bash
   docker compose logs otel-collector | grep -i metrics
   ```

4. メトリクスは **10 秒間隔** (`OTEL_METRIC_EXPORT_INTERVAL=10000`) でエクスポートされます。反映まで少し待つこと。また、カウンタ系メトリクス (コミット数・PR 数など) は **対象アクションを実際に完了** しないと値が出ません。

### WSL / Docker Desktop のネットワーク

WSL ホストから公開済みコンテナポートへは `localhost:4317` で到達できるのが通常です。もし到達できない場合は、エンドポイントを `http://127.0.0.1:4317` に変えて試してください (`OTEL_EXPORTER_OTLP_ENDPOINT`)。

### Loki パネルが空、または表示がおかしい

イベント名はログの **本文 (body)** に入ります。実データを観測した上で Loki クエリの調整が必要になる場合があります (ラベルとして分離されない項目は本文からのパースが必要)。

### 設定ファイルを編集したのに反映されない / コンテナが起動しない

Docker Desktop + WSL2 では、バインドマウントしている設定ファイル (例: `prometheus.yml`, `otel-collector-config.yaml`) を **上書き保存すると inode が変わり、古いマウント参照が失効** します。この状態で `docker compose restart` すると次のようなエラーで起動に失敗します:

```
error mounting "..." to rootfs at "/etc/prometheus/prometheus.yml": no such file or directory
```

設定ファイルを編集したら `restart` ではなく **`down` してから `up -d`** し、マウントを作り直してください:

```bash
docker compose down && docker compose up -d
```

### otel-collector が `exec /otelcol-contrib: no such file or directory` で crash-loop する

Collector イメージには **バージョン固有で起動できない不良タグ** が存在します (このスタックでは `0.116.0` が該当。動的リンクなのに linker を含まないベースでビルドされていた)。`docker-compose.yml` の `otel-collector` のイメージタグを、動作確認済みの `0.127.0` (もしくは `latest`) に固定してください (このリポジトリは既に `0.127.0` 固定済み)。

### WSL2 / Docker Desktop を再起動したら Grafana は開けるのに何も映らない

Docker Desktop 自体の再起動やスリープ復帰後、Grafana だけ復帰して otel-collector / prometheus / loki が `Exited(127)` のまま取り残されることがあります。さらに、Grafana の provisioning ディレクトリ (バインドマウント) も同時に失効すると、**Grafana は正常に起動しているのにダッシュボード一覧が空** になります (provisioning がファイルを読めず、`disableDeletion: false` により登録済みダッシュボードが削除されるため)。どちらも原因は上記と同じ「マウント失効」で、`restart` / `start` では古い参照を再利用して直りません。必ずコンテナを作り直してマウントを貼り直します:

```bash
docker compose down && docker compose up -d
```

を実行してください。復旧後、メトリクスは次のエクスポート周期 (~60秒) から流れ始めます。

#### オプション: 復旧を一発化するエイリアス `cco-up`

Windows の Modern Standby などスリープ/復帰の多い環境では、上記の「マウント失効」は**ほぼ毎朝発生**します。同梱の `scripts/cco-up.sh` は `down → up -d` でマウントを貼り直したうえで、コンテナ状態・Grafana ヘルスに加えて **ダッシュボードが実際に登録されたか** まで検証します (「コンテナは起動しているのにダッシュボードは空」という取りこぼしを防ぐため)。

`~/.bashrc` にエイリアスを登録すると、復旧が `cco-up` の一言で済みます:

```bash
echo "alias cco-up='bash ~/claude-code-observability/scripts/cco-up.sh'" >> ~/.bashrc
source ~/.bashrc
```

- `cco-up` — コアスタックを復旧・検証
- `cco-up --traces` — Tempo (`traces` プロファイル) も含めて起動

**このエイリアスで解決すること**: スリープ復帰によるマウント失効で起きる「① バックエンドが `Exited(127)` になる」「② Grafana のダッシュボードが消える」の両方を、1コマンドで復旧し、ダッシュボードの再表示まで検証する。

## 10. 既知の制約

他の人に渡す・別環境で動かす前に、以下は認識しておいてください。

- **これは「各自ローカルで動かす」ツールで、チーム全体のコストを1箇所に集約するダッシュボードではありません。** 複数人の利用状況を横断的に見たい場合は、各利用者のローカルから中央のコレクター/Prometheus にリモート push する構成、認証、テナント分離(誰のデータか区別するラベル)などを別途設計する必要があります。現行構成をそのまま複数人で1台に相乗りさせるのはおすすめしません (下記の匿名 Admin の理由もあります)。
- **Grafana は匿名 Admin ログイン**です。個人が `localhost` だけで使う前提だからこそ許容できる設定であり、共有サーバーに載せる・ネットワークに公開する用途には**そのまま使わないでください**。認証を有効化する設計変更が必要です。
- **動作確認環境が Docker Desktop + WSL2 のみ**です。Mac (Docker Desktop for Mac) やネイティブ Linux での動作は未検証です。Issue や PR で動作報告・修正を歓迎します。
- **`OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` のオプトイン設定**は、README のサンプルや配布物のデフォルトに含めないでください。有効化するとプロンプトが平文で Loki に残ります (「7. プライバシー」参照)。
- **settings.json の手動編集は事故りやすい**箇所です。JSON の構文ミスで Claude Code が起動しなくなるケースがあるため、上記の `jq` スニペットの利用、またはセットアップスクリプト化を検討してください。
- **Prometheus (90日) と Loki (7日) で保持期間が異なります。** 長期トレンドが要るメトリクスは長めに、直近確認用途の生ログは短めに、という意図的な設計です。ディスク使用量が気になる場合は `prometheus/prometheus.yml` の `--storage.tsdb.retention.time` と `loki/loki-config.yaml` の `retention_period` を調整してください。
