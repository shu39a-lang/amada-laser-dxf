import SwiftUI
import UIKit

/// ③ DXFファイルを作る(できたファイルの中身を確認してから送る)
struct ExportView: View {
    @Environment(AppStore.self) private var store
    let drawingID: UUID
    @State private var files: [Exporter.ExportedFile] = []
    @State private var skipped: [String] = []
    @State private var made = false
    @State private var showShare = false
    @State private var zoom: Exporter.ExportedFile?

    var body: some View {
        List {
            Section {
                StepHeader(number: 3, title: "DXFファイル")
                if made {
                    Text(files.isEmpty ? "作れたファイルはありません" : "\(files.count)個のファイルができました。形を確かめてから送ってください。")
                        .font(.subheadline)
                }
            }
            if made && !files.isEmpty {
                // v3.5: 「ファイル」アプリに自動で保存した場所
                Section {
                    HStack {
                        Text("会社名").foregroundStyle(.secondary)
                        TextField("例: 日新電子工業", text: companyBinding)
                    }
                    let folders = Array(Set(files.compactMap(\.savedFolder))).sorted()
                    if folders.isEmpty {
                        Text("「ファイル」アプリへの保存に失敗しました").foregroundStyle(.red).font(.footnote)
                    } else {
                        // v3.8: タップすると「ファイル」アプリでそのフォルダを開く
                        ForEach(folders, id: \.self) { f in
                            Button {
                                openInFiles(f)
                            } label: {
                                HStack {
                                    Label(f, systemImage: "folder.fill").font(.footnote)
                                    Spacer()
                                    Text("開く").font(.footnote.bold())
                                }
                            }
                        }
                    }
                    Button("この会社名で保存し直す") { make() }
                        .font(.footnote)
                } header: {
                    Text("iPhoneに自動で保存しました")
                } footer: {
                    Text("「ファイル」アプリ → このiPhone内 → SHEET MASTER(アプリのアイコン付きのフォルダ)→ DXF → 会社 → 素材 → 板厚 のフォルダに入っています。フォルダ名をタップすると「ファイル」アプリで開きます。会社名が違っていたら直して「保存し直す」を押してください。")
                }
            }
            if !files.isEmpty {
                Section("できたファイル") {
                    ForEach(files) { f in
                        HStack(spacing: 12) {
                            PartPreview(built: f.built, showLabels: false)
                                .frame(width: 96, height: 70)
                                .onTapGesture { zoom = f }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(.subheadline.bold()).lineLimit(2)
                                Text("\(Fmt.num(f.built.width)) × \(Fmt.num(f.built.height)) mm ・ 穴\(f.built.holeLabels.count)個 ・ \(f.quantity)枚")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(f.url.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showShare = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("まとめて送る・保存する", systemImage: "square.and.arrow.up").font(.title3.bold())
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("OneDrive・Googleドライブ・メール・「ファイル」アプリなどに保存して、会社のパソコンで開いてください。")
                }
            }
            if !skipped.isEmpty {
                Section("作れなかった部品") {
                    ForEach(skipped, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                    Text("前の画面で「数値を直す」(板厚の入力など)か「指示して読み直す」をしてから、もう一度作ってください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink("会社のパソコンへの送り方") { TransferGuideView() }
            }
        }
        .navigationTitle("DXFファイル")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: make)
        .sheet(isPresented: $showShare) { ShareSheet(items: files.map(\.url)) }
        .sheet(item: $zoom) { f in
            // v2.9: ここからも見比べられるようにする(勝手違いは写真と左右が逆なので除く)
            if f.title.contains("勝手違い") {
                FullPreviewView(title: f.title, built: f.built)
            } else {
                FullPreviewView(title: f.title, built: f.built, loadImages: {
                    guard let d = store.drawings.first(where: { $0.id == drawingID }) else { return [] }
                    return d.imageFiles.compactMap { store.loadImage($0) }
                })
            }
        }
    }

    private var companyBinding: Binding<String> {
        Binding(
            get: { store.drawings.first(where: { $0.id == drawingID })?.company ?? "" },
            set: { v in
                if let di = store.drawings.firstIndex(where: { $0.id == drawingID }) {
                    store.drawings[di].company = v
                    store.save()
                }
            }
        )
    }

    /// v3.8: 保存したフォルダ(DXF/会社/素材/板厚)を「ファイル」アプリで開く
    private func openInFiles(_ folder: String) {
        let dir = Exporter.dxfRoot.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true)
        let path = dir.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dir.path
        if let url = URL(string: "shareddocuments://" + path) {
            UIApplication.shared.open(url)
        }
    }

    private func make() {
        guard let d = store.drawings.first(where: { $0.id == drawingID }) else { return }
        let items = d.parts.filter { $0.process == .laser && $0.include }.map { Exporter.Item(drawing: d, part: $0) }
        let r = Exporter.exportFiles(items: items, settings: store.settings)
        files = r.files
        skipped = r.skipped
        made = true
    }
}
