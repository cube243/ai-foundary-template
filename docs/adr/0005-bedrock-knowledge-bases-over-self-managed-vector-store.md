# ADR-0005: ベクトルDBの第一弾としてBedrock Knowledge Bases(CUSTOMデータソース)を採用する

## ステータス
承認済み

## コンテキスト
RAGを実現するには、文書のチャンク分割・埋め込み生成・ベクトル格納・類似検索という一連の機能が必要になる。これを自前のOpenSearch(またはpgvector on Aurora)クラスタ+自作の分割/埋め込みパイプラインで構築する方法と、Amazon Bedrock Knowledge Basesにこれらを任せる方法の両方が選択肢としてあった。

## 決定
Amazon Bedrock Knowledge Basesを採用し、データソースタイプは`CUSTOM`(Direct Ingestion API: `IngestKnowledgeBaseDocuments`/`DeleteKnowledgeBaseDocuments`/`Retrieve`/`GetKnowledgeBaseDocuments`)とする。裏側の実ベクトルストア自体はBedrock Knowledge Basesが対応する複数の選択肢(S3 Vectors、OpenSearch Serverless等)から選べるようにし、デフォルトは実装コストが低いものとする(具体的な選定はADR-0005のスコープ外、`variables.tf`のコメント参照)。

## 検討した代替案
- **自前でOpenSearch Serverless/Aurora pgvectorを構築し、チャンク分割・埋め込み生成を自作する**: 実装量が大幅に増える(チャンク分割ロジック、埋め込みモデル呼び出しのリトライ/バッチ処理、ベクトルインデックスのスキーマ設計・運用が全て自己責任になる)。Bedrock Knowledge Basesを使えば、これらをAWSのマネージドサービスに任せられ、`IngestKnowledgeBaseDocuments`等の少数のAPIでCRUDが揃う。
- **Bedrock Knowledge BasesのS3/Web Crawler等の標準データソースタイプを使う**: これらはAWS側が定期的にクロール/同期する設計であり、アプリケーションから「今すぐこの1文書を追加/更新/削除する」というリアルタイムなCRUD操作には向かない。`CUSTOM`データソース+Direct Ingestion APIは、アプリケーション側からのプッシュ型の同期的なドキュメント管理に対応しており、マルチテナントSaaSのような「ユーザー操作に応じて即座に反映したい」要件に合致する。

## 結果・トレードオフ
得られるもの: チャンク分割・埋め込み生成・ベクトル格納の実装をほぼゼロにでき、本テンプレートの実装範囲を6つのLambda関数(CRUD相当)に絞り込める。Bedrockのマネージドサービスとしての可用性・スケーラビリティの恩恵を受けられる。
引き換えに受け入れるもの: Bedrock Knowledge Basesの制約(`IngestKnowledgeBaseDocuments`/`DeleteKnowledgeBaseDocuments`のアカウント全体で同時実行数10件までという制約、検索系APIのTPS上限等)にアプリケーション側が従う必要があり、これが非同期化(ADR-0007関連)や同時実行数の変数化(3.6)といった追加の設計判断を要求している。またBedrock側の仕様変更(API/IAMアクション名等)に追従する必要がある。
