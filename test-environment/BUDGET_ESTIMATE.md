# 56タイプのテスト環境の費用見積（2サブスクリプション合計）

作成: 2026-11-18 UTC。PUBLIC Retail API（JPY/Consumption）とMicrosoft公式資料による差額見積。認証・Azure管理API・deploymentなし。既存ネットワーク対応の候補PS/ARM・定義数は書き換え完了後のRoot採用／新Planへの結び付け待ち。

**利用者は53型・ASE込み、予算目安6,000円維持、4時間目標・6時間計画枠を選択済みです。** 既存subnet制約でFirewallをStandardへ変更した現構成では4hは4,192.32円、6hは5,354.66円です。**8hは6,517.01円で予算を517.01円超過し、未承認**です。作成資格・region・実category等で不可の型は理由付きskipとし、CodeSigning、Bing、ExpressRouteは省略します。既知単価＋予備枠の計画見積であり、実請求の上限保証ではありません。

| 計画（2subs全体） | 作成からDELETE完了4h | 作成からDELETE完了8h | 予算目安4h /8h |
|---|---:|---:|---:|
| 比較: base38（37 feasible＋VM2台の1型） | 1,413.18円 | 1,654.95円 | 1,500 / 2,000円 |
| 広範囲52（ASEなし） | 3,788.51円 | 5,709.41円 | 4,000 / 6,000円（比較案） |
| 選択済み53（ASEあり） | 4,192.32円 | 6,517.01円 | 6,000円（既存承認、8h超過） |

上表には税込みの例として10%を予備加算した。契約・税区分は未確認。4h/8hはテストだけの時間ではなく、provision・試験・削除待ちを含む**全寿命**。APIM/ASE等の作成・削除が延びれば増額する。実行は4時間以内を目標に、共通基盤後のデプロイと有料リソースの削除開始をまとめて待ち時間を重ねます。全有料資産を全時間維持する保守的計算なので、この短縮分は見積から差し引いていません。

## 既存ネットワーク構成によるFirewallの差額

新しいAzureFirewallManagementSubnetを作れないため、B/Japan WestのFirewallをBasicからStandard（非forced-tunnel）へ変更します。新規Standard単価197.7875円/h、旧Basic単価62.50085円/hなので、**追加は135.28665円/h**です。Standardのデータ処理は2.53168円/GBで、従量500円枠は据え置きます。公式価格ページはCapacity Unitをprescalingの明示有効時だけの追加料金と明記しているため、prescaling無効・AI add-onなしの本構成には加算しません。

| 全寿命（作成〜DELETE完了） | 53型の計画額 | 既存6,000円との差 |
|---|---:|---:|
| 4h（目標） | 4,192.32円 | 1,807.68円の余裕 |
| 6h | 5,354.66円 | 645.34円の余裕 |
| 7h | 5,935.84円 | 64.16円の余裕 |
| 8h | 6,517.01円 | **517.01円超過・未承認** |

利用者は4時間目標・6時間計画枠を選択済みです。6時間なら既存予備枠とは別に645.34円の余裕が残ります。7時間も計算上は6,000円内ですが余裕が小さく、今回選択した計画枠ではありません。8時間を維持する場合は予算または保持時間の判断が必要で、増額を自動承認しません。単純な線形式での境界は約7.1104時間ですが、各サービスの端数課金・実際の作成／削除時刻があるため、請求上限や停止タイマーには使いません。

既存2VNetとNSG、固定5subnet、追加のVNet作成拒否ポリシーには固定存在料金を加算しません。DatabricksはB/Japan Westへ移しますがcluster/job/warehouseは作らず、元の管理NAT／PIPの計画確保額を減額せず残します。ASEは引き続き含み、他の単価・500円＋500円の予備枠・10%税予備・JPY換算・PIPの確保数量は変更しません。リソース作成前の利用登録待ちは課金リソースの保持時間として加算しません。

## 前回のVM／AKS／Web見直し（Standard化前の差額）

作成実績と最新のSKU／クォータ情報に合わせ、VM2台とAKS2ノードをJapan EastのD2s_v4へ変更し、Web／Function／両slotの共有planをB/WestUS2のLinux S1へ移します。VMSS2個はD2s_v4定義・capacity0です。型数53・ASEあり、VM／node／planの数量、500円＋500円の予備枠、10%税予備は据え置きます。JPY Retail単価に為替倍率を重ねません。

| 変更する時間料金（全数量） | 旧案 円/h | 新案 円/h | 差額 円/h |
|---|---:|---:|---:|
| Linux VM2台 | 4.303856 | 39.241040 | +34.937184 |
| AKS Linux2ノード | 78.482080 | 39.241040 | -39.241040 |
| 共有S1 plan1 | 18.671140 | 12.658400 | -6.012740 |
| 53型合計の差額 | — | — | **-10.316596** |

前回のBasic構成の税込計画額はVM／AKS／Webの変更により4hで45.3930224円、8hで90.7860448円減りました（今回のStandard化前）（各表示合計を丸める前の差額）。WestUS2宛先と、Bのglobal候補が診断対応している場合の東日本fallback宛先を含む最大5個の宛先Storageに固定存在料はなく、全Storage合計1GB・各10K操作の既存予備枠内で計画します。Webの移設は実作成前で、作成・診断成功は主張しません。リソース作成前の利用登録解除待ちは、この保持時間へ足しません。選択済みの予算目安6,000円は変更ありません。

## 合計の内訳

| 内訳 | 52型4h | 52型8h | 53型4h | 53型8h |
|---|---:|---:|---:|---:|
| 既知の存在／時間料金＋日／月額確保 | 2,342.84円 | 3,987.84円 | 2,709.93円 | 4,722.03円 |
| AppGW:20CU×全時間の追加計画枠 | 101.26円 | 202.53円 | 101.26円 | 202.53円 |
| 管理資産／最低料金未確定の予備枠 | 500.00円 | 500.00円 | 500.00円 | 500.00円 |
| 小容量のログ・Storage・I/O等予備枠 | 500.00円 | 500.00円 | 500.00円 | 500.00円 |
| 税前の計画額 | 3,444.10円 | 5,190.37円 | 3,811.20円 | 5,924.56円 |
| 10%税予備 | 344.41円 | 519.04円 | 381.12円 | 592.46円 |
| 計画額合計 | 3,788.51円 | 5,709.41円 | 4,192.32円 | 6,517.01円 |

NATv2 flow-logの月額632.92円を4h/8hどちらにも**全額**含む。ACR Basicは26.36円/日、SQL Basicは28.01円/日をそれぞれ1日分確保。CodeSigningの月額は上記に含めない。

53型の6hは5,354.66円、10hは7,679.36円です（同じ予備枠・10%税予備込み）。8hは6,000円を超えます。時間検知やBudgetJPYは請求をhard capしません。

## 数量と配置

- 2subsへ型ごとに分配し、全型を2倍・全regionへ複製しない。A/R1=Japan East、B/R2=Japan West、A/R3=Canada Central、B/R4=West US2（Linux Web/Function共有plan）。globalは所属RGの位置を示す。
- VM2台（両方Japan East、D2s_v4）、VMSS2個（Japan West、capacity0、D2s_v4定義）、AKS1 cluster（Japan East、D2s_v4 Linux2台）。VM OSはStandard_LRS32GiB、AKS OSはManaged32GiB・既定Premium_LRS/P4を価格仮定。
- fixture LA3（Source/Aux/Base）＋F1/F2の新宛先LA4＝LA7。Storage行にもWorkspaceを作るため、各cycleで両Subに1個ずつです。監視用Storage LRS1(Canada)＋送信先ZRS最大5（A:Japan East/Canada、B:Japan West/West US2/条件付きJapan East）＝指定Storage最大6。Bのglobal DNS／Private DNS等にSourceDiagを設定できた場合のみ東日本fallback宛先が増えます。実作成数はSeed／事前チェック後に確定し、最大5個の宛先が必ず作られるとは扱いません。全宛先をteardownまで保持する。provider自動Storageは別の残余枠。
- B/WestUS2のLinux S1 plan1をWeb App1＋slot1、Function App1＋slot1で共有。Firewall Standard1＋policy1（非forced-tunnel、追加ManagementSubnetなし）＋PIPの既存予備確保、AppGW1＋PIP1、AKS自動LB1＋PIP1、Databricks自動NAT1＋PIP1を計画数量に含む。NATv2 fixtureは未attachでPIPなし。
- base38比較ではPIP1（FW/AKS/Databricksなし）へ数量を減らし、VNetは既存2を参照して、VM2・VMSS2(capacity0)・LA7・Storage最大6を計画する。
- DCRはfixture3＋F1/F2新規4＋Monitor workspace自動DCR/DCE候補。Storageサービス子scope、Redis default DB、SQL master等は別の有料rootを追加しない。
- region override時は依存とそのregionのStorage宛先を再確認・再見積。Retail掲載はSKU・region・quota・作成資格の保証ではない。

## 全56型の確認表

金額列は53型案の既知料金成分（円）。`従量枠`・`未確定`は無料を意味せず、上の予備枠または未確定扱い。親／他行に含む成分は二重加算しない。ASE行を除けば52型案。

| exact resourceType | 個数・配置／SKU | 4h | 8h | 費用条件・省略理由 |
|---|---|---:|---:|---|
| `microsoft.codesigning/codesigningaccounts` | 0 / — / Artifact Signing Basic（追加案のみ） | 省略（追加時1,580.72/月） | 省略（追加時1,580.72/月） | 全月¥1,580.7177。作成直後から全月課金・日割なし、paid offer条件。標準案から省略。 |
| `microsoft.web/sites/slots` | 2 / B/R4 / Web App slot1＋Function App slot1 / S1 plan共有 | S1親に含む | S1親に含む | site/slotにplanを重複計上しない。 |
| `microsoft.network/natgateways` | 1 / B/R2 / StandardV2、未attach、flowlogs設定 | 661.40 | 689.88 | gateway ¥7.1204/h。Log Enabled月額¥632.92は按分分母未確定のため全月額を両案に確保。PIPなし。 |
| `microsoft.databricks/workspaces` | 1 / B/R2 / Premium、cluster/job/warehouseなし | 31.65 | 63.29 | 自動NAT1+StandardPIP1を計画数量として¥7.91155/h、managed Storageは従量/残余枠。実inventoryが異なれば再見積。 既存VNet参照のB/Japan Westへ移設。cluster/job/warehouseは作成しない。管理NAT/PIPの既存計画確保額は今回差し引かず据置。 |
| `microsoft.app/containerapps` | 1 / A/R1 / Consumption / minReplicas0 | 従量枠 | 従量枠 | scale-to-zero後の実行0を想定。初回起動CPU/メモリ/ログは従量枠。無料枠に依存しない。 |
| `microsoft.app/jobs` | 1 / A/R1 / Consumption / Manual / 未実行 | 従量枠 | 従量枠 | job実行なし。診断出力等は従量枠。 |
| `microsoft.app/managedenvironments` | 1 / A/R1 / Consumption / azure-monitor | 従量枠 | 従量枠 | Dedicated profile/NAT/PEは追加しない。環境のusageは従量枠。 |
| `microsoft.servicebus/namespaces` | 1 / A/R1 / Basic / メッセージ操作なし | 従量枠 | 従量枠 | ¥7.9115/100万ops。namespace本体の時間料はBasic料金表になし。ログ等は従量枠。 |
| `microsoft.web/hostingenvironments` | 1 / A/R1 / 空ASEv3 / 専用VNet+subnet | 367.09 | 734.19 | 空でもWindows I1v2 1台相当¥91.7734/h。追加可能な有料選択肢。長いprovision/deleteを全寿命に含む。 |
| `microsoft.communication/communicationservices` | 1 / A/R1 / global / 番号・通信なし | 従量枠 | 従量枠 | 通話/SMS/番号等の利用料は発生させない。診断従量は別。 |
| `microsoft.network/dnsresolverpolicies` | 1 / B/R2 / 空policy / rules・domainlistなし | 最低額未確定／残余枠 | 最低額未確定／残余枠 | query ¥94.938/100万件、domainlist ¥79.115/1000domains月の意味に要注意。空policy本体の最低料金は未確定。無償保証せず残余枠。 |
| `microsoft.network/expressroutecircuits` | 0 / — / provider offer / 回線条件未確定 | 省略・契約費未確定 | 省略・契約費未確定 | サービスキー発行からMicrosoft課金。短期hourly按分でもprovider/契約費は別、delete+provider deprovisionまで継続。未provision=無料とはしない。 |
| `microsoft.automation/automationaccounts` | 1 / A/R1 / Basic / runbookなし | 従量枠 | 従量枠 | 実行分課金の対象処理なし。関連Monitor料金は従量枠。 |
| `microsoft.relay/namespaces` | 1 / A/R1 / Standard / listenerなし | 従量枠 | 従量枠 | listener時間/送受信等は発生させない。診断従量は別。 |
| `microsoft.botservice/botservices` | 1 / A/R1 / F0 / UAMI1共有 | F0＋従量枠 | F0＋従量枠 | 有料channel/処理なし。F0の制限と作成可否は未確認。 |
| `microsoft.cache/redis` | 1 / A/R1 / Basic C0 | 13.92 | 27.85 | 新規顧客は2026-04-01以降作成制限。試行不能なら理由付きskip、他typeに置換しない。 |
| `microsoft.sql/servers` | 1 / A/R3 / SQL logical server / master | user DBに含む | user DBに含む | SQL user DBに計上。masterを追加の5DTU DBとして作成・計上しない。 |
| `microsoft.sql/servers/databases` | 1 / A/R3 / Basic 5DTU / user DB2GB | 28.01 | 28.01 | ¥28.00671/日を1日分確保（4/8h同額）。時間按分参考¥1.166946/h、5DTUを再度掛けない。DTU正確な最小課金粒度は未確認。 |
| `microsoft.search/searchservices` | 1 / A/R1 / Free1 / Basic1は追加選択肢 | 0.00 | 0.00 | Retail Free Unit=¥0/h。Free作成数/診断制約で不可ならskip。Basic有料代替¥21.04459/hは別途合意済予算内で計画修正、無断fallbackなし。 |
| `microsoft.web/serverfarms` | 1 / B/R4 / Linux S1 ×1 | 50.63 | 101.27 | site+slotで共有。plan停止でも割当capacity課金。PAYG秒単位。 |
| `microsoft.web/sites` | 2 / B/R4 / Linux Web App1＋Function App1 / S1共有 | S1親に含む | S1親に含む | 追加のplan instance、certificate、domainなし。 |
| `microsoft.logic/workflows` | 1 / A/R1 / Consumption / Disabled / 空actions | 従量枠 | 従量枠 | trigger/action/connector実行なし。 |
| `microsoft.recoveryservices/vaults` | 1 / A/R1 / 空Standard vault / 保護対象なし | 従量枠 | 従量枠 | Backup instance/storageなし。後で保護を有効化する費用は含めない。 |
| `microsoft.web/connections` | 1 / A/R1 / 未OAuth / 未使用connection | 従量／最低額未確定 | 従量／最低額未確定 | connector呼出なし。最低料金の公開確定なし、診断/残余枠。 |
| `microsoft.compute/virtualmachinescalesets` | 2 / B/R2 / Uniform / capacity0 / D2s_v4定義 | 実VM0（従量枠） | 実VM0（従量枠） | 実VM0・OSdisk0を維持。VMSS管理objectに別のcompute料金を掛けない。DCRA実可否は別問題。 |
| `microsoft.network/loadbalancers` | 1 fixture + AKS自動1 / B/R2 / Standard internal / fixture rule0 | AKS分はAKS行 | AKS分はAKS行 | fixtureのrule0は時間料なし（公式FAQ）。AKS側1LB/1outbound rule ¥3.95575/hはAKS行に含める。 |
| `microsoft.compute/disks` | 空1 + OS4（別行計上） / A/R3 / Empty1GiB Standard_LRS / 未attach | 0.00 | 0.00 | 一度もVM attachしない空diskは課金開始前（公式FAQ）。attach時はS4 32GiB bucket ¥267.4087/月=¥0.371401/h(Canada)を追加。VM/AKS OSは各行で計上。 |
| `microsoft.app/sessionpools` | 1 / A/R1 / PythonLTS / ready0 / session未作成 | 従量／ready0条件 | 従量／ready0条件 | ready0受理と地域は未確定。不成立ならskip。ready5/別SKUへ自動拡大しない。 |
| `microsoft.containerregistry/registries` | 1 / A/R1 / Basic / image未push | 26.36 | 26.36 | ¥26.361118/日。partial-day最小単位未確定のため丸1日を両案に確保。 |
| `microsoft.containerservice/managedclusters` | 1 / A/R1 / Free control plane +D2s_v4 Linux2 | 186.63 | 373.26 | 2nodes ¥39.24104/h +32GiB P4 OS2 ¥2.66899/h（既定SKU未確認）+LB1 ¥3.95575/h+PIP1 ¥0.79115/h。managed nodeRG全体削除。 |
| `microsoft.insights/datacollectionrules` | fixture3＋F1/F2新4＋Monitor自動候補1 / A/R1 / 旧DCR2+sentinel1 / 管理用DCR | 従量枠 | 従量枠 | DCR本体とdata ingestion/transformを分離。AMAなし、送信なし。DCEも管理台帳へ。 |
| `microsoft.monitor/accounts` | 1 / A/R1 / Azure Monitor workspace / scrapeなし | 従量枠 | 従量枠 | ¥17.4053/1000万samples ingest、¥0.15823/1000万samples query。意図的scrape/queryなし。 |
| `microsoft.apimanagement/service` | 1 / A/R1 / Developer1 | 41.65 | 83.29 | ¥10.411534/h。長いprovision/deleteを含む。partialhourは保守的にceil。 |
| `microsoft.bing/accounts` | 0 / — / Bing Search APIs終了 | 省略（退役） | 省略（退役） | 2025-08-11退役。新規作成不可のため省略。別製品を同resourceTypeとして数えない。 |
| `microsoft.cache/redisenterprise` | 1 / A/R1 / Managed Redis Balanced_B0 / NonHA | 12.66 | 25.32 | 公式One Node NonHA ¥0.020USD/h欄とRetailJPY3.1646/hを照合、quantity1。実作成可否は未確認。 |
| `microsoft.dbforpostgresql/flexibleservers` | 1 / A/R1 / B1ms /32GiB / HAなし | 20.34 | 40.68 | compute ¥4.11398/h +32×¥21.83574/GB月/720h。作成5分でも1h最小（compute+storage）をceil。 |
| `microsoft.documentdb/databaseaccounts` | 1 / A/R3 / serverless account / DB/containerなし | 従量枠 | 従量枠 | RU/request・保存dataを生成しない。管理/診断等のusageは別。 |
| `microsoft.network/applicationgateways` | 1 / B/R2 / Standard_v2 / autoscale min0,max2 | 196.21 | 392.41 | 固定¥49.0513/h。通信ゼロ・min0の公式例ではCU=0だが、計画では20CU×¥1.2658/hを別枠確保。max2はCU料金の上限ではない。PIPはPIP行。 |
| `microsoft.insights/components` | 1 / A/R3 / workspace-based / 別base LA | LA従量枠 | LA従量枠 | baseLAとSourceLAを分離。ingestはLA行の全体0.1GB枠に合算、二重課金しない。 |
| `microsoft.operationalinsights/workspaces` | 7 / A/R1・A/R3 / PerGB2018 / fixture3+新dest4 | 従量枠 | 従量枠 | JPE¥528.4882/GB、Canada¥436.7148/GB。5GB無料枠を差し引かない。全workspace合計0.1GBを従量予備枠へ。 |
| `microsoft.network/azurefirewalls` | 1 / B/R2 / AZFW_VNet Standard / 非forced-tunnel / policy1 | 791.15 | 1,582.30 | Japan West Standard deployment ¥197.7875/h +data ¥2.53168/GB。prescaling/AI add-onは無効、追加CU料金なし。policy1の既存計画とPIP確保額は据置（不要となる管理PIP分も差し引かない）。新AzureFirewallManagementSubnetを作成しない。 |
| `microsoft.network/dnszones` | 1 / B/R2 / Public DNS zone / global | 5.27 | 5.27 | ¥79.115/月。日単位課金としてNov30日中の最大2calendar daysを確保。query¥63.292/100万件は従量枠。 |
| `microsoft.network/networksecuritygroups` | 1 / B/R2 / 空NSG / flowLogsなし | 従量枠／本体meterなし | 従量枠／本体meterなし | NSG本体の別meterは確認できず、通常の本体存在料は計上せず。TrafficAnalytics等は有効化しない。無料請求保証ではない。 |
| `microsoft.network/privatednszones` | 1 / B/R2 / Private DNS zone / global / linkなし | 5.27 | 5.27 | Publicと同額¥79.115/月、最大2calendar daysを確保。 |
| `microsoft.network/virtualnetworks` | 既存2（参照） / A・B / 固定5subnet | 0.00 | 0.00 | VNet/NSG自体の固定存在料は0。NetworkPrepで用意する既存2VNetと固定5subnetを参照し、main fixtureから新VNetを作らない。peering、DDoS paid、VPNgatewayなし。 |
| `microsoft.kusto/clusters` | 1 / A/R1 / Dev Basic E2a_v4 / engine1+DM1 | 96.20 | 192.41 | 既知engine VM ¥24.05096/hのみ本行。DevはmarkupなしだがDM1台も必要。DM SKU、managed disk/LBは未確定で別のmanaged残余枠¥500を確保。 |
| `microsoft.network/privateendpoints` | 1 / B/R2 / Storage blob target / 未通信 | 6.33 | 12.66 | ¥1.5823/h、端数hour切上。ingress/egress各¥1.5823/GBとStorageは従量枠。 |
| `microsoft.compute/virtualmachines` | 2 / A/R1 / D2s_v4 Linux / OS32GiB Standard_LRS2 | 159.66 | 319.33 | 2×¥19.62052/h+2×S4 ¥243.04128/月/720h。normal bootdisk I/Oは従量枠。VM computeは分単位、OSdiskはDELETEまで。 |
| `microsoft.network/networkinterfaces` | 1 fixture + VM2 + PE自動1 / B/R2 / 通常NIC / paid featureなし | 従量枠／本体meterなし | 従量枠／本体meterなし | 通常NICに別meterを確認できず本体存在料を計上しない。Accelerated Connections/TAPなし。 |
| `microsoft.network/publicipaddresses` | 3 fixture + AKS1/DBX1は各行 / B/R2 / Standard static IPv4 | 9.49 | 18.99 | fixtureはAppGW用1+Firewall用2。¥0.79115/h×3、firsthour割引を見込まず全時間確保。AKS/DBX各1PIPは各row。NATV2のPIPは作らない。 |
| `microsoft.eventgrid/systemtopics` | 1 / A/R3 / Storage system topic / eventsubなし | 従量枠 | 従量枠 | イベント配信なし。診断等のusageは別。 |
| `microsoft.keyvault/vaults` | 1 / A/R3 / Standard / key・secret操作なし | 従量枠 | 従量枠 | Premium HSM/ManagedHSMなし。softdelete7日残存とname再利用はcleanupへ。Standard object本体存在料は想定せず操作従量。 |
| `microsoft.storage/storageaccounts` | 最大6 + provider管理Storage候補 / A/R3 / LRS1Canada+destZRS最大5(A:JPE/Canada; B:JPW/WestUS2/条件付きJPE) | 従量枠 | 従量枠 | fixture LRS1と送信先ZRS最大5を区別。Bのglobal DNS等でSourceDiagを設定できた場合に東日本fallback宛先が必要。実数はSeedと事前チェック後に確定。固定存在料はなく、provider管理分を含むStorage合計1GB・既存操作予備枠を据置。HotZRS最大¥3.95575/GB月、write/list最大¥10.886224/10K、read¥0.696212/10K。 |
| `microsoft.machinelearningservices/workspaces` | 1 / A/R3 / workspace / compute・managednetworkなし | 共有依存＋従量枠 | 共有依存＋従量枠 | Storage/KV/AppInsightsを共有。workspaceだけのcompute料なし想定。managedNetwork Disabled、PE/Firewall追加なし。 |
| `microsoft.cognitiveservices/accounts/projects` | 1 / A/R3 / 親AIServices S0共有 / project | 最低額未確定／残余枠 | 最低額未確定／残余枠 | model/agent/runtime等なし。projectのみの最低額は未確定、残余枠。 |
| `microsoft.cognitiveservices/accounts` | 1 / A/R3 / AIServices S0 / model deployなし | 最低額未確定／残余枠 | 最低額未確定／残余枠 | S0は無料tier名ではない。token/API/model処理なし。accountのみの最低額は未確定、残余枠。 |

## 予備枠と未確定点

Workspace7とDCR8の数量は据え置きです。Storageは指定最大6（fixture1＋宛先最大5）を見込みますが、固定存在料金はなく全体の取り込み量と従量予備枠を据え置きます。Standard Firewallの差額を含む新計画額は上表のとおりです。既存承認6,000円は変更せず、8h案の超過は未承認として扱います。

**小容量500円**は、7LA合計0.1GB（最大52.85円）、Storage全体1GB（丸1か月としても最大3.96円）、write10K＋read/list10K（各最大10.89円）を想定し、通常boot I/O、診断出力、少量network等の余裕を含める。意図的なログ生成、通信、推論、job/runbook実行は行わない。LA1GBを予定するならこの枠を1,000円へ増やす。無料5GB枠は他用途で消費済みでも成立するよう差し引かない。

**管理資産・未確定500円**はKustoのDM/managed disk/LB、Databricks管理Storage/想定超過、空DNS policy・AI account/project・connectionの最低料金未確定を含む。base38にも同額を確保し、その場合は空DNS policy・AI account/project等の未確定最低料金に充てる。Kustoは公式資料でDevでもengine1＋DM1と明記され、既知24.05096円/hはengine VMのみ。追加DMをE2a_v4相当24.05096円/h、P10 128GiBを1枚3,587.0741円/月/720h、network5円/hとする計画例は10hで約340.33円だが、これは実Kusto構成や上限の立証ではない。inspectで実SKU/数量・最低料金が仮定を超えるなら当該bundleを止めて再見積する。既知subtotalを完成請求額として提示していない。

AppGWはmin0/max2。公式のmin0・通信0の例ではCU0だが、ここでは追加20CU×1.2658円/hを確保している。max2は料金上限ではない。ASEは空でも91.7734円/h、4h367.09円/8h734.19円なので、絶対的に高すぎる型とはせず追加選択肢に戻した。Free Searchが不適合の場合のBasic追加は4h84.18円/8h168.36円。無断のSKU拡大・ready5化・高額region変更はしない。

Bingは退役によるskip。CodeSigningは作成直後からBasic全月1,580.72円、日割なし、paid offer制約・月境界の扱いも未確定のためskip案。ExpressRouteはサービスキー発行でMicrosoft課金が始まり、provider/契約費が別、停止に削除とprovider deprovisionが必要で、未provisionなら無料とはならない。provider offerと終了条件未確定のためskip案。

## 単価の原本と課金粒度

- [単一JSONのapps根拠](budget-estimate.json#embeddedSources)（`embeddedSources.apps` / `officialDocuments`）: exact meter/product/OS、sourceURL、fetchedAt、月/日/時単位、最小課金条件を保存。
- [単一JSONのdata根拠](budget-estimate.json#embeddedSources)（`embeddedSources.data` / `officialDocuments`）: Redis NonHA quantity照合、PG、SQL、Storage/LA、Kusto残余の証拠を保存。
- [単一JSONのnetwork根拠](budget-estimate.json#embeddedSources)（`embeddedSources.network`）: JPY Retail Consumptionの地域別/Global primary meterとAPI rawを保存。
- 取得日時は2026-11-18 UTC（network約05:24–05:26、apps/data約05:54–06:06）。各recordの`fetchedAt`と`effectiveStartDate`を区別する。API原本は`/tmp`研究証拠に保持し、repoへコピー不要。選択meter・公式URL・取得日時は単一JSONに埋め込んだ。JPYはRetailの表示見積で契約/税/割引を反映した請求書ではない。
- NAT/PE/LBは部分hourの切上げ、PGは最低1h、AppServiceは秒、VMは分、managed diskは月額の時間按分。November2026の月額按分は720h。DNSは日単位。NAT logの720/730按分差、ACR/SQL partial-day粒度は少額でも隠さず全月/全日を確保。PIPのfirsthour免除は差し引かない。
- [機械可読の全数量・計算・未確定点](budget-estimate.json)。候補SHAで後続変更との差を識別する。manifest/ARM/API rawのsnapshotは`/tmp`研究証拠に保持し、配布時はこのMarkdownと単一JSONだけで見積根拠を追跡できる。

利用者の選択は53タイプ・ASE込み・予算目安6,000円維持、4時間目標・6時間計画枠です。旧環境の撤去完了後、実環境の可用性・数量がこの仮定に一致することを確認して進めます。

構成見直しの新規Retail出典（JPY・Consumption、原応答と選択meterはJSONへ保持）:

- [d2sv4-japaneast](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27JPY%27&%24filter=serviceName+eq+%27Virtual+Machines%27+and+armSkuName+eq+%27Standard_D2s_v4%27+and+armRegionName+eq+%27japaneast%27+and+priceType+eq+%27Consumption%27)
- [s1-westus2](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27JPY%27&%24filter=serviceName+eq+%27Azure+App+Service%27+and+skuName+eq+%27S1%27+and+armRegionName+eq+%27westus2%27+and+priceType+eq+%27Consumption%27)
- [storage-westus2](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27JPY%27&%24filter=serviceName+eq+%27Storage%27+and+productName+eq+%27General+Block+Blob+v2%27+and+armRegionName+eq+%27westus2%27+and+priceType+eq+%27Consumption%27)

Standard Firewallの公開出典（Japan West、JPY Consumption）: [https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27JPY%27&%24filter=serviceName+eq+%27Azure+Firewall%27+and+armRegionName+eq+%27japanwest%27+and+priceType+eq+%27Consumption%27](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27JPY%27&%24filter=serviceName+eq+%27Azure+Firewall%27+and+armRegionName+eq+%27japanwest%27+and+priceType+eq+%27Consumption%27)。CUの条件: [Azure Firewall pricing](https://azure.microsoft.com/en-us/pricing/details/azure-firewall/)。
