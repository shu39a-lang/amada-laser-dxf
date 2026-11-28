import SwiftUI

@main
struct SheetMasterApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                // v3.9: アマダの機械の色(赤い本体・白いロゴ)。リンクや小さいボタンは白
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack { HomeView() }
    }
}

/// v3.9: アプリの色。アマダ LASMAC の機械の写真から取った色。ここを変えると全画面の色が変わる
enum Theme {
    /// アマダの赤(機械の本体)。大きいボタンの文字・番号の丸の文字など
    static let red = Color(red: 0xCC / 255.0, green: 0x32 / 255.0, blue: 0x31 / 255.0)
    /// 画面の背景(本体の赤を少し暗くした色。白い文字が読みやすい)
    static let background = Color(red: 0x8E / 255.0, green: 0x22 / 255.0, blue: 0x20 / 255.0)
    /// 機械の上カバーのグレー
    static let gray = Color(red: 0x66 / 255.0, green: 0x63 / 255.0, blue: 0x5E / 255.0)
    /// 暗いカードの上で読める明るい赤(「部品1」などの見出し)
    static let redText = Color(red: 1.0, green: 0x5A / 255.0, blue: 0x55 / 255.0)
    /// 大きいボタン・リンク(機械のロゴの白)
    static let accent = Color.white
}

extension View {
    /// v3.9: 一覧・入力画面の背景をアマダの赤にする
    func smScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .toolbarBackground(Theme.background, for: .navigationBar)
    }
}
