#Requires -Version 7.0

# ---
# 全Subの確認が成功した場合だけ削除する。全Subの旧DCR関連付けを外してから、旧診断設定を外す。
# ---
$records = @(& (Join-Path $PSScriptRoot 'step2_verify.ps1') -PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$resource = $null
try {
    foreach ($kind in @('Association', 'Diagnostic')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($resource in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                # 旧本文と、送信を続ける場合の新設定を再確認してから削除する。削除済みは省く。
                Remove-OldSetting -Record $record -Setting $resource
            }
        }
    }
}
catch {
    # 1件でも失敗したら、他Subも含めて残りを止める。
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $resource.Id
        Reason = $_.Exception.Message
        Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
    } | Export-Csv (Join-Path $PSScriptRoot 'delete_failures.csv') -Encoding utf8BOM
    throw
}
Write-Host '旧設定を削除しました。保存先と新設定は残しています。'
