#Requires -Version 5.1
param([string]$BackupPath, [string[]]$SubscriptionIds)
. (Join-Path $PSScriptRoot 'log_migration_common.ps1')
if (-not $BackupPath) { $BackupPath = $migrationBackupPath }

# 全体、または指定サブスクリプションの旧設定を復元してから新診断設定を削除します。
$resourceId = $BackupPath
$expected = $null
try {
    $backup = Read-MigrationBackup -Path $BackupPath
    if ($PSBoundParameters.ContainsKey('SubscriptionIds') -and ($SubscriptionIds.Count -eq 0 -or
        @($SubscriptionIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        @($SubscriptionIds | Select-Object -Unique).Count -ne $SubscriptionIds.Count -or
        @($SubscriptionIds | Where-Object { $_ -notin $backup.Targets.SubscriptionId }).Count -gt 0)) { throw '指定サブスクリプションが空・重複・バックアップ外のいずれかです。' }
    $targets = @($backup.Targets | Where-Object { -not $SubscriptionIds -or $_.SubscriptionId -in $SubscriptionIds })
    $states = @{}
    $resources = [Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        $states[$subscriptionId] = @(Invoke-RollbackDiagnostics -Target $target -Diagnostics @($target.Diagnostics))
        foreach ($result in $states[$subscriptionId]) { if ($result.Error) { $resourceId = $result.Item.ResourceId; $expected = $result.Item.Before; throw "$($result.Item.ResourceId): $($result.Error)" } }
        # 旧2本への関連は、他の復元より先に全件確認します。
        foreach ($oldAssociation in @($target.OldAssociations | Where-Object { $null -ne $_ })) {
            $resourceId = $oldAssociation.ResourceId; $expected = $oldAssociation.Before
            $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $resourceId) -Association -RequireReady
            if ($current -and -not ((Test-BaselineValues $current $expected) -and (Test-BaselineValues $expected $current))) { throw "旧DCR関連が前値と異なります: $resourceId" }
        }
        # 新DCR自体は残します。既存DCRと全関連付けだけを切戻し対象にします。
        $items = @($target.Dcr | Where-Object { $null -ne $_.Before }) + @($target.Associations)
        foreach ($saved in $items) {
            $resourceId = $saved.ResourceId; $expected = $saved.Before
            $association = $saved.ResourceId -match '/dataCollectionRuleAssociations/'
            $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $saved.ResourceId) -Association:$association -RequireReady
            $same = (Test-BaselineValues $current $saved.Before) -and (Test-BaselineValues $saved.Before $current)
            if (-not $same -and $current -and -not (Test-RollbackAfter $current $saved.After $saved.Before)) { throw "DCRまたは関連付けが前値・完成形のいずれとも異なります: $($saved.ResourceId)" }
            $resources.Add(@{ Target = $target; Saved = $saved; Association = $association; Restore = -not $same })
        }
    }

    # 選択した全対象で旧2本の関連を復元し、全件読み戻してから新側の変更に進みます。
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        foreach ($saved in @($target.OldAssociations | Where-Object { $null -ne $_ })) {
            $resourceId = $saved.ResourceId; $expected = $saved.Before
            $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $resourceId) -Association -RequireReady
            if ($current) {
                if (-not ((Test-BaselineValues $current $expected) -and (Test-BaselineValues $expected $current))) { throw "復元直前に旧DCR関連が変更されています: $resourceId" }
                continue
            }
            $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -Body $saved.Before
            $null = Wait-RollbackResource -ResourceId $resourceId -Association
        }
    }
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        foreach ($saved in @($target.OldAssociations | Where-Object { $null -ne $_ })) {
            $resourceId = $saved.ResourceId; $expected = $saved.Before
            $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $resourceId) -Association -RequireReady
            if (-not ((Test-BaselineValues $current $expected) -and (Test-BaselineValues $expected $current))) { throw "旧DCR関連の復元後の読み戻しが一致しません: $resourceId" }
        }
    }

    # 復元が1件でも失敗した場合、新診断設定の削除は一切始めません。
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        $missing = @($states[$subscriptionId] | Where-Object { -not $_.Result.OldPresent } | ForEach-Object { $_.Item })
        foreach ($result in @(Invoke-RollbackDiagnostics -Target $target -Diagnostics $missing -Restore)) {
            if ($result.Error) { $resourceId = $result.Item.ResourceId; $expected = $result.Item.Before; throw "$($result.Item.ResourceId): $($result.Error)" }
        }
    }
    foreach ($item in @($resources | Where-Object Restore)) {
        $subscriptionId = $item.Target.SubscriptionId
        $saved = $item.Saved
        $resourceId = $saved.ResourceId; $expected = $saved.Before
        $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $saved.ResourceId) -Association:$item.Association -RequireReady
        if ((Test-BaselineValues $current $saved.Before) -and (Test-BaselineValues $saved.Before $current)) { continue }
        if ($current -and -not (Test-RollbackAfter $current $saved.After $saved.Before)) { throw "復元直前にDCR・関連付けが変更されています: $($saved.ResourceId)" }
        if ($null -eq $saved.Before) {
            $null = Invoke-ArmRequest -Method Delete -ResourceId $saved.ResourceId
        }
        else {
            $null = Invoke-ArmRequest -Method Put -ResourceId $saved.ResourceId -Body $saved.Before
            $null = Wait-RollbackResource -ResourceId $saved.ResourceId -Association:$item.Association
        }
    }

    # バックアップ内の旧診断設定・DCR・関連付けを、全対象読み戻してから次へ進みます。
    foreach ($target in $targets) {
        $states[$target.SubscriptionId] = @(Invoke-RollbackDiagnostics -Target $target -Diagnostics @($target.Diagnostics))
        foreach ($result in $states[$target.SubscriptionId]) {
            $resourceId = $result.Item.ResourceId; $expected = $result.Item.Before
            if ($result.Error -or -not $result.Result.OldPresent) { throw "旧診断設定の復元が未完了です: $($result.Item.ResourceId) / $($result.Error)" }
        }
    }
    foreach ($item in $resources) {
        $subscriptionId = $item.Target.SubscriptionId
        $resourceId = $item.Saved.ResourceId; $expected = $item.Saved.Before
        $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $item.Saved.ResourceId) -Association:$item.Association -RequireReady
        if (-not ((Test-BaselineValues $current $item.Saved.Before) -and (Test-BaselineValues $item.Saved.Before $current))) { throw "DCR・関連付けの復元後の読み戻しが一致しません: $($item.Saved.ResourceId)" }
    }

    # 削除直前にも旧設定と新設定を確認します。失敗時は以降の削除を止めます。
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        foreach ($result in @($states[$subscriptionId] | Where-Object { $_.Result.NewPresent })) {
            $saved = $result.Item
            $resourceId = $saved.ResourceId; $expected = $saved.Before
            $settings = @(Get-DiagnosticSettings -ResourceId $saved.ResourceId)
            $old = @($settings | Where-Object { $_.name -eq $saved.OldName })
            $new = @($settings | Where-Object { $_.name -eq $newDiagnosticSettingName })
            if ($old.Count -ne 1 -or (Get-DiagnosticSignature $old[0]) -cne (Get-DiagnosticSignature $saved.Before) -or
                ($new.Count -gt 0 -and ($new.Count -ne 1 -or (Get-DiagnosticSignature $new[0]) -cne (Get-DiagnosticSignature $saved.After)))) { throw "削除直前に診断設定が変更されています: $($saved.ResourceId)" }
            if ($new.Count -eq 0) { continue }
            $id = "$($saved.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($newDiagnosticSettingName))"
            $null = Invoke-ArmRequest -Method Delete -ResourceId $id -ApiVersion '2021-05-01-preview'
            Write-Host "新設定削除OK: $($saved.ResourceId)"
        }
    }
    # この移行で新規作成した適用除外だけを最後に解除します。既存の除外は維持します。
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        foreach ($saved in @($target.Exemptions | Where-Object { -not $_.Existed })) {
            $resourceId = $saved.ResourceId; $expected = $null
            $current = Get-OptionalArmResource -ResourceId $saved.ResourceId -ApiVersion '2022-07-01-preview'
            if (-not $current) { continue }
            $assignment = @($policyAssignments | Where-Object { $saved.ResourceId.EndsWith($_.Name) })[0]
            Assert-PolicyExemption -Exemption $current -Assignment $assignment
            $null = Invoke-ArmRequest -Method Delete -ResourceId $saved.ResourceId -ApiVersion '2022-07-01-preview'
        }
    }
}
catch {
    Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage '切戻し' -Message $_.Exception.Message -Expected $expected
}
Complete-MigrationStep -Step 'rollback'
