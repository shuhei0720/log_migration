#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$targets = @(Read-MigrationTargets)
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    try {
        # ---
        # 当日の旧設定と作成先を調べ、新しい保存先・送信設定の本文を準備する。
        # ---
        $record = Read-MigrationRecord -Target $target
        $plan = Get-MigrationPlan -Target $target -Record $record
        $plan.NewSettings = @(New-PolicyExemptionSettings -SubscriptionId $subscriptionId)
        $plan.Destinations = @(New-LogAnalyticsDestinations -Target $target)
        $plan.Destinations += @(New-StorageDestinations -Storages $plan.Discovery.Storages)
        $plan.Destinations += @(New-VmLogTableSettings -Target $target -OldSettings $plan.OldSettings)
        $plan.NewSettings += @(New-DcrSettings -Target $target -Discovery $plan.Discovery)
        $plan.NewSettings += @(New-DiagnosticSettings -Target $target -Plan $plan)

        # ---
        # 変更前の値を加え、JSONの保存が成功してからAzureへの書込みを始める。
        # ---
        Set-MigrationBeforeValues -Plan $plan -Record $record
        $plan.Remove('Discovery')
        $record = Save-MigrationPlan -Plan $plan -Record $record -SubscriptionId $subscriptionId

        # ---
        # ポリシーを除外し、利用登録後に保存先、DCR・関連付けの順で設定する。
        # 一致済みは省略する。失敗したSubの残りは止め、旧設定を残して次のSubへ進む。
        # ---
        foreach ($resource in @($record.NewSettings | Where-Object Kind -eq 'Exemption')) {
            Set-MigrationResource -Resource $resource
        }
        # 利用登録で失敗した場合に、保存先のIDを失敗CSVへ出せるようにする。
        $resource = @($record.Destinations)[0]
        Register-MigrationProviders -Record $record -SubscriptionId $subscriptionId
        foreach ($resource in $record.Destinations) {
            Set-MigrationResource -Resource $resource
        }
        foreach ($resource in @($record.NewSettings | Where-Object { $_.Kind -notin @('Exemption', 'Diagnostic') })) {
            Set-MigrationResource -Resource $resource
        }

        # 保存先の準備後、新診断設定を並列に作成し、失敗した対象だけを集める。
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
