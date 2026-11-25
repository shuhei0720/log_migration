#Requires -Version 7.0
# SubscriptionIdsを省略すると、保存済みJSONの全Subを戻す。
param([string[]]$SubscriptionIds)
# 空指定で全Subを戻さないよう、引数を指定したかも記録しておく。
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1')
$records = @(Get-RollbackRecords -SubscriptionIds $SubscriptionIds -FilterProvided:$subscriptionFilterProvided)
$failurePath = Join-Path $PSScriptRoot 'rollback_failures.csv'
try {
    # ---
    # 全対象を先に確認する。記録外の変更があれば、復元を始めずに止める。
    # ---
    foreach ($record in $records) {
        $subscriptionId = $record.Target.SubscriptionId
        foreach ($setting in @($record.OldSettings) + @($record.NewSettings)) {
            Assert-RollbackSetting -Setting $setting -SubscriptionId $subscriptionId
        }
    }

    # ---
    # 全Subの旧DCR関連付け→旧診断設定を、記録した本文から復元する。一致済みは省く。
    # ---
    foreach ($kind in @('Association', 'Diagnostic')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($setting in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                Restore-MigrationSetting -Setting $setting -SubscriptionId $subscriptionId -RestoreOld
            }
        }
    }

    # ---
    # 旧送信の復元後、新側を変更前へ戻す。保存先・ログ・新規DCR本体・元からあるWaiverは残す。
    # ---
    foreach ($kind in @('Dcr', 'Association', 'Diagnostic', 'Exemption')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($setting in @($record.NewSettings | Where-Object Kind -eq $kind)) {
                Restore-MigrationSetting -Setting $setting -SubscriptionId $subscriptionId
            }
        }
    }
}
catch {
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $setting.Id
        Reason = $_.Exception.Message
    } | Export-Csv $failurePath -Encoding utf8BOM
    throw
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '切り戻しが完了しました。保存先と保存済みログは残しています。'
