# App Store Connect / TestFlight への最短工程

## 事前作業（このZIPで実装済み）
- SwiftUI 5工程、端末内Vision、DXF、カメラ権限、App Icon、Privacy Manifest、Codemagic YAML。
- Bundle ID 仮設定: `com.shu39a.amadaoffline`。Apple Developer側に登録・使用可能か未確認。

## 実際にアップロードするための外部設定（未完了）
1. Apple DeveloperでBundle IDが使用可能か確認し、App Store Connectに新しい「図面レーザーDXF」レコードを作成。既存の別アプリのBundle IDは流用しない。
2. GitHubの専用リポジトリを作り、このZIPの`AMADA_Offline_iOS`フォルダ内のファイルをリポジトリのルートへ配置。`codemagic.yaml`はルート必須。
3. Codemagicで専用リポジトリを追加。YAML workflow `ios-testflight`を選択。`app_store_connect: codemagic`は既存の統合名が違う場合だけ置き換える。
4. Apple Distribution証明書とApp Store provisioning profileをCodemagicに設定。Start new buildで署名付きIPAを生成。グリーンになったらApp Store ConnectのTestFlightでビルドを確認。
5. TestFlightで実機テスト。特に撮影・OCR・穴位置・DXFのCAM互換性。問題修正の後、App Store申請情報を入力。

注意：ここにあるのはアップロード対象のソースであり、IPAではありません。Xcodeビルド・署名・TestFlight転送はまだ未実行です。
