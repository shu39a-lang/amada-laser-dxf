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
    /// v3.6
    @State private var makingShape = false
    @State private var deleting: PartRef?

    private var drawing: DrawingRecord? { store.drawings.first { $0.id == drawingID } }

    var body: some View {
        if drawing?.reviewPending == true {
            // v3.6: 展開を読む前に、部品の分け方を確かめる
            InventoryReviewView(drawingID: drawingID)
        } else if let d = drawing {
            let laser = d.parts.filter { $0.process == .laser }
            let others = d.parts.filter { $0.process != .laser }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StepHeader(number: 2, title: "形を確かめる")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title.isEmpty ? "(品名なし)" : d.title).font(.title3.bold())
                        Text("図番 \(d.drawingNumber)" + (d.productNumber.isEmpty ? "" : "  製番 \(d.productNumber)"))
                            .font(.footnote).foregroundStyle(.white.opacity(0.8))
                        Text(laser.count <= 1 ? "この図面の板は1種類です" : "この図面には\(laser.count)種類の板があります(部品1〜\(laser.count))")
                            .font(.subheadline.bold()).foregroundStyle(.white).padding(.top, 4)
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
                                 onCompare: { comparing = PartRef(id: pair.element.id) },
                                 onDelete: { deleting = PartRef(id: pair.element.id) })
                    }

                    // v3.6: 読み取りが実物と大きく違うとき、形と寸法から部品を作る
                    Button {
                        makingShape = true
                    } label: {
                        Label("形から部品を作る", systemImage: "square.on.square.dashed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Text("L字・コの字・門形などの形を選んで外寸を入れると、曲げ控除表で展開した部品ができます(AIは使いません)。")
                        .font(.caption).foregroundStyle(.secondary)

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
                    // v3.6: 部品の分け方からやり直す(読み済みの部品の展開は残る)
                    Button {
                        backToReview()
                    } label: {
                        Label("部品の分け方に戻る(まとめる・複製・読み直し)", systemImage: "list.bullet.rectangle")
                    }
                    .padding(.bottom, 90)
                }
                .padding()
            }
            .smScreen() // v3.9: アマダの赤の背景
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
                .foregroundStyle(Theme.red)
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
            .sheet(isPresented: $makingShape) {
                ShapePartSheet(drawingID: drawingID)
            }
            .alert("この部品を削除しますか?",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("削除", role: .destructive) {
                    if let r = deleting { PartOps.remove(store, drawingID: drawingID, partID: r.id) }
                    deleting = nil
                }
                Button("やめる", role: .cancel) { deleting = nil }
            } message: {
                Text("DXFにも出なくなります。間違えて消したときは「形から部品を作る」か「板を追加して読む」で作り直せます。")
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

    /// v3.6: 「部品を確かめる」画面に戻す
    private func backToReview() {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }) else { return }
        store.drawings[di].reviewPending = true
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
    /// v3.6
    var onDelete: () -> Void = {}

    var body: some View {
        let built = Geometry.build(part: part, settings: settings)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("部品\(number)").font(.title2.bold()).foregroundStyle(Theme.redText)
                Text(part.name).font(.headline).lineLimit(2)
                Spacer()
                // v3.6: いらない部品を消す
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .accessibilityLabel("この部品を削除")
            }
            if let k = part.shapeKind, let sk = ShapeKind(rawValue: k) {
                Text("形から作った部品(\(sk.label))")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan))
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
                .foregroundStyle(Theme.red)
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

// MARK: - v3.6 部品の削除・複製・まとめる

enum PartOps {
    /// 図面の中でまだ使っていない部品キー(P1, P2 …)
    static func newKey(_ rec: DrawingRecord) -> String {
        let used = Set(rec.parts.map(\.partKey))
        var n = rec.parts.count + 1
        while used.contains("P\(n)") { n += 1 }
        return "P\(n)"
    }

    /// 部品を消す(前板+側壁から分けた帯板があれば一緒に消す)
    static func remove(_ store: AppStore, drawingID: UUID, partID: UUID) {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
              let p = store.drawings[di].parts.first(where: { $0.id == partID }) else { return }
        let stripPrefix = p.partKey + "-W"
        store.drawings[di].parts.removeAll { $0.id == partID || $0.partKey.hasPrefix(stripPrefix) }
        store.save()
    }

    /// 同じ部品をもう1つ作る(1つの部品を2つに分けたいとき。名前・指示は作業者が直す)
    static func duplicate(_ store: AppStore, drawingID: UUID, partID: UUID) {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
              let pi = store.drawings[di].parts.firstIndex(where: { $0.id == partID }) else { return }
        var c = store.drawings[di].parts[pi]
        c.id = UUID()
        c.partKey = newKey(store.drawings[di])
        c.name = c.name + "(複製)"
        c.manualAlign = nil
        c.addedBy = "user"
        store.drawings[di].parts.insert(c, at: pi + 1)
        store.save()
    }

    /// 選んだ部品を1枚の板にまとめる(例: 側板・天板・側板 → コの字の1枚)。展開は読み直す
    static func merge(_ store: AppStore, drawingID: UUID, partIDs: [UUID], name: String, hint: String) {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }) else { return }
        let rec = store.drawings[di]
        let picked = rec.parts.filter { partIDs.contains($0.id) }
        guard picked.count >= 2, let first = picked.first,
              let at = rec.parts.firstIndex(where: { $0.id == first.id }) else { return }
        var m = Part()
        m.partKey = newKey(rec)
        m.name = name.isEmpty ? picked.map(\.name).joined(separator: "+") : name
        m.material = first.material
        m.thickness = first.thickness
        m.thicknessSource = first.thicknessSource
        m.thicknessEvidence = first.thicknessEvidence
        m.process = .laser
        m.include = true
        m.quantity = first.quantity
        m.mirrorPair = picked.contains { $0.mirrorPair }
        m.bendsCount = max(picked.count - 1, picked.map(\.bendsCount).reduce(0, +))
        m.viewsDescription = picked.map { "\($0.name): \($0.viewsDescription)" }.joined(separator: " / ")
        m.addedBy = "user"
        m.userHint = hint
        store.drawings[di].parts.removeAll { partIDs.contains($0.id) }
        store.drawings[di].parts.insert(m, at: min(at, store.drawings[di].parts.count))
        store.save()
    }
}

// MARK: - v3.6 ② 部品を確かめる(展開を読む前)

/// 洗い出した部品の一覧を、展開を読む前に作業者が直す画面。
///  削除・複製・まとめる・形から作る・板厚と数量の変更ができ、「この部品で展開を読む」で段階Bへ進む
struct InventoryReviewView: View {
    @Environment(AppStore.self) private var store
    let drawingID: UUID
    @State private var selected: Set<UUID> = []
    @State private var running = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var makingShape = false
    @State private var showMerge = false
    @State private var mergeName = ""
    @State private var mergeHint = ""
    @State private var showReinventory = false
    @State private var reHints = ""
    @State private var showOriginal = false
    @State private var deleting: PartRef?

    private var drawing: DrawingRecord? { store.drawings.first { $0.id == drawingID } }

    /// 部品1つ分の Binding(削除しても落ちないように、毎回IDで探す)
    private func binding(_ id: UUID) -> Binding<Part> {
        Binding(
            get: { store.drawings.first { $0.id == drawingID }?.parts.first { $0.id == id } ?? Part() },
            set: { nv in
                if let a = store.drawings.firstIndex(where: { $0.id == drawingID }),
                   let b = store.drawings[a].parts.firstIndex(where: { $0.id == id }) {
                    store.drawings[a].parts[b] = nv
                    store.save()
                }
            }
        )
    }

    var body: some View {
        if let d = drawing {
            let laser = d.parts.filter { $0.process == .laser }
            let others = d.parts.filter { $0.process != .laser }
            Form {
                Section {
                    StepHeader(number: 2, title: "部品を確かめる")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title.isEmpty ? "(品名なし)" : d.title).font(.headline)
                        Text("図番 \(d.drawingNumber)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("展開を読む前に、部品の分け方を確かめてください。いらない部品は削除、足りない部品は「形から部品を作る」、1枚の板を曲げて作る部品は2つ以上選んで「まとめる」を押します。")
                        .font(.footnote)
                }

                if let h = d.hints, !h.isEmpty {
                    Section("入れた前提") { Text(h).font(.footnote) }
                }
                if !d.questions.isEmpty {
                    Section {
                        ForEach(d.questions, id: \.self) { Text("・" + $0).font(.footnote) }
                    } header: {
                        Text("AIからの確認").foregroundStyle(.orange)
                    }
                }
                if !d.analysis.isEmpty {
                    Section {
                        DisclosureGroup("AIが考えた部品の分け方") {
                            Text(d.analysis).font(.caption)
                        }
                    }
                }

                Section {
                    if laser.isEmpty {
                        Text("板の部品がありません。「形から部品を作る」で足すか、「部品一覧を読み直す」を押してください。")
                            .foregroundStyle(.red).font(.footnote)
                    }
                    ForEach(Array(laser.enumerated()), id: \.element.id) { pair in
                        ReviewPartRow(number: pair.offset + 1,
                                      part: binding(pair.element.id),
                                      selected: selected.contains(pair.element.id),
                                      settings: store.settings,
                                      onSelect: { toggle(pair.element.id) },
                                      onDuplicate: { PartOps.duplicate(store, drawingID: drawingID, partID: pair.element.id) },
                                      onExclude: { setProcess(pair.element.id, .other) },
                                      onDelete: { deleting = PartRef(id: pair.element.id) })
                    }
                } header: {
                    Text("板(レーザー)\(laser.count)種類")
                } footer: {
                    Text("左の丸をタップすると選べます。2つ以上選ぶと「まとめる」が使えます。")
                }

                Section {
                    Button {
                        mergeName = laser.filter { selected.contains($0.id) }.map(\.name).joined(separator: "+")
                        mergeHint = "「" + laser.filter { selected.contains($0.id) }.map(\.name).joined(separator: "」「")
                            + "」は1枚の板を曲げて作る(例: コの字に曲げて3面を覆う)。1枚の展開にしてください。"
                        showMerge = true
                    } label: {
                        Label("選んだ\(selected.count)つを1枚にまとめる", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(selected.count < 2 || running)
                    Button {
                        makingShape = true
                    } label: {
                        Label("形から部品を作る(L字・コの字・門形など)", systemImage: "square.on.square.dashed")
                    }
                    .disabled(running)
                    Button {
                        reHints = d.hints ?? ""
                        showReinventory = true
                    } label: {
                        Label("前提を足して部品一覧を読み直す", systemImage: "arrow.clockwise")
                    }
                    .disabled(running)
                    Button {
                        showOriginal = true
                    } label: {
                        Label("元の図面を見る", systemImage: "doc.text.image")
                    }
                }

                if !others.isEmpty {
                    Section {
                        ForEach(others) { p in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name).font(.footnote)
                                    Text(p.process.label).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("板にする") { setProcess(p.id, .laser) }
                                    .font(.caption).buttonStyle(.bordered)
                                Button(role: .destructive) {
                                    PartOps.remove(store, drawingID: drawingID, partID: p.id)
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("レーザー対象外(データは作りません)")
                    }
                }

                if let e = errorText {
                    Section { Text(e).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Color.clear.frame(height: 60)
                }
                .listRowBackground(Color.clear)
            }
            .smScreen() // v3.9: アマダの赤の背景
            .navigationTitle("部品を確かめる")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard !running else { return }
                    Task { await readFlats() }
                } label: {
                    HStack {
                        Spacer()
                        if running { SpinningGear(size: 22) }
                        Text(running ? (progressText.isEmpty ? "展開を読み取り中…" : progressText) : "この部品で展開を読む")
                            .font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.6)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.red)
                .disabled(laser.isEmpty && !running)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.ultraThinMaterial)
            }
            .sheet(isPresented: $makingShape) {
                ShapePartSheet(drawingID: drawingID)
            }
            .sheet(isPresented: $showMerge) {
                NavigationStack {
                    Form {
                        Section("まとめた板の名前") {
                            TextField("名前", text: $mergeName)
                        }
                        Section {
                            TextField("どう曲げて作るか", text: $mergeHint, axis: .vertical).lineLimit(3...8)
                        } header: {
                            Text("AIへの指示")
                        } footer: {
                            Text("例: 「側板・天板・側板を1枚の細長い板でコの字に曲げる」。材質・板厚・数量は最初に選んだ部品と同じになります(あとで直せます)。")
                        }
                    }
                    .smScreen() // v3.9: アマダの赤の背景
                    .navigationTitle("1枚にまとめる")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("やめる") { showMerge = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("まとめる") {
                                PartOps.merge(store, drawingID: drawingID, partIDs: Array(selected), name: mergeName, hint: mergeHint)
                                selected = []
                                showMerge = false
                            }.bold()
                        }
                    }
                }
            }
            .sheet(isPresented: $showReinventory) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("例: 部品は8種類。板厚違いは1種類。大きい板をコの字に曲げて3面を覆う", text: $reHints, axis: .vertical)
                                .lineLimit(3...8)
                        } header: {
                            Text("前提")
                        } footer: {
                            Text("部品一覧をAIに読み直させます。今の一覧(直した所も)は置き換わります。「形から作った部品」は残ります。")
                        }
                    }
                    .smScreen() // v3.9: アマダの赤の背景
                    .navigationTitle("部品一覧を読み直す")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("やめる") { showReinventory = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("読み直す") {
                                showReinventory = false
                                Task { await reInventory() }
                            }.bold()
                        }
                    }
                }
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
                }
            }
            .alert("この部品を削除しますか?",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("削除", role: .destructive) {
                    if let r = deleting {
                        selected.remove(r.id)
                        PartOps.remove(store, drawingID: drawingID, partID: r.id)
                    }
                    deleting = nil
                }
                Button("やめる", role: .cancel) { deleting = nil }
            }
        } else {
            Text("図面が見つかりません")
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func setProcess(_ id: UUID, _ p: PartProcess) {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
              let pi = store.drawings[di].parts.firstIndex(where: { $0.id == id }) else { return }
        store.drawings[di].parts[pi].process = p
        store.drawings[di].parts[pi].include = p == .laser
        selected.remove(id)
        store.save()
    }

    /// 段階B: 展開がまだ無い部品だけ読む
    @MainActor private func readFlats() async {
        guard let d = drawing else { return }
        errorText = nil
        running = true
        let keep = KeepAwake()
        keep.begin()
        defer { running = false; keep.end() }
        let imgs = d.imageFiles.compactMap { store.loadImage($0) }
        let needsAI = d.parts.contains { $0.process == .laser && $0.shapeKind == nil && $0.flat == nil }
        if needsAI && imgs.isEmpty { errorText = "元の写真がありません"; return }
        let reader = DrawingReader(apiKey: store.apiKey, settings: store.settings)
        do {
            let result = try await reader.readFlats(record: d, images: imgs) { text in progressText = text }
            store.upsert(result)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 前提を足して段階Aをやり直す(形から作った部品は残す)
    @MainActor private func reInventory() async {
        guard let d = drawing else { return }
        errorText = nil
        running = true
        let keep = KeepAwake()
        keep.begin()
        defer { running = false; keep.end() }
        let imgs = d.imageFiles.compactMap { store.loadImage($0) }
        guard !imgs.isEmpty else { errorText = "元の写真がありません"; return }
        let reader = DrawingReader(apiKey: store.apiKey, settings: store.settings)
        do {
            var result = try await reader.readInventory(images: imgs, into: d, hints: reHints) { text in progressText = text }
            let kept = d.parts.filter { $0.shapeKind != nil }
            for var k in kept {
                if result.parts.contains(where: { $0.partKey == k.partKey }) { k.partKey = PartOps.newKey(result) }
                result.parts.append(k)
            }
            selected = []
            store.upsert(result)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 「部品を確かめる」の1行(部品1つ分)
struct ReviewPartRow: View {
    let number: Int
    @Binding var part: Part
    let selected: Bool
    let settings: AppSettings
    var onSelect: () -> Void
    var onDuplicate: () -> Void
    var onExclude: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(selected ? "選択を外す" : "選ぶ")
                Text("部品\(number)").font(.headline).foregroundStyle(Theme.redText)
                TextField("名前", text: $part.name).font(.headline)
            }
            if let k = part.shapeKind, let sk = ShapeKind(rawValue: k) {
                Text("形から作成済み(\(sk.label))・展開は読みません")
                    .font(.caption.bold()).foregroundStyle(.cyan)
                let built = Geometry.build(part: part, settings: settings)
                if !built.outline.isEmpty {
                    PartPreview(built: built, showLabels: false)
                        .frame(height: 120)
                }
            } else if part.flat != nil {
                Text("展開は読み取り済み").font(.caption.bold()).foregroundStyle(.green)
            }
            if let by = part.addedBy {
                Text(by == "user" ? "作業者が追加・まとめた部品" : "部品表に無い板(AIが追加)")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !part.viewsDescription.isEmpty {
                Text("描かれている所: " + part.viewsDescription)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                TextField("材質", text: $part.material)
                    .textFieldStyle(.roundedBorder)
                Text("t")
                ThicknessField(part: $part)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            .font(.subheadline)
            Stepper("数量 \(part.quantity)枚", value: $part.quantity, in: 1...999)
                .font(.subheadline)
            Toggle("勝手違い(左右反転)も作る", isOn: $part.mirrorPair)
                .font(.subheadline)
            if part.shapeKind == nil {
                TextField("この部品への指示(任意)例: 3面を1枚で覆うコの字", text: $part.userHint, axis: .vertical)
                    .font(.footnote)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button(action: onDuplicate) { Label("複製", systemImage: "plus.square.on.square") }
                Button(action: onExclude) { Label("対象外", systemImage: "nosign") }
                Spacer()
                Button(role: .destructive, action: onDelete) { Label("削除", systemImage: "trash") }
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
