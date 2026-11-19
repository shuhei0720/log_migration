#Requires -Version 5.1
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()
$records = @()

# ---
# 記録後に増えた旧設定や、変更された旧設定を確認する
# 削除済みの旧設定は許可し、保存先・新設定は記録した全対象を確認する。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        foreach ($current in $currentPlan.OldSettings) {
            $saved = @($record.OldSettings | Where-Object Id -eq $current.Id)
            if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
                throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
            }
        }
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            try {
                $current = Invoke-ArmRequest -Resource $resource -Optional
                $expected = $resource.Body
                if ($resource.Kind -eq 'Group') {
                    $expected = @{}
                }
                if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                    ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                    throw '必要な設定がないか、予定の値と異なります。'
                }
                $results += [pscustomobject]@{
                    SubscriptionId = $subscriptionId
                    ResourceId = $resource.Id
                    Result = 'OK'
                    Reason = '一致'
                    Expected = ''
                }
            }
            catch {
                $results += [pscustomobject]@{
                    SubscriptionId = $subscriptionId
                    ResourceId = $resource.Id
                    Result = 'NG'
                    Reason = $_.Exception.Message
                    Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
                }
            }
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
$results | Export-Csv (Join-Path $PSScriptRoot 'verify_results.csv') -NoTypeInformation -Encoding UTF8
if ($results.Result -contains 'NG') {
    throw '未完了の設定があります。verify_results.csvを確認してください。'
}
if ($PassThru) {
    $records
}
else {
    Write-Host '全件確認が完了しました。'
}
