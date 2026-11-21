# 図面レーザーDXF — iOS App Storeアップロード準備パッケージ v1.0

5工程をすべて含むオフラインSwiftUIアプリです。月額AI API・Webサーバー費用はありません。Apple DeveloperとCodemagic等の費用は別。

## 実装済み
- iPhoneカメラ・写真ライブラリ読み込み（画像の向きを正規化）
- Apple Vision OCR、矩形・輪郭・丸穴候補の抽出
- 外形寸法・角C・材質・板厚・穴径・座標の編集および加工図プレビュー
- 穴の外形はみ出し、穴同士の重複、角C付近の干渉確認
- 原図との照合確認後のみDXF R12出力・共有
- AMADA等のCAD/CAMへの受け渡し案内
- iOSアプリアイコン、プライバシーマニフェスト、カメラ説明、Codemagic YAML、ストア文案

## 制約（公開前に要検証）
- 複雑形状、切欠き、長穴、寸法線や文字と切断輪郭の完全な区別、OCRの寸法自動確定は未対応。
- 丸穴検出は未確認の候補。原図の寸法を見て補正してからDXF出力してください。
- 実際のAMADA CAD/CAMでDXF互換性の実証が必要。NCプログラムは生成しません。
- LinuxでSwiftの構文解析は可能ですが、Apple SDKを使ったXcodeビルド・署名は未実施です。

## 開き方
`AMADAOffline.xcodeproj`をXcodeで開き、Apple Teamと署名を設定。Codemagicではルートの`codemagic.yaml`を利用。
