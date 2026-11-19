#Requires -Version 5.1
. (Join-Path $PSScriptRoot "common.ps1")
$script:initiativeDefinition = $null

# CSVから対象サブスクリプションと移行先を読み込む。
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        # 対象サブスクリプションに、指定した3件のポリシー割り当てがあるか確認する。
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
        # 3件目のイニシアティブに、指定した12件の参照IDがあるか確認する。
        foreach ($referenceId in $policyReferenceIds) {
            if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) { throw "指定の参照IDがイニシアティブに存在しません: $referenceId" }
        }
        # 現在の診断設定と地域を調べ、移行後の設定と地域別の保存先を組み立てる。
        # 旧設定を残したまま、新設定を追加できる枠があるかも確認する。
        $null = Get-MigrationPlan -Target $target
        # 新しい診断設定名が既存設定と重なっていたら、エラーとして記録する。
        foreach ($plan in $target.DiagnosticPlans) {
            if (@($plan.NewSettings).Count -gt 0) {
                Add-MigrationFailure -Target $target -ResourceId $plan.ResourceId -Stage "診断設定の事前確認" `
                    -Message "新しい診断設定名が既存設定と重複しています。初回の事前チェックを停止します。"
            }
        }
        # 保存先の地域でStandard_ZRSを使えるか、ストレージ名を利用できるか確認する。
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
# 確認結果とエラーを出力する。
Complete-MigrationStep -Step "precheck" -IncludeChecks
