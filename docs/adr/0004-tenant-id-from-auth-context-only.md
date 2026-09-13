# ADR-0004: tenant_idをLLM/呼び出し元パラメータにせず、認証コンテキストから強制取得する

## ステータス
承認済み

## コンテキスト
`rag-vector-db-bedrock-kb`はプール型のマルチテナント構成(1つのKnowledge Baseを全テナントで共有し、メタデータでフィルタする)を採る。この構成では、検索・追加・更新・削除のいずれの操作でも「どのテナントの操作か」を正しく特定できなければ、他テナントのデータが漏洩・破壊されるリスクがある。特に`query_document`はLLMがツールとして直接呼び出すため、入力スキーマに`tenant_id`のような値が含まれていると、プロンプトインジェクションや単純なLLMの誤りによって他テナントの`tenant_id`を指定されてしまう可能性がある。

## 決定
`tenant_id`はいかなる場合もLLM/呼び出し元が指定できる値にしてはならない。`query_document`の入力スキーマは`{"query","top_k"}`のみとし、`tenant_id`は含めない。`add_document`/`update_document`/`delete_document`/`get_document_status`も同様に、リクエストボディに`tenant_id`を含めない。代わりに、認証で検証済みの値(Cognito JWTクレーム、`lambda_common/auth_context.py`が正規化したもの)をコード側で機械的に注入する。`Retrieve`呼び出し時は`filter`に`{"equals": {"key": "tenant_id", "value": <認証コンテキスト由来の値>}}`を組み込み、`add/update/delete/get_status`は認証コンテキストのtenant_idを使ってBedrock側のドキュメントIDを`{tenant_id}::{document_id}`という合成キーにする(ADR-0006参照)ことで、ID直接指定によるテナント越境も構造的に防ぐ。

なお、`purge_tenant`は例外である。これは管理者権限を要求する操作であり、「どのテナントを退会処理するか」を指定すること自体が機能の本質のため、リクエストボディに`tenant_id`を含める。この操作は認証コンテキストの`roles`に`admin`が含まれることをコード側で強制チェックすることで安全性を担保しており、「呼び出し元がtenant_idを指定できない」というテナントスコープ操作向けの原則とは異なる、別のトラストバウンダリ(管理者操作)として扱う。

## 検討した代替案
- **`query_document`の入力に`tenant_id`を含め、Gateway側のインターセプターが正しい値に上書きする**: 値の存在自体がLLMに「tenant_idというパラメータがある」ことを示唆してしまい、モデルへのプロンプト設計上ノイズになる。また上書き忘れのリスクがある。
- **`add/update/delete`もBedrock側のドキュメントIDをそのまま使い、認証コンテキストのtenant_idはメタデータのフィルタ用途にのみ使う**: `Retrieve`と異なり、`IngestKnowledgeBaseDocuments`/`DeleteKnowledgeBaseDocuments`/`GetKnowledgeBaseDocuments`はドキュメントID直指定のAPIであり、メタデータによるフィルタが効かない。呼び出し元が他テナントのドキュメントIDを知っている(あるいは推測できる)場合、そのまま操作できてしまう。これは指示書に明記されていなかったが、実装時に発見したギャップであり、合成キー方式(ADR-0006)で解消した。

## 結果・トレードオフ
得られるもの: LLMや呼び出し元アプリケーションのバグ・悪意ある入力によって、他テナントのデータが読み書きされる経路が構造的に塞がれる。
引き換えに受け入れるもの: `query_document`はAgentCore Gateway経由で呼ばれるため、認証コンテキストをLambdaに届ける標準的な仕組みが無く(ADR-0002参照)、この原則を`query_document`単体で完全に閉じることができていない。Gateway側にリクエストインターセプターを構成するまでは、この原則は「守ろうとしているが実現手段が未完成」という状態にあることをREADMEのTODOとして明記している。
