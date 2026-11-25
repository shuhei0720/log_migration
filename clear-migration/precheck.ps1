#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$targets = @(Read-MigrationTargets)
$regionNames = @(Get-RegionAbbreviations -Targets $targets)

# ---
# 対象Subの旧設定を調べ、ポリシー・作成先・名前・空き枠を順に確認する。
# Azureの変更や作業記録の保存は行わない。
# ---
$results = foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        Assert-NewResourceGroup -Target $target
        $sources = Get-MigrationSources -Target $target
        Assert-PolicyAssignments -SubscriptionId $subscriptionId
        $null = @(Get-StorageTargets -Target $target -Diagnostics $sources.Diagnostics -RegionNames $regionNames)
        $null = Get-DcrTargets -Target $target -OldSettings $sources.OldSettings
        $null = @(Get-DiagnosticTargets -Target $target -Diagnostics $sources.Diagnostics -OldSettings $sources.OldSettings)
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'OK'
            Reason = '事前確認完了'
        }
    }
    catch {
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'NG'
            Reason = $_.Exception.Message
        }
    }
}
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
