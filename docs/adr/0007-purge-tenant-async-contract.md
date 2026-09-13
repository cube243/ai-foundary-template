# ADR-0007: purge_tenantを非同期契約にする

## ステータス
承認済み

## コンテキスト
テナントの退会時には、そのテナントに属する全文書をKnowledge Baseから削除する必要がある。しかしBedrock Knowledge Basesには「あるテナントの文書を一括削除する」というネイティブAPIが存在せず、`DeleteKnowledgeBaseDocuments`(1回の呼び出しにつき最大10件のドキュメント識別子)をテナントの文書数に応じて繰り返し呼び出すバッチループとして実装する必要がある。また、この操作は`IngestKnowledgeBaseDocuments`/`DeleteKnowledgeBaseDocuments`のアカウント全体で同時実行数10件までという制約を共有しており、他の`add`/`update`/`delete`と同じ枠を奪い合う。

## 決定
`purge_tenant`は同期完了を約束しない非同期契約にする。APIは`{"tenant_id"}`を受け取り、即座に`{"status":"PURGE_QUEUED","job_id":"<uuid>"}`を返す。実際の列挙・削除ループは専用のSQSキュー経由のワーカーLambda(reserved concurrency=1)が行う。ワーカーは`list_knowledge_base_documents`でテナントの文書を(合成キーの前方一致で)列挙し、`delete_knowledge_base_documents`の上限である10件ずつのバッチで削除する素朴なループとする。

## 検討した代替案
- **同期APIとして実装し、削除完了まで応答を待たせる**: テナントの文書数が多い場合、API Gatewayの統合タイムアウト(最大29秒)を超える可能性が高く、また削除ループの途中でクライアントとの接続が切れても処理自体は継続させたいため、同期設計はそもそも成立しない。
- **`purge_tenant`用に別の同時実行数枠を確保せず、`delete_document`のキュー/ワーカーをそのまま再利用する**: シンプルだが、大量削除がテナント単位の個別削除(通常のdelete_document呼び出し)のレイテンシに影響を与えうる。専用のキュー+ワーカー+reserved concurrencyを分けることで、通常の削除フローとバッチパージが互いを妨げないようにした。
- **削除進捗を確認できるget-purge-statusのようなエンドポイントを追加する**: 指示書の契約に含まれておらず、今回は`job_id`をログ相関のためだけに発行し、進捗確認APIは実装しないスコープとした。

## 結果・トレードオフ
得られるもの: 大量の文書を持つテナントの退会処理でも、APIのタイムアウトを気にする必要が無い。バッチ削除の同時実行を1に抑えることで、`add`/`update`/`delete`の同時実行数と合わせてもBedrockのアカウント全体10件枠を超えない設計にできる。
引き換えに受け入れるもの: 呼び出し元は「削除がいつ完了したか」をポーリングする手段を持たない(get-purge-statusを実装していないため)。削除完了の確認が必要な場合は、`get_document_status`を個別文書に対して呼び出すか、CloudWatch Logsで`job_id`を追跡する運用でカバーする想定になる。
