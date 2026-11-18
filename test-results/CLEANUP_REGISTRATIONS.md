# 後片付け時のサービス登録

対象は検証に使用したサブスクリプション1・2だけです。作成したリソース、ポリシー、適用除外、管理グループは撤去し、サブスクリプションの配置は元のテナントルートへ戻します。

リソースプロバイダーは、Azureの各サービスをサブスクリプションで使用するための登録です。一部について登録前の正確な状態を記録していないため、その部分の初期値との一致は照合できません。

|対象|検証で登録を実行したサービス|
|---|---|
|サブスクリプション1|Storage、OperationalInsights、Insights、Security、Web、ContainerService、Compute、Network、ManagedIdentity|
|サブスクリプション2|Storage、OperationalInsights、Insights、Security、Network、Sql、CognitiveServices、Web、KeyVault、DocumentDB、EventHub、ServiceBus、EventGrid、Automation、RecoveryServices|

正確に`NotRegistered`を記録できているのは、サブスクリプション2のStorage、OperationalInsights、Insights、Security、Network、EventGrid、Automation、RecoveryServicesの8件です。それ以外は初期状態の記録が不完全です。

登録解除は検証リソースの全撤去後に行います。Microsoft.Resources、Microsoft.Authorizationなどの基本プロバイダーは解除対象に含めません。

ユーザー確認済みの方針：元の未登録を確認できた上記8件だけ解除し、それ以外の登録は残します。現時点では解除前です。
