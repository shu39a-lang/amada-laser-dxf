import SwiftUI
import UIKit

// MARK: - 設定(歯車ボタンから)

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var saved = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Claude APIキー") {
                SecureField("sk-ant-…", text: $keyText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(saved ? "保存しました" : "保存") {
                    store.apiKey = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved = true
                }
                Text(store.apiKey.isEmpty ? "未設定" : "設定済み").font(.caption).foregroundStyle(.secondary)
            }
            Section("読み取り") {
                Picker("AIモデル", selection: $store.settings.model) {
                    ForEach(AppSettings.models.indices, id: \.self) { i in
                        Text(AppSettings.models[i].label).tag(AppSettings.models[i].id)
                    }
                }
                Picker("拡大の細かさ", selection: $store.settings.tileMode) {
                    ForEach(TileMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                NavigationLink("曲げ控除表") { DeductionTableView() }
                NavigationLink("タップ下穴表") { TapTableView() }
            } footer: {
                Text("控除表の初期値は仮の値です。現場の曲げ控除表の数値に入れ替えてください。")
            }
            Section("DXF") {
                Toggle("曲げ線もDXFに入れる(BENDレイヤー)", isOn: $store.settings.includeBendLayer)
                Toggle("ファイル名を英数字のみにする", isOn: $store.settings.asciiFileNames)
            }
            Section {
                NavigationLink("会社のパソコンへの送り方") { TransferGuideView() }
                LabeledContent("バージョン", value: AppInfo.version)
            }
        }
        .smScreen() // v3.9: アマダの赤の背景
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        .onAppear { keyText = store.apiKey }
    }
}

struct DeductionTableView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List {
            ForEach(["SPCC", "SUS", "AL"], id: \.self) { g in
                Section(g == "SPCC" ? "SPCC / SPHC / SS400" : (g == "SUS" ? "SUS" : "アルミ")) {
                    ForEach($store.settings.deductions) { $row in
                        if row.materialGroup == g {
                            HStack {
                                NumField(label: "t", value: $row.thickness)
                                NumField(label: "V", value: $row.vWidth)
                                NumField(label: "控除", value: $row.value90)
                                    .onChange(of: row.value90) { _, _ in $row.provisional.wrappedValue = false }
                                // v4.0: 45°曲げの控除値(空欄・0なら理論式で計算)
                                NumField(label: "45°", value: Binding(
                                    get: { row.value45 ?? 0 },
                                    set: { $row.value45.wrappedValue = $0 > 0 ? $0 : nil }))
                                if row.provisional { Text("仮").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                    }
                    Button("\(g) の行を追加") {
                        store.settings.deductions.append(DeductionRow(materialGroup: g, thickness: 0, vWidth: 0, value90: 0, provisional: false))
                    }
                }
            }
            Section {
                Button("仮マークをすべて外す(会社の表を入力済み)") {
                    for i in store.settings.deductions.indices { store.settings.deductions[i].provisional = false }
                }
                Button("初期値に戻す", role: .destructive) { store.settings.deductions = AppSettings.defaultDeductions }
            } footer: {
                Text("控除 = 90°曲げ1回あたりの控除値(mm)。展開長 = 外寸の合計 − 控除値×曲げ回数。\n45° = 45°曲げ1回あたりの控除値(わかれば。例: SUS t1.5 で 0.4)。0のままなら90°の値から理論式で計算します。図面に手書きの控除(「−0.8」など)があれば、そちらを優先します。")
            }
        }
        .smScreen() // v3.9: アマダの赤の背景
        .navigationTitle("曲げ控除表")
    }
}

struct TapTableView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List {
            ForEach($store.settings.tapDrills) { $row in
                HStack {
                    TextField("M3", text: $row.size).frame(width: 70)
                    NumField(label: "下穴φ", value: $row.drill)
                }
            }
            .onDelete { store.settings.tapDrills.remove(atOffsets: $0) }
            Button("行を追加") { store.settings.tapDrills.append(TapDrillRow(size: "M", drill: 0)) }
        }
        .smScreen() // v3.9: アマダの赤の背景
        .navigationTitle("タップ下穴表")
    }
}

struct TransferGuideView: View {
    var body: some View {
        List {
            Section("iPhone → 会社のパソコン") {
                Label("「DXFファイルを作る」→「まとめて送る・保存する」", systemImage: "1.circle")
                Label("OneDrive / Googleドライブ / メール などを選んで保存", systemImage: "2.circle")
                Label("会社のパソコンで同じ場所からDXFを取り出す(USBメモリ経由でも可)", systemImage: "3.circle")
                Label("アマダのソフトでDXFを読み込み、割付・加工条件を設定", systemImage: "4.circle")
            }
            Section("DXFの中身") {
                Text("・形式: AutoCAD R12、単位mm、原点は左下\n・切る線はすべて CUT レイヤー(線・円弧・円)\n・曲げ線は設定でONのときだけ BEND レイヤー\n・勝手違いは _MIRROR 付きの別ファイル\n・ファイル名の _x2 は必要枚数")
                    .font(.footnote)
            }
        }
        .smScreen() // v3.9: アマダの赤の背景
        .navigationTitle("送り方")
    }
}

// MARK: - 共通部品

struct NumField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .font(.footnote.monospacedDigit())
        }
    }
}

struct ThicknessField: View {
    @Binding var part: Part
    @State private var text = ""

    var body: some View {
        // v4.0: 板厚が無ければ赤(必須)、AIの推定ならオレンジ(要確認)
        let level: Attention = part.thickness == nil ? .required : (part.thicknessSource == "inferred" ? .check : .ok)
        HStack(spacing: 4) {
            TextField("必須", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onAppear { text = part.thickness.map(Fmt.num) ?? "" }
                .onChange(of: text) { _, t in
                    let v = Double(t.trimmingCharacters(in: .whitespaces))
                    if v != part.thickness {
                        part.thickness = v
                        part.thicknessSource = v == nil ? "unknown" : "user"
                    }
                }
            AttentionTag(level: level)
        }
        .attention(level)
    }
}

// MARK: - v4.0 注意の色分け
//  赤(必須)  : 入れないとDXFを作れない・正しく作れない所(板厚・材質など)
//  オレンジ(要確認): AIの推定・図面に寸法が無かった所。図面と見比べて確かめる所
//  どの画面でも同じ色・同じ札にして、ひと目で分かるようにする

enum Attention {
    case required
    case check
    case ok
}

/// 「必須」「要確認」の小さな札
struct AttentionTag: View {
    let level: Attention

    var body: some View {
        switch level {
        case .required:
            Text("必須")
                .font(.caption2.bold())
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
                .overlay(Capsule().stroke(Color.white, lineWidth: 1))
        case .check:
            Text("要確認")
                .font(.caption2.bold())
                .foregroundStyle(Color.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange))
        case .ok:
            EmptyView()
        }
    }
}

/// 背景の色分け(赤い画面の上でも見えるよう、白・オレンジの枠を付ける)
struct AttentionBackground: ViewModifier {
    let level: Attention

    @ViewBuilder
    func body(content: Content) -> some View {
        switch level {
        case .required:
            content
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 2))
        case .check:
            content
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2))
        case .ok:
            content
        }
    }
}

extension View {
    /// v4.0: 赤(必須)・オレンジ(要確認)の背景を付ける
    func attention(_ level: Attention) -> some View {
        modifier(AttentionBackground(level: level))
    }
}

/// v4.0: 色の意味の説明(②の画面の上に出す)
struct AttentionLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            AttentionTag(level: .required)
            Text("必ず入力").font(.caption)
            AttentionTag(level: .check)
            Text("推定・図面と確認").font(.caption)
        }
    }
}

struct RawTextView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onPick(info[.originalImage] as? UIImage)
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPick(nil)
            parent.dismiss()
        }
    }
}
