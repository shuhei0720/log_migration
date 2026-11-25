#Requires -Version 7.0
# SubscriptionIdsを省略すると、保存済みJSONの全Subを戻す。
param([string[]]$SubscriptionIds)
# 空指定で全Subを戻さないよう、「指定されていない」と「空で指定された」を区別する。
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1')
$records = @(Get-RollbackRecords -SubscriptionIds $SubscriptionIds -FilterProvided:$subscriptionFilterProvided)
$failurePath = Join-Path $PSScriptRoot 'rollback_failures.csv'
try {
    # ---
    # 全対象を先に確認する。記録外の変更があれば、何も戻さず停止する。
    # ---
    foreach ($record in $records) {
        $subscriptionId = $record.Target.SubscriptionId
        foreach ($setting in @($record.OldSettings) + @($record.NewSettings)) {
            Assert-RollbackSetting -Setting $setting
        }
    }

    # ---
    # 全Subの旧関連付け→旧診断設定を記録した本文から復元する。一致済みは省く。
    # ---
    foreach ($kind in @('Association', 'Diagnostic')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($setting in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                Restore-MigrationSetting -Setting $setting -RestoreOld
            }
        }
    }

    # ---
    # 旧送信を戻した後、新側を変更前へ戻す。保存先・ログ・新規DCR本体・元からあるWaiverは残す。
    # ---
    foreach ($kind in @('Dcr', 'Association', 'Diagnostic', 'Exemption')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($setting in @($record.NewSettings | Where-Object Kind -eq $kind)) {
                Restore-MigrationSetting -Setting $setting
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
