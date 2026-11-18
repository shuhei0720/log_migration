#Requires -Version 5.1
. (Join-Path $PSScriptRoot "log_migration_common.ps1")

# 初回の事前チェック後に実行します。途中で止まった場合は、この工程から再実行できます。
# 既に一致する設定は変更せず、不足する設定だけ補います。旧診断設定は削除しません。
try { $backup = Read-MigrationBackup -CheckCsv }
catch {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message $_.Exception.Message
    Complete-MigrationStep -Step 'copy'
}
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    try { $null = Get-MigrationPlan -Target $target }
    catch { Add-MigrationFailure -Target $target -Stage "複製前の調査" -Message $_.Exception.Message }
}
try { Assert-MigrationBackup -Backup $backup -Targets $targets }
catch { Add-MigrationFailure -Stage 'バックアップ照合' -Message $_.Exception.Message }
# 入力・対象調査に失敗した場合は、作成・更新を始めません。
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step "copy" }

foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        if (-not (Set-MigrationBaseline -Target $target)) {
            foreach ($plan in $target.DiagnosticPlans) {
                if (@($plan.NewSettings).Count -eq 1 -and
                    (Get-DiagnosticSignature -Setting $plan.NewSettings[0]) -ceq $plan.NewSignature) { continue }
                Add-MigrationFailure -Target $target -ResourceId $plan.ResourceId -Stage "診断設定の複製未実施" `
                    -Message "保存先などの準備に失敗したため、このサブスクリプションの複製は開始していません。" -Expected $plan.Expected
            }
            continue
        }
        Invoke-DiagnosticBatch -Items $target.DiagnosticPlans.ToArray() -SettingName $newDiagnosticSettingName -Action {
            param($plan, $settingName)
            $settings = @(Get-DiagnosticSettings -ResourceId $plan.ResourceId)
            $source = $plan.SourceSettings[0]
            $currentSource = @($settings | Where-Object { $_.name -eq $source.name })
            if ($currentSource.Count -ne 1 -or (Get-DiagnosticSignature -Setting $currentSource[0]) -cne $plan.SourceSignature) {
                throw "旧設定が調査後に変更されています。古い内容では複製しません。"
            }
            $existing = @($settings | Where-Object { $_.name -eq $settingName })
            if ($existing.Count -gt 0) {
                if ($existing.Count -ne 1 -or (Get-DiagnosticSignature -Setting $existing[0]) -cne $plan.NewSignature) {
                    throw "同名の新設定が期待値と一致しません。上書きせず手動対応用CSVに記録します。"
                }
                return "既存設定と一致・変更なし"
            }
            if ($settings.Count -ge 5) { throw "診断設定が上限の5件です。旧設定は残します。" }
            $newId = "$($plan.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($settingName))"
            $null = Invoke-ArmRequest -Method Put -ResourceId $newId -ApiVersion "2021-05-01-preview" -Body @{ properties = $plan.Expected }
            $created = Get-DiagnosticSettings -ResourceId $plan.ResourceId -Name $settingName
            if ((Get-DiagnosticSignature -Setting $created) -cne $plan.NewSignature) {
                throw "新設定の読み戻しで収集条件・送信先が一致しません。旧設定は残します。"
            }
            "複製・確認完了"
        } | ForEach-Object {
            if ($_.Error) {
                Add-MigrationFailure -Target $target -ResourceId $_.Item.ResourceId -Stage "診断設定の複製" -Message $_.Error -Expected $_.Item.Expected
            }
            else { Write-Host "$($_.Result): $($_.Item.ResourceId) / $newDiagnosticSettingName" }
        }
    }
    catch { Add-MigrationFailure -Target $target -Stage "複製処理" -Message $_.Exception.Message }
}
Complete-MigrationStep -Step "copy"
Write-Host "旧設定を保持しています。verifyで全件確認してから、deleteを実行してください。"
