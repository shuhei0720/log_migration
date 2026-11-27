# 本番作業後の確認

step3が完了したら、移行に使ったcommon設定・CSV・作業記録のままstep4を実行します。

```powershell
pwsh.exe -NoProfile -File .\migration\step4_final_check.ps1
Import-Csv .\migration\final_check_results.csv |
    Format-Table SubscriptionId, ResourceId, Result, Reason
```

CSVの対象サブスクリプションすべてに結果があり、Result列が全件OKであることを確認します。下の4項目はstep4で自動確認する内容です。判定欄へOK・NGを記入します。

|確認項目|合格条件|判定|
|---|---|---|
|T01：旧送信の終了|記録した旧診断設定・旧DCR関連付けがすべて存在しない。再調査でも、指定した旧ワークスペース・旧2本のDCRへの送信設定が0件|未確認|
|T02：診断設定|送信を続ける対象では、送信先とログ・メトリックが作業記録と一致する。移行先のLog Analytics・DCR自身の診断設定も一致する|未確認|
|T03：VM・VMSS|新しい送信を指定したVM・VMSSが、作業記録の新DCRを参照している|未確認|
|T04：保存先・適用除外|新設保存先の設定値が記録と一致する。再利用先は存在と地域が一致する。適用除外も記録の設定値と一致する|未確認|

`None`・空欄の側は、旧設定の削除を確認します。未記録の同名設定を今回の作成物とは見なしません。

NGがあればCSVのResourceId・Reason・Expectedを確認し、原因を直してstep4を再実行します。全件OKを確認してから作業完了とします。CSVと作業記録は作業結果として保管してください。
