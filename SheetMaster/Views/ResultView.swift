import SwiftUI

struct PartRef: Identifiable, Hashable {
    let id: UUID
}

/// ② 形を確かめる(部品1・部品2… ごとに大きなプレビュー)
struct ResultView: View {
    @Environment(AppStore.self) private var store
    let drawingID: UUID
    @State private var editing: PartRef?
    @State private var rereading: PartRef?
    @State private var zooming: PartRef?
    @State private var comparing: PartRef?
    @State private var addingPart = false
    @State private var showExport = false
    @State private var showOriginal = false

    private var drawing: DrawingRecord? { store.drawings.first { $0.id == drawingID } }

    var body: some View {
        if let d = drawing {
            let laser = d.parts.filter { $0.process == .laser }
            let others = d.parts.filter { $0.process != .laser }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StepHeader(number: 2, title: "形を確かめる")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title.isEmpty ? "(品名なし)" : d.title).font(.title3.bold())
                        Text("図番 \(d.drawingNumber)" + (d.productNumber.isEmpty ? "" : "  製番 \(d.productNumber)"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(laser.count <= 1 ? "この図面の板は1種類です" : "この図面には\(laser.count)種類の板があります(部品1〜\(laser.count))")
                            .font(.subheadline).foregroundStyle(.yellow).padding(.top, 4)
                    }

                    if !d.questions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("確認してください").font(.subheadline.bold()).foregroundStyle(.orange)
                            ForEach(d.questions, id: \.self) { Text("・" + $0).font(.footnote) }
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
                    }

                    if laser.isEmpty {
                        Text("板の部品が見つかりませんでした。写真を撮り直すか、下の「元の図面を見る」で写真を確認してください。")
                            .foregroundStyle(.red)
                    }

                    ForEach(Array(laser.enumerated()), id: \.element.id) { pair in
                        PartCard(number: pair.offset + 1, part: pair.element, settings: store.settings,
                                 onEdit: { editing = PartRef(id: pair.element.id) },
                                 onReread: { rereading = PartRef(id: pair.element.id) },
                                 onZoom: { zooming = PartRef(id: pair.element.id) },
                                 onCompare: { comparing = PartRef(id: pair.element.id) })
                    }

                    // v3.0: 部品表に無い板(妻板など)を作業者が足す
                    Button {
                        addingPart = true
                    } label: {
                        Label("板を追加して読む", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Text("図面に描かれているのに出てこない板(両端の妻板など)があれば、ここから「①の下の台形も板」のように一言書いて追加できます。")
                        .font(.caption).foregroundStyle(.secondary)

                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("レーザー対象外(データは作りません)").font(.subheadline.bold())
                            ForEach(others) { p in
                                HStack {
                                    Text("・\(p.name)(\(p.process.label))").font(.footnote)
                                    Spacer()
                                    // AIが板を対象外に分けてしまったとき用
                                    Button("板として読む") { makeLaser(p.id) }
                                        .font(.caption).buttonStyle(.bordered)
                                }
                            }
                        }
                        .foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.09)))
                    }

                    Button {
                        showOriginal = true
                    } label: {
                        Label("元の図面を見る", systemImage: "doc.text.image")
                    }
                    .padding(.bottom, 90)
                }
                .padding()
            }
            .navigationTitle("読み取り結果")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    showExport = true
                } label: {
                    HStack {
                        Spacer()
                        Text("3").font(.headline).frame(width: 26, height: 26).background(Circle().fill(Color.black.opacity(0.2)))
                        Text("DXFファイルを作る").font(.title3.bold())
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
                .disabled(laser.isEmpty)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.ultraThinMaterial)
            }
            .sheet(item: $editing) { ref in
                PartEditSheet(drawingID: drawingID, partID: ref.id)
            }
            .sheet(item: $rereading) { ref in
                RereadSheet(drawingID: drawingID, partID: ref.id)
            }
            .sheet(item: $zooming) { ref in
                if let p = d.parts.first(where: { $0.id == ref.id }) {
                    FullPreviewView(title: p.name, built: Geometry.build(part: p, settings: store.settings),
                                    loadImages: { d.imageFiles.compactMap { store.loadImage($0) } },
                                    savedAlign: p.manualAlign,
                                    onSaveAlign: { saveAlign(p.id, $0) })
                }
            }
            .sheet(isPresented: $addingPart) {
                AddPartSheet(drawingID: drawingID)
            }
            .sheet(item: $comparing) { ref in
                if let p = d.parts.first(where: { $0.id == ref.id }) {
                    CompareSheet(title: p.name, built: Geometry.build(part: p, settings: store.settings),
                                 loadImages: { d.imageFiles.compactMap { store.loadImage($0) } },
                                 savedAlign: p.manualAlign,
                                 onSaveAlign: { saveAlign(p.id, $0) })
                }
            }
            .navigationDestination(isPresented: $showExport) {
                ExportView(drawingID: drawingID)
            }
            .sheet(isPresented: $showOriginal) {
                NavigationStack {
                    ScrollView {
                        ForEach(d.imageFiles, id: \.self) { f in
                            if let img = store.loadImage(f) { Image(uiImage: img).resizable().scaledToFit() }
                        }
                    }
                    .navigationTitle("元の図面")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink("AIの返答") {
                                RawTextView(title: "部品一覧の返答", text: d.rawInventory ?? "まだ返答がありません")
                            }
                        }
                    }
                }
            }
        } else {
            Text("図面が見つかりません")
        }
    }

    /// v3.1: 見比べ画面で手で合わせた写真の位置を部品に保存(次に開いたときも同じ位置)
    private func saveAlign(_ partID: UUID, _ v: [Double]?) {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
              let pi = store.drawings[di].parts.firstIndex(where: { $0.id == partID }) else { return }
        store.drawings[di].parts[pi].manualAlign = v
        store.save()
    }

    /// 対象外の部品をレーザー部品に変えて、読み直しの画面を開く
    private func makeLaser(_ partID: UUID) {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
              let pi = store.drawings[di].parts.firstIndex(where: { $0.id == partID }) else { return }
        store.drawings[di].parts[pi].process = .laser
        store.drawings[di].parts[pi].include = true
        store.save()
        rereading = PartRef(id: partID)
    }
}

/// 部品1枚分のカード
struct PartCard: View {
    let number: Int
    let part: Part
    let settings: AppSettings
    var onEdit: () -> Void
    var onReread: () -> Void
    var onZoom: () -> Void
    var onCompare: () -> Void = {}

    var body: some View {
        let built = Geometry.build(part: part, settings: settings)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("部品\(number)").font(.title2.bold()).foregroundStyle(.yellow)
                Text(part.name).font(.headline).lineLimit(2)
                Spacer()
            }
            if let by = part.addedBy {
                Text(by == "user" ? "部品表に無い板(追加した板)" : "部品表に無い板(AIが図から見つけて追加)")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
            }

            if !built.outline.isEmpty {
                PartPreview(built: built)
                    .frame(height: 230)
                    .onTapGesture(perform: onZoom)
                HStack {
                    PreviewLegend(showCheck: !built.checkMarks.isEmpty)
                    Spacer()
                    Button(action: onZoom) { Label("拡大", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .font(.caption)
                }
                // v2.9: データのすぐ下に「図面と見比べる」
                Button(action: onCompare) {
                    Label("図面と見比べる", systemImage: "rectangle.split.2x1")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("形を読み取れませんでした").font(.headline).foregroundStyle(.red)
                    if let e = part.readError { Text(e).font(.caption).foregroundStyle(.red.opacity(0.8)).lineLimit(4) }
                    else {
                        ForEach(built.blocking, id: \.self) { Text("・" + $0).font(.caption).foregroundStyle(.red.opacity(0.8)) }
                    }
                    Text("「指示して読み直す」を押してください").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("材質").foregroundStyle(.secondary)
                    Text(part.material.isEmpty ? "未確定" : part.material)
                }
                GridRow {
                    Text("板厚").foregroundStyle(.secondary)
                    if let t = part.thickness {
                        Text("t\(Fmt.num(t))" + (part.thicknessSource == "inferred" ? "(推定)" : ""))
                            .foregroundStyle(part.thicknessSource == "inferred" ? Color.yellow : Color.primary)
                    } else {
                        Text("未確定(入力してください)").foregroundStyle(.yellow)
                    }
                }
                GridRow {
                    Text("数量").foregroundStyle(.secondary)
                    Text("\(part.quantity)枚" + (part.mirrorPair ? " + 勝手違い\(part.quantity)枚" : ""))
                }
                if !built.outline.isEmpty {
                    GridRow {
                        Text("展開寸法").foregroundStyle(.secondary)
                        Text("\(Fmt.num(built.width)) × \(Fmt.num(built.height)) mm")
                    }
                    GridRow {
                        Text("穴").foregroundStyle(.secondary)
                        Text(built.holeLabels.isEmpty ? "なし" : "\(built.holeLabels.count)個(" + built.holeLabels.map(\.text).uniqued().joined(separator: "、") + ")")
                    }
                }
            }
            .font(.subheadline)

            // v3.0: 推定した所(図のオレンジの丸・穴)
            if !built.checkMarks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("要確認(図のオレンジの所は推定です。違っていれば「数値を直す」で直してください)")
                        .font(.caption.bold()).foregroundStyle(.orange)
                    ForEach(built.checkMarks.map(\.note).uniqued(), id: \.self) { Text("・" + $0).font(.caption) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 1))
            }

            let checks = built.blocking + built.warnings
            if !checks.isEmpty && !built.outline.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("確かめてほしいこと").font(.caption.bold()).foregroundStyle(.yellow)
                    ForEach(checks, id: \.self) { Text("・" + $0).font(.caption) }
                }
            }

            HStack(spacing: 10) {
                Button(action: onEdit) {
                    Label("数値を直す", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                Button(action: onReread) {
                    Label("指示して読み直す", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11)))
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
