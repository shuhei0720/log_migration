#Requires -Version 5.1
param([string]$BackupPath, [string[]]$SubscriptionIds)
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $BackupPath) { $BackupPath = $migrationBackupPath }

# 必要な場合だけ実行する切戻し用です。通常の移行はstep3で終了します。
# 旧診断設定は不足分だけ復元し、同名の異なる設定は上書きしません。
function Invoke-RollbackDiagnostics {
    param([object]$Target, [object[]]$Diagnostics, [switch]$Restore)
    $subscriptionId = $Target.SubscriptionId
    $items = @(foreach ($saved in $Diagnostics) {
        @{ ResourceId = $saved.ResourceId; OldName = $saved.OldName; Before = $saved.Before; After = $saved.After; Restore = [bool]$Restore }
    })
    Invoke-DiagnosticBatch -Items $items -SettingName $newDiagnosticSettingName -Action {
        param($saved, $newName)
        $settings = @(Get-DiagnosticSettings -ResourceId $saved.ResourceId)
        $old = @($settings | Where-Object { $_.name -eq $saved.OldName })
        $new = @($settings | Where-Object { $_.name -eq $newName })
        if ($old.Count -gt 1 -or ($old.Count -eq 1 -and (Get-DiagnosticSignature $old[0]) -cne (Get-DiagnosticSignature $saved.Before))) { throw '同名の旧診断設定が前値と異なります。上書きしません。' }
        if ($new.Count -gt 1 -or ($new.Count -eq 1 -and (Get-DiagnosticSignature $new[0]) -cne (Get-DiagnosticSignature $saved.After))) { throw '新診断設定が移行時の完成形と異なります。削除しません。' }
        if ($old.Count -eq 0 -and $settings.Count -ge 5) { throw '旧設定を復元する空きがありません。新設定は残します。' }
        if ($old.Count -eq 0 -and $saved.Restore) {
            $id = "$($saved.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($saved.OldName))"
            $null = Invoke-ArmRequest -Method Put -ResourceId $id -ApiVersion '2021-05-01-preview' -Body @{ properties = $saved.Before }
            $old = @(Get-DiagnosticSettings -ResourceId $saved.ResourceId -Name $saved.OldName)
            if ($old.Count -ne 1 -or (Get-DiagnosticSignature $old[0]) -cne (Get-DiagnosticSignature $saved.Before)) { throw '旧診断設定の復元後の読み戻しが一致しません。' }
        }
        [pscustomobject]@{ OldPresent = $old.Count -eq 1; NewPresent = $new.Count -eq 1 }
    }
}

# 新側の完成形か確認します。DCRの収集元・宛先・フローへの外部追加も許可しません。
function Test-RollbackAfter {
    param([object]$Current, [object]$After, [object]$Before)
    if (-not (Test-BaselineValues $Current $After)) { return $false }
    foreach ($key in @('dataSources','destinations','dataFlows')) {
        if ($null -ne $After.properties.$key -and -not (Test-BaselineValues $After.properties.$key $Current.properties.$key)) { return $false }
    }
    foreach ($key in @('dataCollectionEndpointId','streamDeclarations','description')) {
        if ($null -eq $After.properties.$key -and $null -ne $Current.properties.$key -and
            -not ((Test-BaselineValues $Current.properties.$key $Before.properties.$key) -and (Test-BaselineValues $Before.properties.$key $Current.properties.$key))) { return $false }
    }
    $true
}

# この切戻しで復元したDCR・関連だけ、最大30秒の読み戻しを行います。
function Wait-RollbackResource {
    param([string]$ResourceId, [switch]$Association)
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $restored = Get-OptionalArmResource -ResourceId $ResourceId
        if ($restored -and $restored.properties.provisioningState -notin @('Creating','Updating','Accepted')) { break }
        Start-Sleep -Seconds 2
    }
    Get-RollbackBody $restored -Association:$Association -RequireReady
}

# 1. ①で保存した変更前情報から、全体または指定Subの現在値を確認します。
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

    # 2. 選択した全Subの旧DCR関連を復元し、全件読み戻してから次へ進みます。
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

    # 3. 旧診断設定と保存済みDCR・関連付けを復元します。失敗時は新診断設定を残します。
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

    # 4. 選択した全Subの旧診断設定・DCR・関連付けを読み戻し、復元完了を確認します。
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

    # 5. 全件の復元確認後、新診断設定を削除します。削除直前の不一致でも後続を止めます。
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
