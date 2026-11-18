# 診断設定の段階移行

指定したLog Analyticsを宛先にする既存の診断設定を、新しい保存先へ複製します。原本の`log_migration.ps1`と原本CSVは変更していません。

本番で使用する6本は、`migration`フォルダーにまとめています。通常の実行順はstep1〜step4です。`common.ps1`は各工程が読み込むため単独実行は不要です。`rollback.ps1`は切戻しが必要な場合だけ実行します。

|ファイル|役割|
|---|---|
|[common.ps1](migration/common.ps1)|設定値と繰り返し使う処理|
|[step1_precheck.ps1](migration/step1_precheck.ps1)|① 名前・入力・追加可能数の事前確認|
|[step2_copy.ps1](migration/step2_copy.ps1)|② 保存先の準備と診断設定の複製|
|[step3_verify.ps1](migration/step3_verify.ps1)|③ 全対象の現在値を確認|
|[step4_delete.ps1](migration/step4_delete.ps1)|④ 全件確認後の旧設定削除|
|[rollback.ps1](migration/rollback.ps1)|②・④の途中／完了後からの切り戻し|

Windows PowerShell 5.1とAzure CLI 2.54以降を使用します。対象サブスクリプションのOwnerで`az login`済みであることを前提とします。日本語を含むスクリプトはUTF-8 BOM付きで保存してください。

コードを読む際は、[処理の流れ・変数・途中再開を説明する補助資料](REVIEW_GUIDE.md)も参照してください。現在は実機検証中の下書きです。

## 設定

`migration/common.ps1`冒頭の`$targetWorkspaceId`と`$environment`を指定します。`$oldDcrIdsByEnvironment`には、ご提示の本番・検証・開発それぞれ2本の旧DCRリソースIDを設定済みです。新しい診断設定の共通名は同ファイルの`$newDiagnosticSettingName`で変更できます。

`migration`内の入力例を、同じフォルダーへ`log_migration_targets_regional.csv`としてコピーします。環境ごとに実行し、CSVには今回の環境のサブスクリプションだけを記載してください。

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
powershell.exe -NoProfile -File .\migration\step1_precheck.ps1
```

前日などにも単独実行できます。同名Storage・同名診断設定があれば停止します。新DCR・新関連のIDが旧DCR・旧関連と重なる場合も停止します。Azureの設定は変更せず、バックアップも作りません。①の結果ファイルは②以降の入力にしません。

①の実行後に対象が追加・変更されても、②は実行時のAzureを調べ直します。既存のバックアップがある場合も、①はそれを読み書きしません。

## ② 設定・再実行

```powershell
powershell.exe -NoProfile -File .\migration\step2_copy.ps1
```

①の実行有無に依存せず、CSVを読みます。サブスクリプションごとに「現在の対象を調査→変更前情報を保存→適用除外→保存先とDCRを準備→診断設定を複製」の順で処理し、次のサブスクリプションへ進みます。

変更前情報は `migration/log_migration_backup_<環境名>.json`（形式Version 3）へ保存します。対象の旧診断設定、今回扱うDCR・関連付けの変更前設定、適用除外の既存有無だけで、ログデータは含みません。診断設定は複製のため取得した値を保存し、旧DCR関連付けだけは一覧で省略される項目を個別取得します。保存を完了してから、そのサブスクリプションの変更を始めます。

途中停止後は同じ設定値とバックアップを保持して②を再実行します。保存済みの変更前情報は上書きせず、新たに見つかった対象だけ情報を追加してから処理します。サブスクリプションを絞る場合はCSVの行を減らせますが、記録済みの行の保存先などは変更できません。

初めて扱う対象では、同名Storage・同名新診断設定を再利用しません。今回の記録にある作成済みの設定は、内容が一致すればスキップします。不一致は上書きせず手動対応一覧へ出します。保存先はID・リージョン・基礎構成を確認し、不足する設定だけ補完します。旧診断設定と旧DCR 2本への関連付けは残します。

VMログ用のEvent・Syslogテーブルは、テーブル単位の合計保持期間 `totalRetentionInDays` を3年（1,095日）に明示設定します。既存テーブルはその項目だけPATCHし、分析保持期間・スキーマ・プランと、他のテーブルは変更しません。ワークスペース既定の保持期間は365日のままです。StorageのappendBlob削除ルールも1,095日とし、今回の管理対象の旧365日ルールは置き換え、他のルールは保持します。

## ③ 全件確認

```powershell
powershell.exe -NoProfile -File .\migration\step3_verify.ps1
```

②のバックアップ・処理記録とAzureの現在値で全件確認します。手動設定後も再実行してください。旧設定・旧DCR関連を削除済みのリソースも、バックアップに記録した全対象の新診断設定・新DCR関連を確認します。この工程ではAzureを変更しません。

## ④ 旧設定削除

人が③の全件成功を確認した後に実行します。

```powershell
powershell.exe -NoProfile -File .\migration\step4_delete.ps1
```

削除版も全CSV対象を再確認し、未完了が1件でもあれば削除を開始しません。旧DCR 2本への関連付け、旧診断設定の順で削除します。各削除の直前にも新旧設定を確認します。失敗した場合は以降の削除をすべて止めます。途中停止後は、全対象の新設定を確認してから残っている旧設定だけを削除します。旧DCR本体は残します。

## 切り戻し

②・④の途中／完了後とも同じスクリプトを使用します。全体を戻す場合は次を実行します。

```powershell
powershell.exe -NoProfile -File .\migration\rollback.ps1
```

②の変更前に保存した状態へ戻します。①の実行時点の状態は使用しません。

一部のサブスクリプションだけを戻す場合は、Windows PowerShellを開いて対象IDを指定します。

```powershell
.\migration\rollback.ps1 -SubscriptionIds "対象のサブスクリプションID"
# 複数指定する場合
.\migration\rollback.ps1 -SubscriptionIds "ID1", "ID2"
```

旧DCR 2本への関連付けを全対象で復元し、読み戻して一致を確認します。その後、元の診断設定や新側の変更前設定を復元し、今回追加した送信設定を外します。旧関連の復元に失敗した場合は、新側の送信設定を残して停止します。対象外の設定や、内容が期待値と異なる設定は上書きしません。

Storage・Log Analyticsと保存済みログは残します。新規作成したDCR本体も残し、既存DCRは変更前の内容へ戻します。今回追加したDCR関連付けと適用除外は元の有無へ戻し、既存の適用除外は維持します。

## 出力と設定範囲

失敗時は工程別の`*_failures.csv`に、リソースID・理由・期待する設定を出します。確認結果は`*_results.csv`に出します。これらは手動作業・確認用です。

元のログ・メトリックの有効／無効、categoryGroup、保持条件、Log Analyticsの格納方式を維持し、宛先をCSVの指定先へ変更します。元の他の宛先は引き継ぎません。対象外の診断設定は変更・削除しません。

Storage・Log Analyticsの構成とDCRの収集内容は原本を踏襲します。各サブスクリプションの設定前に指定環境の3件のポリシーをWaiverで除外します。最初の2件は全体、3件目は指定12参照ID。期限はなく、通常の移行工程では自動削除しません。

診断設定の調査と複製にはPowerShell標準ジョブを最大5個使用します。コード整理後の確認状況は[改修後の検証状況](test-results/READABILITY_REFACTOR.md)に記載します。以前の構成の実測時間・対象は[従来の検証結果](test-results/REPORT.md)、各ケースは[テスト一覧](test-results/TEST_CASES_CURRENT.md)に残しています。

## 追加の56タイプ検証

ご提示の56タイプを対象とする[テスト環境用コードと手順](test-environment/README.md)、[2サブスクリプション合計の見積もり](test-environment/BUDGET_ESTIMATE.md)を用意しました。配布コードはPowerShellとARMテンプレートの2ファイルです。

53タイプ・予算6,000円（有料保持4時間目標・6時間計画枠）の案は承認済みです。リソース網羅テストは有料リソースの展開前に準備処理で停止し、現在は主要6本に対象を絞った検証を優先して休止しています。既存VNetは2つのリソースIDで指定します。

停止した追加環境の専用管理グループと、以前の事前準備用VNet・NSG・ガード等は撤去済みです。元の未登録を記録した31件のプロバイダーを台帳で管理し、全検証終了後に状態を確認・復元します。元の状態が不明な登録は残します。主要6本の動作確認を終えて提出し、ユーザーレビュー後に最後のリソース網羅テストへ進みます。既存VNet・サブネットのNSG・ルートテーブル・委任を変更する構成は使いません。
