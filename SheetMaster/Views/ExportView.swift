import SwiftUI

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
        .sheet(item: $zoom) { f in FullPreviewView(title: f.title, built: f.built) }
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
