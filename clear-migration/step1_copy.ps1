#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$targets = @(Read-MigrationTargets)
$regionNames = @(Get-RegionAbbreviations -Targets $targets)
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    try {
        # ---
        # 当日の旧設定を集め、RG・ポリシー・地域別Storage名・新設定の名前と空き枠を確認する。
        # この段階ではAzureを変更しない。
        # ---
        $record = Read-MigrationRecord -Target $target
        Assert-NewResourceGroup -Target $target -Record $record
        $sources = Get-MigrationSources -Target $target
        Assert-PolicyAssignments -SubscriptionId $subscriptionId
        $storages = @(Get-StorageTargets -Target $target -Diagnostics $sources.Diagnostics -Record $record -RegionNames $regionNames)
        $dcrTargets = Get-DcrTargets -Target $target -OldSettings $sources.OldSettings
        $diagnosticTargets = @(Get-DiagnosticTargets -Target $target -Diagnostics $sources.Diagnostics -OldSettings $sources.OldSettings -Record $record)

        # ---
        # 保存先と送信設定の本文を組み立て、変更前の値を取得する。
        # DCR・関連付けは今回変更しない値を引き継ぎ、復元に必要な情報を記録へまとめる。
        # ---
        $destinations = @(New-LogAnalyticsDestinations -Target $target)
        $destinations += @(New-StorageDestinations -Storages $storages)
        $destinations += @(New-VmLogTableSettings -Target $target -OldSettings $sources.OldSettings)
        $newSettings = @(New-PolicyExemptionSettings -SubscriptionId $subscriptionId)
        $newSettings += @(New-DcrSettings -Target $target -DcrTargets $dcrTargets)
        $diagnosticValues = @{
            Target = $target
            OldSettings = $sources.OldSettings
            DiagnosticTargets = $diagnosticTargets
            Storages = $storages
        }
        $newSettings += @(New-DiagnosticSettings @diagnosticValues)
        $beforeValues = Get-MigrationBeforeValues -Settings $newSettings -Record $record -SubscriptionId $subscriptionId
        $newSettings = @(Merge-ExistingSettingValues -Settings $newSettings -BeforeValues $beforeValues)
        $recordValues = @{
            Target = $target
            OldSettings = $sources.OldSettings
            Destinations = $destinations
            NewSettings = $newSettings
            BeforeValues = $beforeValues
        }
        $plan = New-MigrationRecord @recordValues

        # ---
        # 前回の記録と照合・統合し、JSONの保存が成功してからAzureへの書込みを始める。
        # ---
        $record = Merge-MigrationRecord -Plan $plan -Record $record
        Save-MigrationRecord -Record $record

        # ---
        # Waiver、利用登録、保存先、DCR・関連付けの順で反映する。一致済みは省略する。
        # 失敗したSubの残りは止め、旧設定を残して次のSubへ進む。
        # ---
        foreach ($resource in @($record.NewSettings | Where-Object Kind -eq 'Exemption')) {
            Set-MigrationResource -Resource $resource -SubscriptionId $subscriptionId
        }
        # 利用登録で失敗した場合も、失敗CSVへ保存先IDを出す。
        $resource = @($record.Destinations)[0]
        Register-MigrationProviders -Record $record -SubscriptionId $subscriptionId
        foreach ($resource in $record.Destinations) {
            Set-MigrationResource -Resource $resource -SubscriptionId $subscriptionId
        }
        foreach ($resource in @($record.NewSettings | Where-Object { $_.Kind -notin @('Exemption', 'Diagnostic') })) {
            Set-MigrationResource -Resource $resource -SubscriptionId $subscriptionId
        }

        # 保存先の準備後、新診断設定を並列に作り、失敗した対象だけを集める。
        $diagnostics = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')
        $copied = @(Copy-MigrationDiagnostics -Settings $diagnostics -SubscriptionId $subscriptionId)
        $failures += @($copied | Where-Object Reason)
    }
    catch {
        $failures += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = $resource.Id
            Reason = $_.Exception.Message
            Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
        }
    }
}

# ---
# 失敗は手動対応用CSVへ出す。全件成功なら前回の失敗CSVを消し、step2の確認へ進む。
# ---
$failurePath = Join-Path $PSScriptRoot 'copy_failures.csv'
if ($failures.Count) {
    $failures | Export-Csv $failurePath -Encoding utf8BOM
    throw "未完了のSubがあります。$failurePath を確認して再実行してください。"
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '旧設定を保持しました。step2で確認後、step3へ進んでください。'
