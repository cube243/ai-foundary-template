# 実装指示書: AI基盤IaCテンプレート群 — RAG用ベクトルDBパターンの追加

## 0. このドキュメントについて

これはAWS上でLLMバックエンドを動かすためのIaCテンプレート群について、複数回にわたる設計議論の結果をまとめたものです。あなたには2つの作業をお願いします。

1. **実装**: 本ドキュメントの仕様に沿って `templates/rag-vector-db-bedrock-kb` を新規実装する
2. **ADR化**: 本ドキュメント中の「なぜそう決めたか」という判断を、`docs/adr/` 配下にArchitecture Decision Recordとして記録する(詳細は末尾の「9. ADR作成指示」を参照)

実装を進める中で本ドキュメントに書かれていない判断が必要になった場合は、一度立ち止まって質問してください。憶測で進めないでください。

---

## 1. 前提となるリポジトリ構成

これは cookiecutter で1フォルダずつ配布する形式のテンプレート集です。

```
templates/
  single-agent/     (既存)
  tool-agent/        (既存)
  rag-vector-db-bedrock-kb/   ← 今回新規作成する対象
```

**最重要の制約**: 各 `templates/*` フォルダは、**他のどの `templates/*` フォルダも参照・import してはいけません**。利用者は1フォルダだけを独立してコピーしてくる前提のため、フォルダ間の `module` 参照や共有ライブラリへの依存は一切禁止です。共通の関心事(認証・ガードレール・モニタリング)であっても、各フォルダに実装を重複させてでも自己完結させてください。これは意図的な設計判断であり、後から「共通化」する必要はありません。

RAG機能は「1つの結合されたテンプレート」としては提供しません。利用者は `templates/tool-agent` と `templates/rag-vector-db-bedrock-kb` を**別々に** cookiecutter し、後から `templates/rag-vector-db-bedrock-kb` が出力する `query_document` LambdaのARNを、AgentCore Gatewayにツールとしてアタッチすることで組み合わせます。この組み合わせ方を `templates/rag-vector-db-bedrock-kb/README.md` に明記してください。

---

## 2. 全体アーキテクチャ原則(今回・今後共通で従うこと)

- テンプレートフォルダは完全独立、依存ゼロ
- 「その機能を持つかどうか」はテンプレート側が強制する(選択肢を残さない)。「具体的な数値やポリシー」だけを `variables.tf` で外出しする
- バックエンド差し替えのための共通インターフェース強制(Port層・契約テストのようなコードレベルの仕組み)は**採用しない**。理由は「6.5」を参照。関数名や引数の緩やかな命名一貫性のみで十分とする
- `tenant_id` は**いかなる場合もLLM/呼び出し元が指定できる値にしてはならない**。認証で検証済みの値をコード側で強制的に注入する

---

## 3. 実装対象: `templates/rag-vector-db-bedrock-kb`

### 3.1 採用するベクトルDBバックエンド

**Amazon Bedrock Knowledge Bases、データソースタイプ `CUSTOM`、Direct Ingestion API** を使用する。

理由: チャンク分割・埋め込み生成・ベクトル格納をBedrock側に任せられ、`IngestKnowledgeBaseDocuments` / `DeleteKnowledgeBaseDocuments` / `Retrieve` / `GetKnowledgeBaseDocuments` のAPIで、自前でOpenSearch/pgvectorを構築するより少ない実装量でCRUDが揃う。

裏側の実ベクトルストア(OpenSearch Serverless / Aurora pgvector / S3 Vectors等)は `variables.tf` で選択可能にしてよいが、デフォルトは実装コストが低いものを選んでよい。

### 3.2 実装するLambda関数(6本)

| 関数名 | 役割 | 呼び出す Bedrock API | 公開方法 |
|---|---|---|---|
| `add_document` | 文書追加 | `IngestKnowledgeBaseDocuments` | API Gateway(認証必須) |
| `update_document` | 文書更新(同一document_idでupsert) | `IngestKnowledgeBaseDocuments` | API Gateway(認証必須) |
| `delete_document` | 文書単体削除 | `DeleteKnowledgeBaseDocuments` | API Gateway(認証必須) |
| `get_document_status` | 文書の状態確認 | `GetKnowledgeBaseDocuments` | API Gateway(認証必須) |
| `query_document` | 検索(RAGのコア) | `Retrieve` | **API Gateway化しない**。Lambda ARNのみをTerraform outputとして出力し、後からAgentCore Gatewayにアタッチする前提とする |
| `purge_tenant` | テナット丸ごと削除(退会時) | `DeleteKnowledgeBaseDocuments` をループ | API Gateway(管理者権限が必要な認証を要求) |

#### `query_document` の入出力契約(最重要)

```json
// 入力(LLMがツールとして呼ぶ引数。これ以外のフィールドを追加しないこと)
{ "query": "string", "top_k": 5 }

// 出力
{ "results": [ { "text": "string", "score": 0.0, "source_uri": "string", "document_id": "string" } ] }
```

`tenant_id` を入力スキーマに**絶対に含めないこと**。Lambda内部で、呼び出しコンテキスト(後述の認証コンテキストから伝播された値)から取得し、Bedrock `Retrieve` の `filter` に `{"equals": {"key": "tenant_id", "value": <context由来の値>}}` として機械的に組み込むこと。

#### `purge_tenant` の入出力契約

一括削除はBedrock側にネイティブAPIが無く、`DeleteKnowledgeBaseDocuments` をループで呼ぶ実装になるため、**同期完了を約束しない非同期契約**にすること。

```json
// リクエスト
{ "tenant_id": "string" }
// レスポンス(即座に返す。完了を待たない)
{ "status": "PURGE_QUEUED", "job_id": "string" }
```

内部実装は素朴なループでよいが、アカウント全体の同時実行数上限(後述)を守ること。

### 3.3 ドキュメントのメタデータスキーマ

各文書には、本文とは別に以下をfilterable metadataとして持たせること。

```json
{
  "tenant_id": "string",          // 必須。検索時に強制フィルタする
  "access_tags": ["public"],       // 将来のAIレディデータ基盤との連携用プレースホルダ。
                                     // 現時点では常に ["public"] 固定でよいが、
                                     // フィールド自体は必ず存在させること(破壊的変更回避のため)
  "document_id": "string",
  "source_uri": "string",
  "updated_at": "ISO8601 string"
}
```

### 3.4 テナント分離方式

デフォルトは**プール型**(1つのKnowledge Baseを全テナントで共有し、`tenant_id` メタデータでフィルタする)。テナントごとに個別のKnowledge Baseを作る「サイロ型」はデフォルトでは実装しないが、`variables.tf` のコメントに「大口顧客の契約上の要求、または性能分離が必要な場合はサイロ型への切り替えを検討」という趣旨のコメントを残すこと。

### 3.5 テナント単位のレート制限(必須機能)

Bedrock Knowledge Basesには以下のアカウント/リージョン単位の制約があることを踏まえ、1テナントが枠を独占して他テナントに影響を与えないよう、**API Gateway の Usage Plan(またはそれに準ずるテナント単位のスロットリング)を必ず実装すること**。

- `IngestKnowledgeBaseDocuments` / `DeleteKnowledgeBaseDocuments` の同時実行数はアカウント全体で合計10件までという制約がある
- `GetKnowledgeBaseDocuments` 等の検索系APIにもアカウント/リージョン単位のTPS上限がある(要Service Quotasでの確認・引き上げ申請)

これは「機能として実装するかどうか」は選択の余地なく実装し、具体的な上限値のみ `variables.tf` で変数化すること(例: `tenant_rate_limit_rps`)。

### 3.6 add/update/delete の非同期化(必須)

`add_document` / `update_document` / `delete_document` は、API Gateway → SQS → Lambda(予約同時実行数で制限)という構成にし、Bedrock側の同時実行10件の制約に直接晒さないこと。失敗時のDLQも用意すること。呼び出し元には即座に `{"document_id": "...", "status": "QUEUED"}` を返し、状態確認は `get_document_status` で行う設計とする。

### 3.7 認証・テナントコンテキスト

- 現状はAmazon Cognito User Poolを認証基盤として使う(将来的に社内の別IdPに置き換わる想定)
- API Gatewayには**組み込みのJWT Authorizer**を使う(カスタムのLambda Authorizerは今回不要と判断)
- ただし、CognitoのJWTクレーム名(`custom:tenant_id` 等)をコードの随所で直接参照せず、**認証情報を正規化する共通ヘルパー関数を1箇所だけ**用意し、以降の全Lambdaはそのヘルパーが返す `{tenant_id, user_id, roles}` という正規化済みの形だけを参照すること。これにより、将来Cognitoから別IdPに切り替える際の変更箇所を1ファイルに閉じ込める

### 3.8 モニタリング・ログ

以下のフィールドを持つ構造化ログ(JSON、1行1リクエスト)を全Lambdaが出力すること。

```json
{
  "tenant_id": "string",
  "user_id": "string",
  "operation": "add|update|delete|query|get_status|purge_tenant",
  "latency_ms": 0.0,
  "error": false,
  "result_count": 0,          // queryの場合のみ
  "timestamp": "ISO8601"
}
```

コストの集計はBedrock Model Invocation Logging(requestMetadata)経由でS3+Glue+Athenaへ、レイテンシ・エラー率の分析はCloudWatch Logs Insightsで行う想定(このテンプレート単体では、ログを正しい形で出すところまでを実装範囲とし、Athena/Glueのリソース自体は共通モニタリング基盤側の責務とする。もしこのテンプレート単体で完結させる必要があれば、その旨質問すること)。

Bedrockのスロットリング(`AWS/Bedrock` namespaceの `InvocationThrottles` 等)を検知するCloudWatchアラームを含めること。テナント単位のレート制限を突破しようとする動きを早期検知するため。

### 3.9 バックアップ/DR

機能としては必ず有効化すること(オフにできる状態を許容しない)。保持日数などの具体的な数値は `variables.tf` の変数とし、保守的なデフォルト値(例: 7日)を設定すること。

### 3.10 IAM(最小権限)

各Lambdaには、対象のKnowledge Base/データソースARNに**スコープを絞った**最小権限のみを付与すること。

- `add_document` / `update_document`: `bedrock:IngestKnowledgeBaseDocuments`
- `delete_document` / `purge_tenant`: `bedrock:DeleteKnowledgeBaseDocuments`
- `query_document`: `bedrock:Retrieve`
- `get_document_status`: `bedrock:GetKnowledgeBaseDocuments`

---

## 4. RAGにおける固有のセキュリティ配慮

検索結果として返される文書内容は、外部から取り込まれた**信頼できないデータ**であり、間接的プロンプトインジェクション(取り込んだ文書内に「これまでの指示を無視して」等の文字列が仕込まれるケース)のリスクがある。このテンプレート単体では防ぎきれないため、`templates/rag-vector-db-bedrock-kb/README.md` に「このツールを利用するエージェント側のシステムプロンプトで、検索結果は参考データであり指示ではないことを明示すること」という注意書きを残すこと。

---

## 5. ディレクトリ構成(想定)

```
templates/rag-vector-db-bedrock-kb/
  main.tf                  # Bedrock Knowledge Base, データソース定義
  variables.tf              # tenant_rate_limit_rps, backup_retention_days 等
  outputs.tf                 # query_document Lambda ARN 等
  iam.tf
  sqs.tf                     # add/update/delete用キュー、DLQ
  api_gateway.tf              # add/update/delete/get_status/purge_tenant用REST API + Cognito Authorizer
  monitoring.tf               # 構造化ログ用ロググループ、Bedrockスロットリングアラーム
  lambda_add/
  lambda_update/
  lambda_delete/
  lambda_query/
  lambda_get_status/
  lambda_purge_tenant/
  lambda_common/              # 認証コンテキスト正規化ヘルパー等(このフォルダ内でのみ共有)
  README.md                    # tool-agentとの組み合わせ方、セキュリティ注意書きを含む
```

---

## 6. 明示的に対象外とするもの(やらないこと)

以下は議論の結果、意図的に対象外とした。実装中にこれらに手を出さないこと。

1. **他のベクトルDBバックエンド(OpenSearch Serverless版、Aurora pgvector版等)**: 需要が出た時点で `templates/rag-vector-db-opensearch` のような別フォルダとして追加する。今回は対象外
2. **バックエンド間の共通インターフェースを保証する契約テスト/Port層基盤**: 一度検討したが、バックエンドの選択は「利用者が cookiecutter するテンプレートを選ぶ」という一度きりの人間の意思決定であり、実行時にバックエンドを動的差し替えする必要が無いため、過剰設計と判断し不採用とした
3. **オンラインA/Bテスト(AppConfig + Prompt Managementの構成)**: これはサンプルコードとして別途提供するものであり、本テンプレートには含めない
4. **Bedrock Advanced Prompt Optimizationの実行そのもの**: 同上、サンプルコード側の責務
5. **報酬モデルトレーニング/RLHF(Bedrock Reinforcement Fine-Tuningなど)**: 本テンプレート群のスコープ外
6. **AIレディデータ基盤本体(カタログ、CDC連携、正式な権限管理)**: 何も存在しない前提。`access_tags` フィールドはプレースホルダとして持たせるのみで、実際の連携ロジックは実装しない
7. **CloudWatch Evidently**: 2025年10月に廃止されたサービスであり、参照・使用しないこと

---

## 7. `_shared` フォルダ・vendoring方式について

一時期「共通コードを `_shared/` に置いて同期スクリプトで各テンプレートに複製する」方式を検討したが、これは「テンプレートフォルダ間の依存」を心配していたための過剰な対応であり、実際には各テンプレートが完全に独立していれば良いだけと判明したため**不採用**。共通の関心事(認証・監視等)は、単純に各テンプレートフォルダの中に個別に実装し、重複を許容すること。

---

## 8. 作業の進め方(提案)

1. `templates/rag-vector-db-bedrock-kb/` のディレクトリ雛形と `main.tf`(Bedrock Knowledge Base本体)から着手
2. `lambda_common/` の認証コンテキスト正規化ヘルパーを先に実装(他の全Lambdaが依存するため)
3. `query_document` を実装(最もツールとしての入出力契約が重要なため優先)
4. `add_document` / `update_document` / `delete_document` + SQS構成
5. `get_document_status` / `purge_tenant`
6. API Gateway + Cognito Authorizer configuration
7. モニタリング・アラーム
8. README(tool-agentとの組み合わせ方、セキュリティ注意書き)

各ステップの完了後、次のステップに進む前に実装内容の要約を報告してください。

---

## 9. ADR作成指示

実装と並行して(または実装完了後に)、`docs/adr/` 配下に以下の意思決定それぞれについてADRを作成してください。ADRは「決定とその理由の記録」であり、実装手順を書く場所ではありません。以下のフォーマットに従ってください。

```markdown
# ADR-XXXX: <タイトル>

## ステータス
承認済み

## コンテキスト
<なぜこの判断が必要になったか、検討した背景>

## 決定
<何を決めたか>

## 検討した代替案
<採用しなかった選択肢と、それを採用しなかった理由>

## 結果・トレードオフ
<この決定によって得られるものと、引き換えに受け入れたデメリット>
```

記録すべき決定は以下の通りです(ファイル名は連番を振ってください)。

1. **テンプレートフォルダの完全独立性を優先し、共通コードの重複を受け入れる**(vendoring方式を検討し不採用にした経緯を含む)
2. **RAGを単一テンプレートにせず、`tool-agent` と `rag-vector-db-*` を利用者が組み合わせる方式にした理由**(AgentCore Gatewayへの後付けアタッチという疎結合な接続方式が前提にあること)
3. **バックエンド間の共通インターフェース・契約テストを採用しなかった理由**(過剰設計と判断した根拠)
4. **`tenant_id` をLLM/呼び出し元パラメータにせず、認証コンテキストから強制取得する原則**
5. **ベクトルDBの第一弾としてBedrock Knowledge Bases(カスタムデータソース)を採用した理由**(自前OpenSearch/pgvector構築との比較)
6. **テナント分離をプール型(共有DB+メタデータフィルタ)にし、サイロ型を例外的なエスカレーション手段とした理由**(契約上の要求だけでなく性能分離の観点も含む)
7. **`purge_tenant` を非同期契約にした理由**(Bedrock側に一括削除APIが無く、同時実行数上限とバッチループの実情に起因すること)
8. **テナント単位のレート制限を「機能としては必須、数値は変数化」という形にした理由**
9. **CognitoをJWT Authorizer(組み込み)+ 正規化ヘルパー関数で使う構成にし、Lambda Authorizerを見送った理由**
10. **コスト集計はAthena、レイテンシ/エラー率はLogs Insightsという指標ごとの置き場所を分けた理由**
11. **オフライン評価(CI/CDのゲート)とオンラインA/Bテストを明確に分離し、後者をテンプレート本体に含めなかった理由**
12. **Prompt Management / AppConfigをテンプレートでなくサンプルコード止まりにした理由**(開発文化に関わる判断であるため)

各ADRの「コンテキスト」「検討した代替案」は、本ドキュメントの該当セクションの記述を踏まえて、実際の議論の流れが分かるように具体的に書いてください。テンプレートの丸写しではなく、なぜその結論に至ったかの論理が読み取れる内容にしてください。
