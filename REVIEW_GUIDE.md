# 正本のレビュー資料

正本は [procedural-migration](procedural-migration/README.md) の手続型PowerShell 7版です。説明を重複させないため、設定・実行手順・共通関数・変更前記録・再実行・切り戻し・実測値は同フォルダのREADMEへまとめています。

読む順番は次のとおりです。

1. 説明資料の「設定と実行」でCSVと変数を確認する。
2. step1_copy.ps1を上から読み、調査→変更前記録→設定の順を確認する。
3. step2_verify.ps1とstep3_delete.ps1で、全件成功してから削除する流れを確認する。
4. rollback.ps1で、旧設定を先に戻してから新設定を外す流れを確認する。
5. common.ps1は呼ばれた関数だけ参照する。関数の前に引数・戻り値・処理条件を記載している。

[72ケースの一覧](test-results/PROCEDURAL_CASES.md)、[Windowsでの個別結果](test-results/procedural-windows7.json)、[文字数比較](test-results/procedural-size.json)も確認できます。従来のmigration版の185ケースは旧版の記録です。

最後のリソース網羅・負荷テストは、この正本のレビュー後に実施します。

初心者向けに、各ブロックとPowerShellの構文を詳しく説明した[コメント拡充版](procedural-migration-commented/README.md)も用意しています。コードは正本と同じで、正本の主要6本は変更していません。
