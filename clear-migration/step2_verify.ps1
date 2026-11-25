#Requires -Version 7.0
# PassThruはstep3用。全件OKなら、削除に使う記録も返す。
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$targets = @(Read-MigrationTargets)
$results = @()
$records = @()

# ---
# 記録と当日の旧設定を照合し、保存先・新設定の準備状況を1件ずつ確認する。
# 不一致も結果へ残し、ほかの対象を確認する。Azureは変更しない。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        $sources = Get-MigrationSources -Target $target
        Assert-OldSettingsUnchanged -Record $record -CurrentSettings $sources.OldSettings
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            $results += Test-MigrationResource -Resource $resource -SubscriptionId $subscriptionId
        }
        $records += $record
    }
    catch {
        $results += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = ''
            Result = 'NG'
            Reason = $_.Exception.Message
            Expected = ''
        }
    }
}

# ---
# 全SubのOK/NGをCSVへ出す。NGがあれば停止し、step3へ記録を返さない。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'verify_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '未完了の設定があります。verify_results.csvを確認してください。'
}
if ($PassThru) {
    $records
}
else {
    Write-Host '全件確認が完了しました。'
}
