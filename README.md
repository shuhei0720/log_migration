# 診断設定の段階移行

指定したLog Analyticsを宛先にする既存の診断設定を、新しい保存先へ複製します。原本の`log_migration.ps1`と原本CSVは変更していません。

本番で使用するスクリプトは6本です。

|ファイル|役割|
|---|---|
|[log_migration_common.ps1](log_migration_common.ps1)|設定値と繰り返し使う処理|
|[log_migration_precheck.ps1](log_migration_precheck.ps1)|① 名前・入力・追加可能数の確認と復元情報の保存|
|[log_migration_copy.ps1](log_migration_copy.ps1)|② 保存先の準備と診断設定の複製|
|[log_migration_verify.ps1](log_migration_verify.ps1)|③ 全対象の現在値を確認|
|[log_migration_delete.ps1](log_migration_delete.ps1)|④ 全件確認後の旧設定削除|
|[log_migration_rollback.ps1](log_migration_rollback.ps1)|②・④の途中／完了後からの切り戻し|

Windows PowerShell 5.1とAzure CLI 2.54以降を使用します。対象サブスクリプションのOwnerで`az login`済みであることを前提とします。日本語を含むスクリプトはUTF-8 BOM付きで保存してください。

## 設定

`log_migration_common.ps1`冒頭の`$targetWorkspaceId`と`$environment`を指定します。`$oldDcrIdsByEnvironment`には、ご提示の本番・検証・開発それぞれ2本の旧DCRリソースIDを設定済みです。新しい診断設定の共通名は同ファイルの`$newDiagnosticSettingName`で変更できます。

入力例を同じフォルダーへ`log_migration_targets_regional.csv`としてコピーします。環境ごとに実行し、CSVには今回の環境のサブスクリプションだけを記載してください。

|列|内容|
|---|---|
|SubscriptionName|サブスクリプションIDまたは一意の名前|
|ResourceGroup|保存先を作るリソースグループ|
|StorageAccount|小文字英数字3〜24文字で`jpe`を1箇所だけ含む名前。Log行は空欄可|
|WorkspaceName|新しいLog Analyticsワークスペース名|
|LogDestination|StorageまたはLog|

Storageは移行対象のリージョンごとに作成し、名前の`jpe`だけをMicrosoft公開のAzure Naming Toolの略称へ置き換えます。globalまたは所在地なしは東日本を使用します。Log行はリージョン別Storageを作りません。

DCRの新しい関連付けを作るのは、指定した旧DCR 2本に関連付いていたリソースだけです。VM・VMSSとも、旧関連がないものには追加しません。診断設定の複製とDCRの関連付けは、それぞれの旧設定から対象を判定します。新DCRの収集内容は原本と同じWindowsのApplication／Security／SystemイベントとSyslogです。

## ① 事前チェック

```powershell
powershell.exe -NoProfile -File .\log_migration_precheck.ps1
```

同名Storage・同名診断設定があれば停止します。新DCR・新関連のIDが旧DCR・旧関連と重なる場合も停止します。Azureの設定は変更しません。全件の確認に成功すると、切り戻し用の`log_migration_backup_<環境名>.json`を保存します。既存のバックアップは上書きしません。例：devの場合は`log_migration_backup_dev.json`です。

バックアップは対象の旧診断設定と、今回触るDCR・関連付け・適用除外を元へ戻すための情報だけです。診断設定は事前チェックの取得結果を保存するため、バックアップ目的の再走査は行いません。ログデータは含みません。

①の途中停止でバックアップが未完成の場合は、そのファイルを別名へ退避して①をやり直してください。②以降は、①で完成したバックアップを保持して再実行します。

## ② 設定・再実行

```powershell
powershell.exe -NoProfile -File .\log_migration_copy.ps1
```

途中停止後は、同じ設定値・バックアップを使い、この工程から再実行します。①は初回だけです。作業対象を絞る場合は、①で確認済みのサブスクリプションの行だけをCSVに残せます。各行の設定値は維持してください。

既存の新診断設定は、収集条件と送信先が一致すればスキップします。内容が違えば上書きせず手動対応一覧へ出します。保存先はID・リージョン・基礎構成を確認し、不足する設定だけ補完します。旧診断設定と旧DCR 2本への関連付けは残します。

## ③ 全件確認

```powershell
powershell.exe -NoProfile -File .\log_migration_verify.ps1
```

Azureの現在値で全件確認します。手動設定後も再実行してください。旧設定・旧DCR関連を削除済みのリソースも、バックアップに記録した全対象の新診断設定・新DCR関連を確認します。この工程ではAzureを変更しません。

## ④ 旧設定削除

人が③の全件成功を確認した後に実行します。

```powershell
powershell.exe -NoProfile -File .\log_migration_delete.ps1
```

削除版も全CSV対象を再確認し、未完了が1件でもあれば削除を開始しません。旧DCR 2本への関連付け、旧診断設定の順で削除します。各削除の直前にも新旧設定を確認します。失敗した場合は以降の削除をすべて止めます。途中停止後は、全対象の新設定を確認してから残っている旧設定だけを削除します。旧DCR本体は残します。

## 切り戻し

②・④の途中／完了後とも同じスクリプトを使用します。全体を戻す場合は次を実行します。

```powershell
powershell.exe -NoProfile -File .\log_migration_rollback.ps1
```

一部のサブスクリプションだけを戻す場合は、Windows PowerShellを開いて対象IDを指定します。

```powershell
.\log_migration_rollback.ps1 -SubscriptionIds "対象のサブスクリプションID"
# 複数指定する場合
.\log_migration_rollback.ps1 -SubscriptionIds "ID1", "ID2"
```

旧DCR 2本への関連付けを全対象で復元し、読み戻して一致を確認します。その後、元の診断設定や新側の変更前設定を復元し、今回追加した送信設定を外します。旧関連の復元に失敗した場合は、新側の送信設定を残して停止します。対象外の設定や、内容が期待値と異なる設定は上書きしません。

Storage・Log Analyticsと保存済みログは残します。新規作成したDCR本体も残し、既存DCRは変更前の内容へ戻します。今回追加したDCR関連付けと適用除外は元の有無へ戻し、既存の適用除外は維持します。

## 出力と設定範囲

失敗時は工程別の`*_failures.csv`に、リソースID・理由・期待する設定を出します。確認結果は`*_results.csv`に出します。これらは手動作業・確認用です。

元のログ・メトリックの有効／無効、categoryGroup、保持条件、Log Analyticsの格納方式を維持し、宛先をCSVの指定先へ変更します。元の他の宛先は引き継ぎません。対象外の診断設定は変更・削除しません。

Storage・Log Analyticsの構成とDCRの収集内容は原本を踏襲します。各サブスクリプションの設定前に指定環境の3件のポリシーをWaiverで除外します。最初の2件は全体、3件目は指定12参照ID。期限はなく、通常の移行工程では自動削除しません。

診断設定の調査と複製にはPowerShell標準ジョブを最大5個使用します。実測時間と検証対象は[検証結果](test-results/REPORT.md)、各ケースは[テスト一覧](test-results/TEST_CASES_CURRENT.md)に記載します。

## 追加の56タイプ検証

ご提示の56タイプを対象とする[テスト環境用コードと手順](test-environment/README.md)、[2サブスクリプション合計の見積もり](test-environment/BUDGET_ESTIMATE.md)を用意しました。配布コードはPowerShellとARMテンプレートの2ファイルです。

53タイプ・予算6,000円（有料保持4時間目標・6時間計画枠）の承認を受け、追加の実Azure検証を開始しています。既存VNetは2つのリソースIDで指定します。旧テスト資産は撤去済みで、既知のNetwork登録1件は全テストの撤去後に元の未登録へ戻します。

追加テスト環境は、管理グループ作成直後の反映待ち不足で停止したため修正中です。有料リソースの作成・追加の移行試験はまだ行っていません。既存6本の完了済み検証結果とは区別しています。
