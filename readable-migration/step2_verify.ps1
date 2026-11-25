#Requires -Version 7.0
# PassThruはstep3用。全件OKなら削除対象の記録も返す。
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$targets = @(Read-MigrationTargets)
$results = @()
$records = @()

# ---
# 記録と現在の旧設定を照合してから、保存先・新設定の準備状況を確認する。Azureは変更しない。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        Assert-OldSettingsUnchanged -Record $record -CurrentSettings $currentPlan.OldSettings
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
# 全SubのOK/NGをCSVへ出す。NGが1件でもあればエラーにし、step3へ削除対象を返さない。
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
