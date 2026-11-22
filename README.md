# SHEET MASTER — 図面の撮影・AI寸法解析・DXF出力

## 2026-11-22 現在
- 写真撮影・写真選択
- Google Geminiへの画像解析リクエストを **Firebase AI Logic のApple SDK** から直接実行（独自サーバー不要）
- Google側でAI Logicを有効化し、Firebase App CheckにiOSアプリを登録する必要がある。これらのクラウド設定と実機API通信の成功は未確認
- 接続失敗時のみ端末内のApple Vision解析に切り替え、画面に切替理由を明示
- 深い赤の背景・白い文字・黄色い主要ボタン
- 寸法と穴の中心X/Y/直径Φ表示、修正、照合確認後のDXF R12出力
- DXFはCAD/CAMへの受け渡しのみ。AMADA専用NCコード生成・加工機械の運転制御はしない
- AI結果が正しいことを前提にせず、必ず原図の全寸法・穴数・座標・直径を照合すること

## 準備・公開
iOSプロジェクト: `AMADAOffline.xcodeproj`
共有スキーム: `AMADAOffline`
Codemagic: `codemagic.yaml`
Firebase: `sheet-master-e2aa0`
Bundle ID: `com.shu39a.amadaoffline`

Firebaseコンソールで Firebase AI Logic の Gemini Developer API を有効にする必要がある。
Firebase App Check で iOS アプリに App Attest を登録する。Apple App Attest の production entitlement はXcodeに追加済み。
Google AI利用料金の管理と予算アラートを設定する。
ビルド・署名・TestFlight反映・実機精度は独立に確認する。

`cloud-recognition/` は以前検討したカスタムCloud Run案で、**現在のiOSアプリでは利用しない**。
