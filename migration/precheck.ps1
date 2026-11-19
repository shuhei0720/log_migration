#Requires -Version 5.1
. (Join-Path $PSScriptRoot "common.ps1")
$script:initiativeDefinition = $null

# --------------------------------------------------
# CSVの読込
# CSVの各行から対象サブスクリプションと移行先を取得する。
# --------------------------------------------------
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        # --------------------------------------------------
        # ポリシー割り当てと参照IDの確認
        # 対象サブスクリプションに、指定した3件の割り当てがあるか確認する。
        # 3件目のイニシアティブから、指定した12件の参照IDを確認する。
        # --------------------------------------------------
        $assignmentUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
        $assignments = @()
        do {
            $page = Invoke-ArmRequest -ResourceId $assignmentUrl
            $assignments += @($page.value)
            $assignmentUrl = $page.nextLink
        } while ($assignmentUrl)
        foreach ($assignment in $policyAssignments) {
            if ($assignment.Id -notin $assignments.id) { throw "指定環境の割り当てが適用されていません: $($assignment.Id)" }
        }
        $assignment = $assignments | Where-Object { $_.id -eq $policyAssignments[2].Id } | Select-Object -First 1
        $definitionId = $assignment.properties.policyDefinitionId
        if (-not $definitionId -or $definitionId -notmatch '/policySetDefinitions/') { throw "3件目の割り当てからイニシアティブの定義IDを取得できません。" }
        if (-not $script:initiativeDefinition) { $script:initiativeDefinition = Invoke-ArmRequest -ResourceId $definitionId -ApiVersion "2023-04-01" }
        foreach ($referenceId in $policyReferenceIds) {
            if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) { throw "指定の参照IDがイニシアティブに存在しません: $referenceId" }
        }
        # --------------------------------------------------
        # 診断設定と保存先の調査
        # 現在の旧設定から移行後の設定を組み立てる。作成を省略する側も、最後に削除する旧設定を調べる。
        # 新設定を作成する対象だけ、旧設定を残して追加できるか診断設定の5件の上限を確認する。
        # --------------------------------------------------
        $null = Get-MigrationPlan -Target $target
        # --------------------------------------------------
        # 診断設定名の重複確認
        # 新設定を作成する対象で、名前が既存設定と重なる場合にエラーとして記録する。
        # --------------------------------------------------
        foreach ($plan in $target.DiagnosticPlans) {
            if (@($plan.NewSettings).Count -gt 0) {
                Add-MigrationFailure -Target $target -ResourceId $plan.ResourceId -Stage "診断設定の事前確認" `
                    -Message "新しい診断設定名が既存設定と重複しています。初回の事前チェックを停止します。"
            }
        }
        # --------------------------------------------------
        # ストレージのSKUと名前の確認
        # 保存先の地域でStorageV2・Standard_ZRSを利用できるか確認する。
        # 地域別に組み立てたストレージ名の重複と、Azure上での名前の空きを確認する。
        # --------------------------------------------------
        if ($target.Storages.Count -gt 0) {
            $skus = @(Invoke-AzJson -Arguments @("storage", "sku", "list", "--subscription", $subscriptionId))
            foreach ($storage in @($Target.Storages.Values | Sort-Object Name)) {
                try {
                    if (-not $script:storageNames.Add($storage.Name)) { throw "変換後のストレージ名が重複しています: $($storage.Name)" }
                    if (-not ($skus | Where-Object { $_.name -eq "Standard_ZRS" -and $_.kind -eq "StorageV2" -and $storage.Location -in $_.locations })) { throw "Standard_ZRSを利用できないリージョンです: $($storage.Location)" }
                    $availability = Invoke-AzJson -Arguments @("storage", "account", "check-name", "--subscription", $subscriptionId, "--name", $storage.Name)
                    if ($availability.nameAvailable -ne $true) { throw "名前を利用できません: $($storage.Name) / $($availability.reason) / $($availability.message)" }
                    Add-MigrationCheck -Target $Target -ResourceId $storage.Id -Stage "ストレージ名の事前確認" -Success $true -Message "利用可能"
                }
                catch {
                    Add-MigrationFailure -Target $Target -ResourceId $storage.Id -Stage "ストレージ名の事前確認" -Message $_.Exception.Message
                }
            }
        }
    }
    catch { Add-MigrationFailure -Target $target -Stage "事前チェック" -Message $_.Exception.Message }
}
# --------------------------------------------------
# 確認結果の出力
# 事前チェックの結果とエラーを出力する。
# --------------------------------------------------
Complete-MigrationStep -Step "precheck" -IncludeChecks
