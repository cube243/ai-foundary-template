# ADR-0008: CognitoをAPI Gateway組み込みJWT Authorizer+正規化ヘルパーで使い、Lambda Authorizerを見送る

## ステータス
承認済み

## コンテキスト
本テンプレートは現状Amazon Cognito User Poolを認証基盤として使うが、将来的に社内の別IdPに置き換わる可能性がある。API Gatewayでの認証方式には、Cognitoに組み込みで対応した`COGNITO_USER_POOLS`タイプのAuthorizer(トークンの署名・有効期限・発行者を検証するだけの機能)と、任意のロジックを書けるカスタムLambda Authorizerの両方の選択肢がある。

## 決定
API Gatewayの組み込み`COGNITO_USER_POOLS`Authorizerを使う。カスタムのLambda Authorizerは実装しない。その代わり、Cognitoの JWTクレーム名(`custom:tenant_id`、`cognito:groups`)をコードの随所で直接参照せず、`lambda_common/auth_context.py`という1つの正規化ヘルパー関数(`get_auth_context(event) -> {tenant_id, user_id, roles}`)を用意し、以降の全Lambdaハンドラはこのヘルパーが返す正規化済みの形だけを参照する。`purge_tenant`の管理者権限チェック(`roles`に`admin`が含まれるか)も、API Gatewayの認可機構ではなくこの正規化済みコンテキストを使ってLambda内部で行う。

## 検討した代替案
- **カスタムLambda Authorizerを実装し、そこでロール判定やより複雑な認可ロジックを行う**: 今回時点では要求される認可ロジックが「トークンが有効か」+「adminロールを持つか(purge_tenantのみ)」程度であり、Lambda Authorizerを追加する複雑さ・レイテンシ増・追加のIAMロールに見合う価値が無いと判断した。
- **API GatewayのCOGNITO_USER_POOLSAuthorizerのauthorization scopes機能でpurge_tenantのアクセス制御を行う**: Cognitoのリソースサーバー/OAuthスコープの追加設定が必要になり、本テンプレートが他に必要としないOAuthクライアントクレデンシャルフローの構成を増やすことになる。Lambda内部でのロールチェックの方がシンプルで、正規化ヘルパーの設計方針(クレーム名を1箇所に閉じ込める)とも一貫する。

## 結果・トレードオフ
得られるもの: API Gateway側の認証設定がシンプルに保たれる。将来Cognitoから別のIdP(OIDC対応の社内IdP等)に置き換える際も、変更箇所は`lambda_common/auth_context.py`1ファイルと、API Gatewayのauthorizer設定(`provider_arns`相当)に限定される。
引き換えに受け入れるもの: 複雑な認可ルール(例: リソースごとに異なるスコープ、細粒度なABAC等)が将来必要になった場合、正規化ヘルパー+各Lambda内でのif文という素朴な形では対応しきれなくなる可能性があり、その時点でLambda Authorizerの導入を再検討する必要がある。
