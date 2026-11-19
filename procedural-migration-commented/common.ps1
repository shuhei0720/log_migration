#Requires -Version 7.0
# ---
# このファイルの読み方
# common.ps1は、実行用スクリプトが共通の変数と5つの関数を読み込むためのファイル。
# 各実行用スクリプトの「. (Join-Path ...)」はドットソースといい、ここで定義した
# 変数や関数を呼び出した側でも使えるようにする。このファイルだけを実行する手順ではない。
# 関数は定義しただけでは本体を実行しない。一方、関数の外にある変数設定やCSV読込は、
# このファイルを読み込んだときに実行される。
# SkipCsvはスイッチ型の引数。-SkipCsvを付けるとtrueになり、CSV読込を省略する。
# 並列処理の作業場所にも関数を読み込む際、CSVやサブスクリプション一覧の再取得を避ける。
# 先頭の#Requiresは、PowerShell 7以上が必要であることを実行時に確認する宣言。
# ---
param([switch]$SkipCsv)

# ---
# 利用者が指定する値
# 移行元のワークスペースと、今回作業する環境を指定する。
#
# 設定値と、Azureで使うID
# $から始まる名前が変数。右側の値を「=」で入れ、後の処理から同じ名前で参照する。
# targetWorkspaceIdは「移行元の」Log AnalyticsワークスペースのリソースID。
# このワークスペース宛ての既存診断設定を見つけるために使う。新しい保存先のIDではない。
# リソースIDは /subscriptions/.../resourceGroups/.../providers/... のような文字列で、
# Azure内の対象を特定する。サブスクリプション名やリソース名だけとは区別する。
# environmentはprod・stg・devのいずれか。下の環境別データと記録の保存場所を切り替える。
# newDiagnosticSettingNameは全リソース共通の新診断設定名、locationは共通の作成地域。
# parallelLimitは診断設定の取得・設定で同時に動かす処理の上限で、対象数そのものではない。
# CSVに指定する保存先の名前と、このファイルの移行元設定の両方を確認して使用する。
# ---
$targetWorkspaceId = '/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01'
$environment = 'dev'
$newDiagnosticSettingName = 'storage-archive'
$location = 'japaneast'
$parallelLimit = 5
# ---
# 自分自身の場所と、共通のAPIバージョン
# PSCommandPathは、実行中のこのファイルのフルパス。並列処理の中から同じファイルを読む。
# PSScriptRoot（後で使用）はこのファイルがあるフォルダで、CSVや記録の相対位置を決める。
# @{ キー = 値 } はハッシュテーブル（辞書）。例として apiVersions.Storage は
# Storageというキーに対応するAPIバージョンを取り出す。
# APIバージョンはサービス側の要求・応答形式を指定する文字列で、PowerShellの版とは別。
# Kindはこのスクリプト内の処理種別で、Azureのリソース種別を短い名前で扱うために使う。
# ---
$commonScript = $PSCommandPath
$diagnosticPath = '/providers/Microsoft.Insights/diagnosticSettings'
$associationPath = '/providers/Microsoft.Insights/dataCollectionRuleAssociations'
$apiVersions = @{
    Exemption = '2022-07-01-preview'
    Group = '2022-09-01'
    Workspace = '2023-09-01'
    Storage = '2023-05-01'
    Blob = '2023-05-01'
    Lifecycle = '2023-05-01'
    Defender = '2025-01-01'
    Table = '2025-07-01'
    Dcr = '2024-03-11'
    Association = '2024-03-11'
    Diagnostic = '2021-05-01-preview'
}

# ---
# 環境ごとの旧DCRとポリシー割り当て
# 同じ環境の情報を一か所に並べ、リソースIDを組み立てる。
#
# 環境ごとに異なる値を、辞書の中へまとめる
# environmentSettings['dev']でdevの辞書、その中の.DcrNamesで旧DCR名の配列を取り出す。
# @('値1', '値2')は複数の値を入れる配列で、配列[0]が先頭、[1]が2番目。
# DCRはデータ収集ルール、関連付けはVM・VMSSなどとDCRを結ぶ設定。
# ここにある2つの旧DCRから関連付けを探し、移行対象を決める。
# Assignmentsはポリシー「割り当て」のID末尾であり、ポリシー定義そのもののIDではない。
# ManagementGroupも指定済みの実名を使う。prodのproducrionという綴りもその指定値。
# ---
$environmentSettings = @{
    prod = @{
        HubSubscriptionId = '7f043232-66a7-4d79-a660-fcb22d1644d0'
        ResourceGroup = 'rg-hub-prod-resource-01'
        DcrNames = @('dcr-hub-prod-vmInsights-01', 'logrule-hub-prod-vm-01')
        ManagementGroup = 'producrion'
        Assignments = @('6d924f0fa7a04145a1a00741', '71c38b62acf0433eb459b65b', '8dbf4e4a9a164f62969dc0ec')
    }
    stg = @{
        HubSubscriptionId = '40c16c7d-02f5-4529-ba94-8b754ccdb03e'
        ResourceGroup = 'rg-hub-stg-resource-01'
        DcrNames = @('dcr-hub-stg-vmInsights-01', 'logrule-hub-stg-vm-01')
        ManagementGroup = 'staging'
        Assignments = @('c0ddff1ad793418fb57fa3eb', '4ad819eb50c447a8a80b6c90', '75e82ef79a3447c3acab3d83')
    }
    dev = @{
        HubSubscriptionId = '43fc6c39-e53d-449d-9871-6d66f95ed2f3'
        ResourceGroup = 'rg-hub-sand-resource-01'
        DcrNames = @('dcr-hub-sand-vmInsights-01', 'logrule-hub-sand-vm-01')
        ManagementGroup = 'sandbox'
        Assignments = @('f6f0b49f9bd34e8fbb2c0304', '17fb86c1d07349769ff9b1a4', '0073f42c7cba4eef8454e06e')
    }
}
# ---
# イニシアティブ内で除外する個別ポリシー
# ポリシーのイニシアティブは、複数のポリシー定義をまとめたもの。
# 下の日本語文字列は表示名として検索するための語ではなく、まとめの中の参照ID。
# 後で3件目の割り当てだけ、この12件を指定して除外する。
# 1件目と2件目は参照IDを指定せず、割り当て全体を除外する。
# ---
$policyReferenceIds = @(
    'Linux 仮想マシンを構成してデータ収集ルールまたはデータ収集エンドポイントと関連付ける_1'
    'Windows 仮想マシンを構成してデータ収集ルールまたはデータ収集エンドポイントと関連付ける_1'
    'App Serviceに対して診断設定を有効化する必要がある_1'
    'Kubernetes サービスに対して診断設定を有効化する必要がある_1'
    'ストレージ アカウントに対して診断設定を有効化する必要がある_1'
    'ストレージ アカウントのサブリソースに対して診断設定を有効化する必要がある_1'
    'App Serviceの関数アプリに対して診断設定を有効化する必要がある_1'
    'VMSSの均一モードでのデプロイを監査する_1'
    'Table service の診断設定を監査する_1'
    'File service の診断設定を監査する_1'
    'Blob service の診断設定を監査する_1'
    'Queue service の診断設定を監査する_1'
)
$settings = $environmentSettings[$environment]
if (-not $settings) {
    throw 'environmentはprod・stg・devから指定してください。'
}
# ---
# 名前から完全なIDを組み立てる
# foreachは配列の各要素について処理を繰り返す。全体を@(...)で囲むことで、結果を
# 0件・1件の場合も配列として受け取る。単なる丸括弧は式の計算順序をまとめるもの。
# 二重引用符の文字列では$変数が値に置き換わる。$($settings.ResourceGroup)のような
# $()は、プロパティ参照などを計算して文字列へ埋め込むときに使う。
# forのindexは0・1・2となり、3つの割り当てを辞書の配列として作る。
# ReferenceIdsは最初の2件が空配列、3件目だけ12件の配列となる。
# ---
$oldDcrIds = @(foreach ($name in $settings.DcrNames) {
    "/subscriptions/$($settings.HubSubscriptionId)/resourceGroups/$($settings.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$name"
})
$policyAssignments = @(for ($index = 0; $index -lt 3; $index++) {
    @{
        Id = "/providers/Microsoft.Management/managementGroups/$($settings.ManagementGroup)/providers/Microsoft.Authorization/policyAssignments/$($settings.Assignments[$index])"
        ReferenceIds = @(if ($index -eq 2) {
            $policyReferenceIds
        })
    }
})
# ---
# 取り違え防止のため、今回の条件と記録場所をまとめる
# Contextには環境・移行元・旧DCR・新診断設定名を保存する。再実行で条件が変わって
# いないか、Read-MigrationRecordが記録内のContextと比較する。
# Join-Pathはフォルダ名とファイル名をつなぐ。記録はこのフォルダのrecords/devなどへ置く。
# ErrorActionPreferenceをStopにすると、通常は表示して続行するPowerShellのエラーも
# 例外として扱い、呼び出し側のtry/catchで捕まえられる。
# 文字コードの設定は、日本語のCSV・JSONやAzure CLIとの受け渡しをUTF-8にそろえる。
# env:は環境変数を表し、PYTHONIOENCODINGは子プロセスにも伝わる設定。
# ---
$migrationContext = @{
    Environment = $environment
    SourceWorkspace = $targetWorkspaceId
    OldDcrIds = $oldDcrIds
    DiagnosticName = $newDiagnosticSettingName
}
$recordDirectory = Join-Path $PSScriptRoot "records/$environment"
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'

# ---
# ARM APIを呼び出す
# ResourceId、またはId・Kind・Bodyを持つResourceを渡し、JSON応答を辞書で返す。
# Optional時の404は値なし。認証更新と一時エラーの再試行だけを共通で処理する。
# Waitは作成・更新の完了を最大5分待つ。既存記録のAPI版も引き続き利用できる。
#
# 関数1 / Invoke-ArmRequestの使い方
# 役割：Azure Resource Manager（ARM）のHTTP APIを呼び、JSONの応答を辞書で返す。
# 主な呼び出し元：下の探索関数、step1の作成、step2の確認、step3の削除、rollbackの復元。
# 入力例：-ResourceId '/subscriptions/.../providers/...' -Method Get -Optional
# または -Resource @{ Id='...'; Kind='Diagnostic'; Body=@{ properties=@{} } } を渡す。
# Methodを省略するとGET（取得）。PUTは作成・置換、PATCHは一部更新、DELETEは削除、
# POSTは操作の実行で、何を変更するかは呼び出し側が渡すURLとBodyで決まる。
# ApiVersionは個別指定、またはResourceのKindに応じて辞書から選ぶ。
# 戻り値：成功時のJSONを辞書にしたもの。Optional指定時の404はnull。
# 失敗：対象IDとHTTP状態を含む例外を投げる。Optionalは404だけを許容する指定。
# Waitは応答のprovisioningStateがCreating・Updating・Acceptedの間、同じ要求を繰り返す。
# 呼び出し側は、主にGETにWaitを付け、作成・更新後の状態を確認している。
# 関数内では呼び出し側のsubscriptionIdを参照するため、先に対象SubのIDを設定して使う。
# ---
function Invoke-ArmRequest {
    param($ResourceId, $Method = 'Get', $Body, $ApiVersion = '2024-03-11', [switch]$Optional, $Resource, [switch]$Wait)
    # ---
    # 引数の受け取り方をそろえる
    # Resourceがあれば、個別のResourceIdなどの代わりに、辞書内のId・Kind・Bodyを利用する。
    # 「A ?? B」はAがnullならBを採用するPowerShell 7の演算子。
    # 保存記録にApiVersionがある場合はそれを使い、ない場合はKind別の既定値を使う。
    # PSBoundParametersは「呼び出すときに明示された引数」の辞書。
    # Bodyを明示指定していれば、null指定も含め、Resource.Bodyで上書きしない。
    # ---
    if ($Resource) {
        $ResourceId = $Resource.Id
        $ApiVersion = $Resource.ApiVersion ?? $apiVersions[$Resource.Kind]
        if ($Method -in @('Put', 'Patch', 'Post') -and -not $PSBoundParameters.ContainsKey('Body')) {
            $Body = $Resource.Body
        }
    }
    # ---
    # 要求先のURLを作る
    # URLそのものを受け取った場合はそのまま利用する。ページ送りのnextLinkもこの形。
    # リソースIDだけなら、ARMのホスト名とapi-versionを付けてHTTP要求の宛先にする。
    # ${ResourceId}は変数名の境界を明示する書き方で、後ろの?と名前を区別できる。
    # この5分の期限は、Waitによる状態確認を続けるか判定するためのもの。
    # 個々のHTTP通信のタイムアウトは下の90秒で、HTTPエラーの再試行回数とは別に管理する。
    # ---
    $uri = $ResourceId
    if (-not $uri.StartsWith('https://')) {
        $uri = "https://management.azure.com${ResourceId}?api-version=$ApiVersion"
    }
    $deadline = (Get-Date).AddMinutes(5)
    # ---
    # 認証情報を取得し、必要なときだけ更新する
    # attemptは0から3までなので、通常のHTTPエラーに対する要求は最大4回。
    # script:の変数は、このスクリプトを読み込んだスコープに保持され、関数を呼ぶたびに
    # 毎回ログイン情報を取り直すことを避ける。並列処理では作業場所ごとに保持される。
    # トークンが未取得・別Sub用・有効期限まで5分以内なら、Azure CLIから取り直す。
    # expires_onはUnix時刻（1970年からの秒数）で、[long]で大きな整数として比較する。
    # az account get-access-tokenはaz login済みの情報を利用する。ここで対話ログインはしない。
    # 「|」は左の出力を右へ渡すパイプ。ConvertFrom-Json -AsHashtableでJSON文字列を辞書にする。
    # LASTEXITCODEはazなど外部プログラムの終了コードで、0以外なら取得失敗として扱う。
    # ---
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        if (-not $script:accessToken -or $script:tokenSubscription -ne $subscriptionId -or
            [long]$script:accessToken.expires_on -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) {
            $script:accessToken = az account get-access-token --subscription $subscriptionId --output json --only-show-errors | ConvertFrom-Json -AsHashtable
            if ($LASTEXITCODE -ne 0 -or -not $script:accessToken.accessToken) {
                throw 'Azureの認証情報を取得できません。az loginを確認してください。'
            }
            $script:tokenSubscription = $subscriptionId
        }
        # ---
        # HTTP要求の設定と送信
        # requestという辞書に、URL・HTTPメソッド・認証ヘッダーなどを入れる。
        # Bearerトークンは認証に使う値で、ログ表示には含めない。
        # Bodyがあるときは、PowerShellの辞書をJSONへ変換し、UTF-8のバイト列として送る。
        # -Depth 40は、入れ子の深いDCRなどを途中で省略せず変換するための深さ指定。
        # Invoke-WebRequest @request の@requestはスプラッティングといい、辞書の各項目を
        # -Uri ... -Method ... のような名前付き引数へ展開する。
        # -SkipHttpErrorCheckを付け、HTTPエラーも応答として受け取り、下で状態コードを判定する。
        # HTTP応答が届く前の通信障害などは、例外としてそのまま呼び出し側へ伝わる。
        # ---
        $request = @{
            Uri = $uri
            Method = $Method
            Headers = @{ Authorization = "Bearer $($script:accessToken.accessToken)" }
            ContentType = 'application/json; charset=utf-8'
            TimeoutSec = 90
        }
        if ($null -ne $Body) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Body -Depth 40))
        }
        $response = Invoke-WebRequest @request -SkipHttpErrorCheck
        $status = [int]$response.StatusCode
        # ---
        # 成功した応答を読み、必要なら作成・更新の途中か確認する
        # HTTP状態コードが400未満なら応答内容をJSONとして読む。
        # Waitがあり、Azureが処理中の状態を返した場合は3秒待ち、同じ要求で状態を確認し直す。
        # attemptを-1へ戻すのは、for末尾の++後に0へ戻すため。処理中の応答を、
        # 一時エラーに対する再試行回数として消費しないようにする。期限を過ぎれば例外となる。
        # returnは値を呼び出し元へ返し、この関数の実行を終える。
        # PowerShellでは代入せずに出力した値も戻り値に流れるので、呼び出し側で
        # 「$null = Invoke-ArmRequest ...」と書く箇所は、不要な応答の出力を捨てている。
        # ---
        if ($status -lt 400) {
            $result = $response.Content | ConvertFrom-Json -AsHashtable
            if ($Wait -and $result.properties.provisioningState -in @('Creating', 'Updating', 'Accepted')) {
                if ((Get-Date) -ge $deadline) {
                    throw "作成・更新が完了しません: $ResourceId"
                }
                Start-Sleep -Seconds 3
                $attempt = -1
                continue
            }
            return $result
        }
        # ---
        # 存在しない場合と、一時的な失敗を区別する
        # 404は対象なし。Optionalがある場合だけnullを返し、作成前や削除後の確認を可能にする。
        # 401は認証エラーなので、残りの試行があればトークンを消して、次のループで再取得する。
        # 408・429・500・502・503・504も、残りの試行がある場合だけ待ってから再送する。
        # 待ち時間は最低2秒。Retry-Afterが秒数として返された場合は、その指示も考慮する。
        # continueは今回のループの残りを飛ばし、次の試行へ進む。
        # それ以外の失敗や、試行を使い切った失敗は、最後のthrowで呼び出し元へ通知する。
        # すべての失敗を握りつぶして続ける処理ではない。
        # ---
        if ($status -eq 404 -and $Optional) {
            return $null
        }
        if ($status -eq 401 -and $attempt -lt 3) {
            $script:accessToken = $null
            continue
        }
        if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
            $delay = 2
            $retryAfter = [string]$response.Headers['Retry-After']
            if ($retryAfter -match '^\d+$') {
                $delay = [Math]::Max($delay, [int]$retryAfter)
            }
            Start-Sleep -Seconds $delay
            continue
        }
        throw "ARM $Method 失敗 ($status): $ResourceId / $($response.Content)"
    }
}

# ---
# 現在値と期待値を比較する
# Expectedの項目がそろえばtrue。Exactは余分な項目も確認し、配列は順不同で比較する。
# 送信設定は正規化して全項目を照合し、Lifecycleは管理ルールと旧365日の残存を確認する。
#
# 関数2 / Test-Configurationの使い方
# 役割：Azureの現在値Actualが、必要な設定Expectedを満たすか調べ、true/falseを返す。
# 主な呼び出し元：記録の条件確認、step1のスキップ判定、step2の照合、step3とrollbackの再確認。
# 例：Actual=@{a=1;b=2}、Expected=@{a=1}なら通常はtrue。-Exactではfalse。
# Kindは、診断設定・DCR・関連付け・ライフサイクルの比較に必要な特別扱いを選ぶ。
# 通常の辞書比較は「期待した項目がそろうか」。Azureが付加する別の項目まで要求しない。
# -Exactは逆方向も比較して、余分な項目を含めて一致するか確認する。
# 配列は順序を問わず比較する。辞書や配列の内部も同じ関数を呼んで調べる（再帰）。
# 戻り値は比較結果であり、ここではAzureへ書き込まない。
# ---
function Test-Configuration {
    param($Actual, $Expected, $Kind, [switch]$Exact)
    # ---
    # 処理中の値や、サービスが付ける読み取り専用値を扱う
    # Kind付きの比較では、作成・更新状態がありSucceededでなければ未完了としてfalse。
    # 診断設定・DCR・関連付けは、GET応答とPUTする本文の形が完全には同じではないため、
    # Get-WritableBodyで比較対象の形をそろえてからExactで比較する。
    # このときKindをnullにするのは、再帰呼び出しで同じ正規化を繰り返さないため。
    # ---
    if ($Kind -and $Actual.properties.provisioningState -and $Actual.properties.provisioningState -ne 'Succeeded') {
        return $false
    }
    if ($Kind -in @('Diagnostic', 'Dcr', 'Association')) {
        $Actual = Get-WritableBody $Actual -Kind $Kind
        $Expected = Get-WritableBody $Expected -Kind $Kind
        $Kind = $null
        $Exact = $true
    }
    # ---
    # 両方向の比較で「必要な値がある」から「同じ値である」へ広げる
    # ActualがExpectedを満たし、ExpectedもActualを満たす場合に一致とする。
    # 再帰呼び出しでは-Exactを渡さないので、ここを無限に行き来することはない。
    # -andは両方がtrueであることを表す。最初がfalseなら後ろの比較は不要なので実行しない。
    # ---
    if ($Exact) {
        return (Test-Configuration $Actual $Expected -Kind $Kind) -and
            (Test-Configuration $Expected $Actual -Kind $Kind)
    }
    # ---
    # ライフサイクルは、このスクリプトで管理するルールだけを照合する
    # 旧名log-append-365が残っていればfalse。新名log-append-1095のルールを比較する。
    # 1095は365日×3年。別用途の既存ルールは、この比較の対象から外す。
    # Where-Object name -eq '...'は、そのnameを持つ要素だけを絞り込む書き方。
    # ---
    if ($Kind -eq 'Lifecycle') {
        if (@($Actual.properties.policy.rules | Where-Object name -eq 'log-append-365').Count) {
            return $false
        }
        $Actual = @($Actual.properties.policy.rules | Where-Object name -eq 'log-append-1095')
        $Expected = @($Expected.properties.policy.rules)
    }
    # ---
    # 配列を順不同で照合する
    # -is [array]で配列型か確認する。remainingは、実際の配列からまだ照合していない要素の一覧。
    # 通常の配列は要素を取り除く操作に向かないため、ここではArrayListへ変換して使う。
    # 期待値の各要素に一致するものを探し、見つけたものをRemoveAtで1つだけ除く。
    # 同じ値が複数あっても、同じ実要素を2回使って一致扱いにしないための処理。
    # breakは内側の検索ループを終え、次の期待値の照合へ移る。
    # Where-Object { $null -ne $_ }の$_は、パイプで流れてきた今の1要素を表す。
    # ---
    if ($Expected -is [array]) {
        [Collections.ArrayList]$remaining = @($Actual | Where-Object { $null -ne $_ })
        if ($remaining.Count -ne $Expected.Count) {
            return $false
        }
        foreach ($item in $Expected) {
            $matched = $false
            for ($index = 0; $index -lt $remaining.Count; $index++) {
                if (Test-Configuration $remaining[$index] $item) {
                    $remaining.RemoveAt($index)
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                return $false
            }
        }
        return $true
    }
    # ---
    # null・辞書・単一の値に分けて、比較を終える
    # nullは「値がない」ことを表し、文字列'null'とは違う。片方だけnullなら不一致。
    # IDictionaryは、通常のハッシュテーブルと順序付き辞書を共通して扱うための型。
    # 辞書ならExpected.Keysにある項目ごとに、内部の値を再帰的に比べる。
    # Actual.$keyは、key変数の中身を項目名として使う書き方。
    # 最後まで配列・辞書でなければ、数値や文字列などを-eqで比較する。
    # PowerShellの通常の文字列-eqは大文字小文字を区別しない。厳密に区別する条件には
    # このファイルでも-cnotmatch・-cnotinなど、c付きの演算子を使っている。
    # ---
    if ($null -eq $Actual -or $null -eq $Expected) {
        return $null -eq $Actual -and $null -eq $Expected
    }
    if ($Expected -is [Collections.IDictionary]) {
        foreach ($key in $Expected.Keys) {
            if (-not (Test-Configuration $Actual.$key $Expected.$key)) {
                return $false
            }
        }
        return $true
    }
    return $Actual -eq $Expected
}

# ---
# GET応答から保存・復元に使う本文を取り出す
# ResourceとKindを渡し、PUT用のHashtableを返す。値なしならnull。
# DCRの読み取り専用項目を除き、診断設定の省略された格納方式をそろえる。
#
# 関数3 / Get-WritableBodyの使い方
# 役割：GETで取得したリソースから、比較・保存・再設定に使える本文だけを取り出す。
# 主な呼び出し元：探索時の旧設定記録、Test-Configuration、step1・step3・rollback。
# 入力：ResourceはAPI応答または保存済み本文の辞書、KindはDiagnostic・Dcr・Associationなど。
# 戻り値：@{ properties=... }を中心とした辞書。入力がnullならnull。
# GET応答にはid・nameやAzureが決める値も含まれるので、そのままPUTしない。
# ここは書き込みの要求を送る関数ではなく、送るデータの形を整える関数。
# 作成・更新状態がありSucceededでなければ、未完了の内容を保存・復元せず例外にする。
# ---
function Get-WritableBody {
    param($Resource, $Kind)
    if (-not $Resource) {
        return $null
    }
    if ($Resource.properties.provisioningState -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw 'リソースの作成・更新が完了していません。'
    }
    # ---
    # DCRだけは、元データの内部を変更しないように複製する
    # 通常の「$copy = $Resource」は、同じ辞書を指すだけで入れ子まで複製するわけではない。
    # DCRは後で内部の項目をRemoveするため、JSONへ変換して読み直し、別の辞書にする。
    # これにより、変更前のResourceを他の箇所から使っていても、その内容を削らない。
    # 空の@{}は辞書、@()は配列。body.propertiesには「項目名→値」を追加していく。
    # ---
    $copy = $Resource
    if ($Kind -eq 'Dcr') {
        $copy = ConvertTo-Json $Resource -Depth 40 | ConvertFrom-Json -AsHashtable
    }
    $body = @{ properties = @{} }
    $keys = @($copy.properties.Keys)
    # ---
    # 種類ごとの書き込み可能な項目を選ぶ
    # 診断設定はログ・メトリック・送信先などの指定項目を採用する。
    # 関連付けは説明・DCRのID・データ収集エンドポイントのIDを採用する。
    # それ以外はpropertiesの項目を候補にし、後の条件で読み取り専用項目を除く。
    # 新しい診断設定の送信先へ変更する作業自体は、step1側でこの本文を使って行う。
    # ---
    if ($Kind -eq 'Diagnostic') {
        $keys = @('logs', 'metrics', 'workspaceId', 'storageAccountId', 'eventHubAuthorizationRuleId', 'eventHubName', 'serviceBusRuleId', 'marketplacePartnerId', 'logAnalyticsDestinationType')
    }
    if ($Kind -eq 'Association') {
        $keys = @('description', 'dataCollectionRuleId', 'dataCollectionEndpointId')
    }
    # ---
    # 値がある項目だけを、結果の本文へ移す
    # foreachで項目名を取り出し、除外一覧にあるAzure側管理の情報は書き込まない。
    # 「$null -ne 値」はfalseや0を除外する条件ではなく、値なしだけを除外する条件。
    # 診断設定でワークスペースがあり格納方式が省略されていた場合、AzureDiagnosticsを補う。
    # 省略された既定値と明示された既定値を、比較の際に別設定とみなさないため。
    # ---
    foreach ($key in $keys) {
        if ($null -ne $copy.properties.$key -and $key -notin @('immutableId', 'provisioningState', 'endpoints', 'metadata', 'ingestionQuotas')) {
            $body.properties[$key] = $copy.properties.$key
        }
    }
    if ($Kind -eq 'Diagnostic' -and $body.properties.workspaceId -and -not $body.properties.logAnalyticsDestinationType) {
        $body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'
    }
    if ($Kind -eq 'Dcr') {
        # ---
        # DCR本体の情報と、内部の読み取り専用情報を分ける
        # DCRではproperties以外にも、地域・種類・タグ・マネージドIDを本文へ引き継ぐ。
        # Log Analyticsなどの送信先配列には、Azureが付加した内部IDが含まれることがある。
        # それらのworkspaceId・accountId・ingestionUriを除き、PUT用の形へ整える。
        # 例えばLog AnalyticsのworkspaceResourceIdは別の項目であり、この処理では削除しない。
        # ---
        foreach ($key in @('location', 'kind', 'tags', 'identity')) {
            if ($null -ne $copy.$key) {
                $body[$key] = $copy.$key
            }
        }
        foreach ($destination in $body.properties.destinations.logAnalytics) {
            $destination.Remove('workspaceId')
        }
        foreach ($destination in $body.properties.destinations.monitoringAccounts) {
            $destination.Remove('accountId')
        }
        foreach ($destination in $body.properties.destinations.azureDataExplorer) {
            $destination.Remove('ingestionUri')
        }
        # ---
        # マネージドIDは種類と参照先を残し、Azureが発行する値を除く
        # principalId・tenantIdはAzure側が返す情報なので、再設定用の本文から外す。
        # ユーザー割り当てIDがある場合、IDの辞書キーを残して、その値を空の辞書へ置き換える。
        # 例：userAssignedIdentities['/subscriptions/.../identities/id1'] = @{} という形になる。
        # ユーザー割り当てIDがないSystemAssignedなどのケースでは、この内側の処理へ入らない。
        # Keysを@(...)で先に配列へ取り出し、辞書の要素を更新しながら安全に巡回する。
        # ---
        if ($body.identity) {
            $body.identity.Remove('principalId')
            $body.identity.Remove('tenantId')
            if ($body.identity.userAssignedIdentities) {
                foreach ($identityId in @($body.identity.userAssignedIdentities.Keys)) {
                    $body.identity.userAssignedIdentities[$identityId] = @{}
                }
            }
        }
    }
    return $body
}

# ---
# サブスクリプションの変更前記録を読む
# Targetに対応するJSONを返す。まだ保存していなければnull。
# 別環境・別の移行元・作業途中のCSV変更は、この時点で停止する。
#
# 関数4 / Read-MigrationRecordの使い方
# 役割：対象SubのJSON記録を読み、今回の実行条件・渡されたTargetと対応しているか確認する。
# 呼び出し元：step1の再実行、step2の確認、rollback。step3はstep2の確認結果を使う。
# 入力Targetは対象の情報を持つ辞書。step1・step2ではCSVの行から作ったものを渡す。
# rollbackでは記録内のTargetを渡すため、この関数も現在のCSVは読み直さない。
# 戻り値：記録を辞書にしたもの。まだファイルがなければnull。
# 記録はログデータのバックアップではなく、処理したID・期待する設定・変更前の設定。
# この関数は記録を読み込むだけで、Azureの現在値を調べたり記録を新規作成したりはしない。
# 記録を書き出すのはstep1で、最初に保存したBeforeを再実行時にも保持する。
# ---
function Read-MigrationRecord {
    param($Target)
    $path = Join-Path $recordDirectory "$($Target.SubscriptionId).json"
    if (-not (Test-Path $path)) {
        return $null
    }
    # ---
    # ファイルの内容と、今回の実行条件を照合する
    # Get-Content -Rawは、JSONファイルを行ごとの配列ではなく1つの文字列として読む。
    # Contextと渡されたTargetをExactで比べ、別の実行条件を同じ作業記録へ混ぜないようにする。
    # Destinationsは保存先、NewSettingsは新たな送信設定や除外、OldSettingsは旧送信設定。
    # これらが一覧（配列）として読めなければ、後続で誤って扱わないよう停止する。
    # ---
    $record = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if (-not (Test-Configuration $record.Context $migrationContext -Exact) -or
        -not (Test-Configuration $record.Target $Target -Exact)) {
        throw "変更前記録と環境・CSVが一致しません: $path"
    }
    foreach ($name in @('Destinations', 'NewSettings', 'OldSettings')) {
        if ($record.$name -isnot [array]) {
            throw "変更前記録の一覧が不正です: $path / $name"
        }
    }
    return $record
}

# ---
# CSVを読み、サブスクリプションを一意に特定する
# 送信を止める行でも保存先を準備する。VM用の列がない旧CSVだけLogを既定値にする。
#
# CSV読込は、通常のドットソース時に1回実行する
# ここからは関数定義ではないので、common.ps1を読み込むと実行される。
# SkipCsvがtrueならこの読込を省略し、並列の作業場所では関数や基本設定だけを準備する。
# targetsはCSV各行を辞書へ整えた配列で、各ステップがSubごとに繰り返す対象一覧。
# regionNamesは、後でストレージ名のjpeを地域略称へ変換するための一覧。
# ---
$targets = @()
$regionNames = @()
if (-not $SkipCsv) {
    $accounts = az account list --all --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'サブスクリプション一覧を取得できません。'
    }
    # ---
    # CSVを1行ずつ読み、入力をそろえる
    # Import-Csvは1行を1つのオブジェクトに変換し、列名で値を参照できるようにする。
    # [ordered]@{}は項目の挿入順を保つ辞書。設定データを人が読みやすい順で保持する。
    # [string]は文字列への変換、Trim()は両端の空白除去。空欄は空文字列として扱う。
    # PSObject.Properties.NameはCSVから読めた列名の一覧。
    # VmLogDestination列自体がない旧CSVはLogを既定値にするが、列があり空欄なら空欄を保つ。
    # 空欄やNoneの意味を、列がない場合の既定値と混同しないため。
    # ---
    foreach ($row in Import-Csv (Join-Path $PSScriptRoot 'targets.csv') -Encoding UTF8) {
        $target = [ordered]@{}
        foreach ($name in @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination')) {
            $target[$name] = ([string]$row.$name).Trim()
        }
        $target.VmLogDestination = 'Log'
        if ('VmLogDestination' -in $row.PSObject.Properties.Name) {
            $target.VmLogDestination = ([string]$row.VmLogDestination).Trim()
        }
        # ---
        # 送信先フラグと、保存先を作るための値を確認する
        # LogDestinationは診断設定用で、Storage・Log・None・空欄を受け付ける。
        # VmLogDestinationはDCRと関連付け用で、Log・None・空欄を受け付ける。
        # Noneと空欄は、その側の新しい送信設定を作らない指定。保存先の作成を省く指定ではない。
        # その側の旧送信設定は最終削除の対象となる。削除は別ステップで確認後に実行する。
        # そのため、送信先フラグがNoneでもRG・WorkspaceNameは必須としている。
        # ---
        if ($target.LogDestination -notin @('Storage', 'Log', 'None', '') -or
            $target.VmLogDestination -notin @('Log', 'None', '')) {
            throw "CSVの送信先が不正です: $($target.SubscriptionName)"
        }
        foreach ($name in @('SubscriptionName', 'ResourceGroup', 'WorkspaceName')) {
            if (-not $target[$name]) {
                throw "CSVの必須値が空欄です: $name"
            }
        }
        # ---
        # ストレージ名は、地域へ置き換える前にも形式を調べる
        # 診断設定の送信先がStorageならStorageAccount列が必要。
        # 名前を指定した場合は小文字英数字3～24文字、jpeをちょうど1か所含むことを確認する。
        # 正規表現の^と$は文字列の先頭・末尾、[a-z0-9]は使える文字、{3,24}は文字数。
        # -cnotmatchは大文字小文字を区別して「パターンに合わない」を判定する。
        # ここは形式の確認。Azure全体でその名前が使用済みかは、下の探索関数で別に調べる。
        # ---
        if (($target.LogDestination -eq 'Storage' -and -not $target.StorageAccount) -or
            ($target.StorageAccount -and ($target.StorageAccount -cnotmatch '^[a-z0-9]{3,24}$' -or
            [regex]::Matches($target.StorageAccount, 'jpe').Count -ne 1))) {
            throw 'StorageAccountは小文字英数字3～24文字でjpeを1か所含む名前を指定してください。'
        }
        # ---
        # サブスクリプションの表示名を、処理で使うIDへ解決する
        # CSVには表示名またはIDを指定できる。az account listの一覧と照合し、1件だけなら採用する。
        # 0件なら不明、2件以上なら同名などで曖昧なので、そのまま実行しない。
        # 新ワークスペースの完全なIDもここで組み立て、移行元と同じIDにならないことを確認する。
        # targets += targetは、整形済みの1行を処理対象の配列へ追加する。
        # ---
        $matches = @($accounts | Where-Object { $_.id -eq $target.SubscriptionName -or $_.name -eq $target.SubscriptionName })
        if ($matches.Count -ne 1) {
            throw "サブスクリプションを一意に特定できません: $($target.SubscriptionName)"
        }
        $target.SubscriptionId = $matches[0].id
        $target.WorkspaceId = "/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)"
        if ($target.WorkspaceId -eq $targetWorkspaceId) {
            throw '移行元と新しいワークスペースは別に指定してください。'
        }
        $targets += $target
    }
    # ---
    # 空CSV・同一Subの重複を防ぎ、必要なら地域略称を取得する
    # Group-ObjectはSubscriptionIdが同じ行をグループ化し、Countが2以上のグループを探す。
    # CSVの列名ではなく、上で解決した実IDを使うので、名前とIDで同じSubを二重指定しても検出する。
    # StorageAccountを指定した行がある場合だけ、AzureNamingToolの地域名データをHTTP取得する。
    # これはAzureの命名ツールで管理される地域名とshortNameの対応を参照する処理。
    # ローカルに独自の略称対応表を作らずに利用し、未対応の地域は探索時にエラーにする。
    # この外部データの取得にも通信が必要で、接続失敗は呼び出し側へ例外として伝わる。
    # ---
    if (-not $targets.Count -or @($targets | Group-Object { $_.SubscriptionId } | Where-Object Count -gt 1).Count) {
        throw 'CSVが空か、同じサブスクリプションが重複しています。'
    }
    if (@($targets | Where-Object StorageAccount).Count) {
        $regionNames = Invoke-RestMethod 'https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json'
    }
}

# ---
# 現在の旧設定、地域、作成予定名と追加枠を調べる。
# TargetはCSVの1行、Recordは保存済み記録。OnlyOldSettingsは旧設定だけを返す。
# 通常はcopy用の軽いDiscoveryも返す。設定内容の組立やAzureの変更は行わない。
#
# 関数5 / Get-MigrationPlanの使い方
# 役割：対象Subの現在のAzureを調べ、旧送信設定と、作成予定の名前・地域をまとめる。
# 呼び出し元：precheck、step1。step2は-OnlyOldSettingsを付けて旧設定の再調査に使う。
# TargetはCSV由来の対象情報。Recordは再実行時の既存記録で、未実行ならnull。
# 戻り値planはContext・Target・Destinations・NewSettings・OldSettingsを持つ辞書。
# 通常は追加でDiscoveryに作成先IDなどを入れる。DestinationsとNewSettingsの本文は
# step1側で組み立てるため、この関数を終えた時点では空の配列。
# OnlyOldSettingsがあると、旧設定を集めた時点で返し、作成予定名などの確認を省く。
# Azureの設定変更はしないが、名前の使用可否確認には参照用のPOST APIを使う。
# precheckの結果を保存して後続が依存する方式ではなく、step1はSubごとに改めて調査する。
# ---
function Get-MigrationPlan {
    param($Target, $Record, [switch]$OnlyOldSettings)

    # ---
    # 今回のSub専用の計画を用意する
    # subscriptionIdを関数内で設定すると、ここから呼ぶInvoke-ArmRequestもこの値を参照する。
    # planの3つの一覧は初めに空配列とし、発見した内容を順に追加する。
    # OldSettingsの各要素は、Id・Kind・Bodyの共通形式。サービス名ではなく、この形式を
    # 使って後の比較・削除・復元を共通して行う。
    # ---
    $subscriptionId = $Target.SubscriptionId
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $plan = @{
        Context = $migrationContext
        Target = $Target
        Destinations = @()
        NewSettings = @()
        OldSettings = @()
    }

    # ---
    # 通常のリソース一覧にStorageの子サービスを加え、旧診断設定を探す。
    #
    # 対象リソースのIDと地域を集め、ページ送りを最後まで読む
    # resourceLocationsは「リソースID→地域」の辞書。対象の重複を避け、後で地域を引ける。
    # APIの一覧は1回で全件返るとは限らず、続きがあればnextLinkにURLが入る。
    # whileはnextLinkがなくなるまで繰り返し、各ページのvalue配列を取り込む。
    # 通常のリソース一覧に現れないStorageの子サービスは、親の種類からIDを補う。
    # Blob専用・File専用は対応するサービスのみ、それ以外はBlob/File/Queue/Tableの4つ。
    # これは診断設定を探す対象の追加であり、ストレージの子サービスを作成する操作ではない。
    # ---
    $resourceLocations = @{}
    $resourcePage = "https://management.azure.com/subscriptions/$subscriptionId/resources?api-version=2021-04-01"
    while ($resourcePage) {
        $page = Invoke-ArmRequest -ResourceId $resourcePage
        foreach ($resource in $page.value) {
            $resourceLocations[$resource.id] = $resource.location
            if ($resource.type -eq 'Microsoft.Storage/storageAccounts') {
                $services = switch ($resource.kind) {
                    'BlobStorage' {
                        'blobServices'
                    }
                    'BlockBlobStorage' {
                        'blobServices'
                    }
                    'FileStorage' {
                        'fileServices'
                    }
                    default {
                        @('blobServices', 'fileServices', 'queueServices', 'tableServices')
                    }
                }
                foreach ($service in $services) {
                    $resourceLocations["$($resource.id)/$service/default"] = $resource.location
                }
            }
        }
        $resourcePage = $page.nextLink
    }
    # ---
    # 診断設定の取得だけを、上限付きの並列処理へ渡す
    # resourceLocations.KeysでIDを取り出し、ForEach-Object -ParallelでIDごとに処理する。
    # -Parallel内は別の実行場所（ランスペース）なので、親の関数や変数がそのまま使えるとは限らない。
    # そのためcommon.ps1をドットソースし、$using:変数名で親から必要な値を受け取る。
    # -SkipCsvでCSVの再読込を避ける。トークンも引き継ぎ、各作業場所で必要なら更新する。
    # ThrottleLimitは同時に動かす数を制限する。同時実行なので戻ってくる順はID順とは限らない。
    # 各作業はSources・Settings・Errorを持つ辞書を返し、親側で結果をまとめて検査する。
    # ---
    $accessToken = $script:accessToken
    $sourceWorkspace = $targetWorkspaceId
    $listedSettings = @($resourceLocations.Keys | ForEach-Object -Parallel {
        $result = @{ ResourceId = $_; Sources = @(); Settings = @(); Error = '' }
        try {
            . $using:commonScript -SkipCsv
            $subscriptionId = $using:subscriptionId
            $script:accessToken = $using:accessToken
            $script:tokenSubscription = $subscriptionId
            $response = Invoke-ArmRequest -ResourceId "$($_)$diagnosticPath" -ApiVersion '2021-05-01-preview'
            # ---
            # 全設定と、今回の移行元に該当する設定を区別する
            # Settingsには対象リソースの既存診断設定をすべて入れ、名前の衝突や上限5件の確認に使う。
            # SourcesにはworkspaceIdが移行元ワークスペースIDと同じものだけを入れる。
            # 設定名だけで旧設定を選ぶのではなく、送信先ワークスペースで対象を絞っている。
            # 別の送信先だけを持つ診断設定はSourcesへ入らず、複製・削除する旧設定の対象にしない。
            # ---
            $result.Settings = @($response.value)
            $result.Sources = @($response.value | Where-Object { $_.properties.workspaceId -eq $using:sourceWorkspace })
        }
        # ---
        # 並列の作業が失敗した場合も、親へ判定材料を返す
        # catch内の$_は、パイプの要素ではなく「捕まえたエラー」を表す。
        # ResourceTypeNotSupportedは診断設定に対応していない種類として扱い、対象なしで返す。
        # それ以外はErrorへメッセージを入れ、作業場所の外でサブスクリプション全体を止める。
        # 各入力IDに必ず1つの結果辞書を返す形にし、結果の不足も後で確認する。
        # ---
        catch {
            if (($_.Exception.Message + $_.ErrorDetails.Message) -notmatch 'ResourceTypeNotSupported') {
                $result.Error = $_.Exception.Message
            }
        }
        $result
    } -ThrottleLimit $parallelLimit)
    # ---
    # 調査漏れ・取得失敗を検出してから、旧診断設定の本文を取り出す
    # 結果数が入力のID数と同じか、各結果にErrorがないかを先に確認する。
    # Sourcesがあるリソースだけに絞り、旧設定のId・Kind・書き込み可能なBodyを記録する。
    # EscapeDataStringは設定名の文字をURLのパスに安全に入れるためのエンコード。
    # リソースの地域は空白を除いて小文字へそろえ、空欄やglobalは東日本として扱う。
    # ここでそろえたLocationが、Storage送信先を地域ごとに選ぶ材料になる。
    # ---
    if ($listedSettings.Count -ne $resourceLocations.Count) {
        throw '診断設定の調査結果が不足しています。'
    }
    foreach ($failed in @($listedSettings | Where-Object Error)) {
        throw "診断設定を調査できません: $($failed.ResourceId) / $($failed.Error)"
    }
    $diagnosticSources = @($listedSettings | Where-Object { $_.Sources.Count })
    foreach ($diagnostic in $diagnosticSources) {
        foreach ($source in $diagnostic.Sources) {
            $plan.OldSettings += @{
                Id = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($source.name))"
                Kind = 'Diagnostic'
                Body = Get-WritableBody -Resource $source -Kind 'Diagnostic'
            }
        }
        $resourceLocation = ([string]$resourceLocations[$diagnostic.ResourceId] -replace '\s', '').ToLowerInvariant()
        if (-not $resourceLocation -or $resourceLocation -eq 'global') {
            $resourceLocation = 'japaneast'
        }
        $diagnostic.Location = $resourceLocation
    }

    # ---
    # 旧2DCRの関連から、このSubの元の関連付けを保存する。
    # 一覧だけでは省略される項目があるため、各関連の本体も取得する。
    #
    # 旧DCRに結び付く対象だけを集める
    # 2つの旧DCRについて関連一覧を読み、関連付けのIDが現在のSub配下にあるものだけを選ぶ。
    # VMやVMSSの種類を1つずつ分岐せず、旧DCRに関連付け済みかどうかで対象を決める。
    # 各関連付けを個別にGETし、一覧取得後に参照DCRが変わっていないかも確認する。
    # この段階では旧DCRも関連付けも削除しない。OldSettingsへ復元可能な本文を追加する。
    # 関連一覧も複数ページになる可能性があるので、nextLinkを追う。
    # ---
    foreach ($oldDcrId in $oldDcrIds) {
        $associationPage = "$oldDcrId/associations"
        while ($associationPage) {
            $page = Invoke-ArmRequest -ResourceId $associationPage
            if ($null -eq $page.value) {
                throw "旧DCRの関連一覧を取得できません: $oldDcrId"
            }
            foreach ($association in $page.value) {
                if ($association.id -notlike "/subscriptions/$subscriptionId/*") {
                    continue
                }
                $current = Invoke-ArmRequest -ResourceId $association.id
                if ($current.properties.dataCollectionRuleId -ne $oldDcrId) {
                    throw "旧DCR関連の参照先が調査中に変わりました: $($association.id)"
                }
                $plan.OldSettings += @{
                    Id = $association.id
                    Kind = 'Association'
                    Body = Get-WritableBody -Resource $current -Kind 'Association'
                }
            }
            $associationPage = $page.nextLink
        }
    }
    # ---
    # 旧設定の再調査だけの場合は、ここで終了する
    # step2はこの指定を使い、記録後に増えた旧設定・変わった旧設定を確認する。
    # 通常のprecheckとstep1は、この先のポリシー・新しい名前・追加枠も調べる。
    # ---
    if ($OnlyOldSettings) {
        return $plan
    }

    # ---
    # このSubに適用される3割り当てと、指定した参照IDを確認する。
    # 同じイニシアティブの定義は、処理中に1回だけ取得する。
    #
    # ポリシー割り当てが本当にこのSubへ適用されるか調べる
    # atScope()フィルターで、このSubのスコープに適用される割り当てを一覧取得する。
    # URL内の`$filterのバッククォートは、$filterをPowerShell変数として展開せず、
    # 文字どおりAPIのクエリ名として送るためのエスケープ。
    # 構成に書かれた3つの割り当てIDが、現在の一覧に含まれていることを確認する。
    # この段階では適用除外（Waiver）を作らず、step1で作れる前提を確認している。
    # ---
    $assignments = @()
    $assignmentPage = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
    while ($assignmentPage) {
        $page = Invoke-ArmRequest -ResourceId $assignmentPage
        $assignments += @($page.value)
        $assignmentPage = $page.nextLink
    }
    foreach ($assignment in $policyAssignments) {
        if ($assignment.Id -notin $assignments.id) {
            throw "ポリシー割り当てが適用されていません: $($assignment.Id)"
        }
    }
    # ---
    # 3件目のイニシアティブと、12個の参照IDを照合する
    # 3件目の割り当てが単独ポリシーではなくpolicySetDefinitionsを参照することを確認する。
    # 同じ定義を次のSubでも使う場合は、script:変数に保持した取得結果を再利用する。
    # -cnotinは大文字小文字を区別して、指定参照IDが定義に含まれない場合を検出する。
    # ここでIDの誤りを止め、存在しない参照IDで除外を作ろうとしないようにする。
    # ---
    $initiative = @($assignments | Where-Object { $_.id -eq $policyAssignments[2].Id })[0]
    $definitionId = $initiative.properties.policyDefinitionId
    if ($definitionId -notmatch '/policySetDefinitions/') {
        throw '3件目の割り当てがイニシアティブではありません。'
    }
    if ($script:initiativeDefinitionId -ne $definitionId) {
        $script:initiativeDefinition = Invoke-ArmRequest -ResourceId $definitionId -ApiVersion '2023-04-01'
        $script:initiativeDefinitionId = $definitionId
    }
    foreach ($referenceId in $policyAssignments[2].ReferenceIds) {
        if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) {
            throw "イニシアティブに参照IDがありません: $referenceId"
        }
    }

    # ---
    # step1へ渡す、作成予定の位置情報をまとめる
    # Discoveryは、StorageのID・地域、DCRのID、関連付けや診断設定のIDを入れるための辞書。
    # ここでは「どこに何を作るか」を決め、「どの本文で作るか」とBeforeの取得はstep1で行う。
    # ローカルの計画を組み立てているだけで、この代入によってAzureへ作成されるものはない。
    # ---
    $discovery = @{
        Storages = @()
        Dcr = $null
        Associations = @()
        Diagnostics = @()
    }

    # ---
    # 保存先Storageの地域・名前・ZRS対応を調べる。
    #
    # ストレージ名が指定されていれば、送信フラグに関係なく保存先を準備する
    # 旧診断設定がある地域の一覧を、Sort-Object -Uniqueで重複なしにする。
    # 旧診断設定が1つもなければ、保存先として東日本を1つ準備する。
    # StorageAccountの指定有無を条件にしており、LogDestination=Noneでも指定があれば対象。
    # Storage SKU一覧はこのSubのAPIから取得し、各地域でStandard_ZRSを使えるか調べる。
    # ---
    if ($Target.StorageAccount) {
        $storageLocations = @($diagnosticSources.Location | Sort-Object -Unique)
        if ($storageLocations.Count -eq 0) {
            $storageLocations = @('japaneast')
        }
        $skus = Invoke-ArmRequest "/subscriptions/$subscriptionId/providers/Microsoft.Storage/skus" -ApiVersion '2023-05-01'
        foreach ($storageLocation in $storageLocations) {
            # ---
            # 地域名を略称へ変換し、変換後の名前も検査する
            # 例：名前のjpe部分だけを対象地域のshortNameへ置換する。jpeは入力時に1か所と検査済み。
            # 略称が取得できない・複数候補・不正な文字の場合は、推測した名前で作成せず停止する。
            # 地域によって略称の長さが違うため、置換後にも小文字英数字3～24文字を確認する。
            # ZRSを利用できない地域でも、勝手に別の冗長化方式へ落とさず停止する。
            # ---
            $region = @($regionNames | Where-Object { ($_.name -replace '\s', '') -eq $storageLocation })
            if ($region.Count -ne 1 -or $region[0].shortName -cnotmatch '^[a-z0-9]+$') {
                throw "地域の略称を取得できません: $storageLocation"
            }
            $storageName = $Target.StorageAccount.Replace('jpe', [string]$region[0].shortName)
            if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') {
                throw "変換後のStorage名が不正です: $storageName"
            }
            if (-not ($skus.value | Where-Object { $_.name -eq 'Standard_ZRS' -and $_.kind -eq 'StorageV2' -and $storageLocation -in $_.locations })) {
                throw "Standard_ZRSを利用できません: $storageLocation"
            }
            $storageId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/$storageName"
            # ---
            # 初回の名前衝突確認と、再実行を分ける
            # Storage名はAzure全体で一意なので、名前の使用可否APIを呼ぶ。
            # ただし、今回の記録Destinationsに同じIDがすでにある場合は、この名前確認を飛ばす。
            # 途中まで自分で作った保存先を、再実行時に「名前が使用済み」として止めないため。
            # 記録がない別の同名Storageを、ここで見つけて自動再利用する処理ではない。
            # 既にある記録対象の実体・設定内容は、step1側で読み直して確認する。
            # 確認結果はId・Name・LocationとしてDiscovery.Storagesへ追加する。
            # ---
            if ($storageId -notin @($Record.Destinations.Id)) {
                $availability = Invoke-ArmRequest "/subscriptions/$subscriptionId/providers/Microsoft.Storage/checkNameAvailability" -Method Post -ApiVersion '2023-05-01' -Body @{
                    name = $storageName
                    type = 'Microsoft.Storage/storageAccounts'
                }
                if (-not $availability.nameAvailable) {
                    throw "Storage名が使用済みです: $storageName"
                }
            }
            $discovery.Storages += @{
                Id = $storageId
                Name = $storageName
                Location = $storageLocation
            }
        }
    }

    # ---
    # 作成するDCR・関連付け・診断設定のIDと追加枠を確認する。
    # 設定内容とBeforeは、変更を行うcopy側で組み立てる。
    #
    # VM側は、旧関連付けがあり、かつLog指定の場合だけ新しい送信設定を計画する
    # VmLogDestinationがNone・空欄なら、新DCRと新関連付けの計画を作らない。
    # 旧関連付けはすでにOldSettingsへ収集済みなので、新設定を作らない場合でも削除対象に残る。
    # 新DCR名は新ワークスペース名の先頭logをdcrへ置き換えて決める。^logの^は先頭の意味。
    # 新しいDCRが指定済みの旧DCRと同じIDにならないことを先に確認する。
    # ---
    $oldAssociations = @($plan.OldSettings | Where-Object Kind -eq 'Association')
    if ($oldAssociations.Count -gt 0 -and $Target.VmLogDestination -eq 'Log') {
        $dcrName = $Target.WorkspaceName -replace '^log', 'dcr'
        $dcrId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
        if ($dcrId -in $oldDcrIds) {
            throw "新旧DCRのIDが同じです: $dcrId"
        }
        $discovery.Dcr = @{
            Id = $dcrId
            Name = $dcrName
        }
        # ---
        # VM・VMSSごとの新しい関連付けIDを作る
        # 旧関連付けIDの末尾「/providers/.../dataCollectionRuleAssociations/関連名」を外すと、
        # 関連付け先リソース自身のIDになる。[^/]+は「/以外の文字が1文字以上」という意味。
        # 同じVMが2つの旧DCRを参照していても、新しい関連付けは親リソースごとに1つとする。
        # ここで作るのは関連付け設定の計画であり、VM・VMSSそのものを新規作成するものではない。
        # ---
        $parentIds = @($oldAssociations.Id | ForEach-Object { $_ -replace "$associationPath/[^/]+$", '' } | Sort-Object -Unique)
        foreach ($parentId in $parentIds) {
            $associationId = "$parentId$associationPath/$dcrName"
            if ($associationId -in $oldAssociations.Id) {
                throw "新旧DCR関連のIDが同じです: $associationId"
            }
            $discovery.Associations += @{ Id = $associationId }
        }
    }
    # ---
    # 診断設定側の新規作成を計画し、同名・上限に当たる場合は先に止める
    # LogDestinationがStorageまたはLogのときだけ新診断設定の計画を作る。
    # 同じリソースに対象の旧設定が複数あれば、共通の新設定名へ安全に1対1で複製できないため停止。
    # 新設定名が旧設定自身と同じ場合も、旧設定を上書きしないよう停止する。
    # 既存の同名設定は、今回の記録NewSettingsにあるものだけ再実行対象として許容する。
    # 別の同名設定は変更しない。診断設定がすでに5件あり追加枠がなければ、これも停止する。
    # 以上を満たしたID・旧設定ID・地域をstep1へ渡し、実際の本文作成と設定はstep1が行う。
    # ---
    if ($Target.LogDestination -in @('Storage', 'Log')) {
        foreach ($diagnostic in $diagnosticSources) {
            if ($diagnostic.Sources.Count -ne 1) {
                throw "対象の旧診断設定が複数あります: $($diagnostic.ResourceId)"
            }
            $newId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($newDiagnosticSettingName))"
            if ($newId -in $plan.OldSettings.Id) {
                throw "新旧診断設定の名前が同じです: $newId"
            }
            $existing = @($diagnostic.Settings | Where-Object name -eq $newDiagnosticSettingName)
            if ($existing.Count -gt 0 -and $newId -notin @($Record.NewSettings.Id)) {
                throw "新しい診断設定名が使用済みです: $newId"
            }
            if ($existing.Count -eq 0 -and $diagnostic.Settings.Count -ge 5) {
                throw "診断設定を追加する空き枠がありません: $($diagnostic.ResourceId)"
            }
            $oldId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($diagnostic.Sources[0].name))"
            $discovery.Diagnostics += @{
                Id = $newId
                OldId = $oldId
                Location = $diagnostic.Location
            }
        }
    }
    # ---
    # 調査結果を呼び出し元へ返す
    # 返した後、precheckは結果を捨てて事前確認の成否だけを表示する。
    # step1はDiscoveryを基に送信先や新設定のBodyを作り、変更前記録を保存してからAzureへ反映する。
    # この関数だけでは、保存先・新診断設定・DCR・除外のいずれも作成されない。
    # ---
    $plan.Discovery = $discovery
    return $plan
}
