#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()

# ---
# 1. サブスクリプションごとに作業記録を読み、今回の環境・CSVと一致するか確認する。
# 記録を使えない場合はNGを残し、次のサブスクリプションへ進む。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
    }
    catch {
        $results += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = ''
            Result = 'NG'
            Reason = $_.Exception.Message
            Expected = ''
        }
        continue
    }

    # ---
    # 2. 旧ワークスペース・旧DCRへの送信設定を調べ直す。
    # 記録にない旧設定が追加・再作成されていたらNGにする。記録済みの旧設定は次で確認する。
    # ---
    try {
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        foreach ($current in $currentPlan.OldSettings | Where-Object { $_.Id -notin $record.OldSettings.Id }) {
            $results += [pscustomobject]@{
                SubscriptionId = $subscriptionId
                ResourceId = $current.Id
                Result = 'NG'
                Reason = '作業記録にない旧送信設定が残っています。'
                Expected = '存在しない'
            }
        }
    }
    catch {
        $results += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = ''
            Result = 'NG'
            Reason = "旧送信設定を調査できません: $($_.Exception.Message)"
            Expected = ''
        }
    }

    # ---
    # 3. 旧設定が削除され、保存先・新送信設定・適用除外が記録どおり残っているか確認する。
    # 新設した保存先は保持期間やセキュリティ設定も比べ、再利用した保存先は記録した地域を比べる。
    # ---
    foreach ($resource in @($record.OldSettings) + @($record.Destinations) + @($record.NewSettings)) {
        $isOldSetting = $resource.Id -in $record.OldSettings.Id
        $result = 'OK'
        $reason = '記録と一致'
        $expectedText = ConvertTo-Json $resource.Body -Depth 40 -Compress
        if ($isOldSetting) {
            $reason = '旧設定は削除済み'
            $expectedText = '存在しない'
        }
        try {
            $current = Invoke-ArmRequest -Resource $resource -Optional
            if ($isOldSetting) {
                if ($current) {
                    throw '旧設定が残っています。'
                }
            }
            else {
                $expected = $resource.Body
                # 新設RGは存在を確認する。再利用RGは、記録した地域も確認する。
                if ($resource.Kind -eq 'Group' -and -not $resource.Reuse) {
                    $expected = @{}
                }
                # 新設テーブルは、合計保持日数を明示した設定であることも確認する。
                if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                    ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                    throw '必要な設定がないか、作業記録の値と異なります。'
                }
            }
        }
        catch {
            $result = 'NG'
            $reason = $_.Exception.Message
        }
        $results += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = $resource.Id
            Result = $result
            Reason = $reason
            Expected = $expectedText
        }
    }
}

# ---
# 4. 全サブスクリプションの確認結果をCSVへ保存し、NGがあれば未完了として終了する。
# Azureの設定と作業記録は変更しない。問題を直した後は、同じ条件で再実行できる。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'final_check_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '移行後の設定に未完了の項目があります。final_check_results.csvを確認してください。'
}
Write-Host '移行後の最終確認が完了しました。final_check_results.csvは全件OKです。'
