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
    /// v4.0: できたDXFファイルそのものを開いて見る
    @State private var viewingDXF: DXFFileRef?

    var body: some View {
        List {
            Section {
                StepHeader(number: 3, title: "DXFファイル")
                if made {
                    Text(files.isEmpty ? "作れたファイルはありません" : "\(files.count)個のファイルができました。形を確かめてから送ってください。")
                        .font(.subheadline)
                }
            }
            // v4.0: 確認済みにしていない部品があれば知らせる(DXFは作るが、送る前に見比べてもらう)
            if let d = store.drawings.first(where: { $0.id == drawingID }) {
                let notYet = d.parts.filter { $0.process == .laser && $0.include && !$0.isConfirmed }
                if !notYet.isEmpty {
                    Section {
                        ForEach(notYet) { p in
                            Text("・\(p.partKey) \(p.name)").font(.footnote)
                        }
                    } header: {
                        Text("確認済みになっていない部品があります").foregroundStyle(.orange)
                    } footer: {
                        Text("前の画面で「図面と見比べる」をしてから「確認済み」を押してください。確かめていないデータを機械に流さないための注意です。")
                    }
                }
            }
            if made && !files.isEmpty {
                // v3.5: 「ファイル」アプリに自動で保存した場所
                Section {
                    HStack {
                        Text("会社名").foregroundStyle(.secondary)
                        TextField("例: 日新電子工業", text: companyBinding)
                    }
                    // v4.0: 会社名が空のときは、未確定のフォルダに入ることを知らせる
                    if companyBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("会社名が入っていないため「会社名未確定」のフォルダに保存しました。会社名を入れて「この会社名で保存し直す」を押してください")
                            .font(.footnote).foregroundStyle(.orange)
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
                                // v4.0: DXFファイルそのものを読み込んで表示する
                                Button {
                                    viewingDXF = DXFFileRef(url: f.url)
                                } label: {
                                    Label("DXFを見る", systemImage: "doc.viewfinder").font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
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
                    .foregroundStyle(Theme.red)
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
                // v4.0: これまでに保存したDXFを一覧から開いて見る
                NavigationLink("保存したDXFを見る") { SavedDXFListView() }
                NavigationLink("会社のパソコンへの送り方") { TransferGuideView() }
            }
        }
        .smScreen() // v3.9: アマダの赤の背景
        .navigationTitle("DXFファイル")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: make)
        .sheet(isPresented: $showShare) { ShareSheet(items: files.map(\.url)) }
        .sheet(item: $viewingDXF) { r in DXFFileView(url: r.url) }
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


// MARK: - v4.0 DXFファイルを見る
//
// 保存したDXFファイルそのものを読み込んで描く(アプリの中の形ではなく、会社のパソコンに送られるファイルの中身)。
// 読めるのは LINE / ARC / CIRCLE(このアプリが書き出す形)。

struct DXFFileRef: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
}

enum DXFReader {
    struct Loaded {
        var built = BuiltPart()
        var lines = 0
        var arcs = 0
        var circles = 0
    }

    static func load(_ url: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return nil }
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        // グループコードと値の組
        var pairs: [(Int, String)] = []
        var i = 0
        while i + 1 < raw.count {
            if let c = Int(raw[i].trimmingCharacters(in: .whitespaces)) {
                pairs.append((c, raw[i + 1].trimmingCharacters(in: .whitespaces)))
            }
            i += 2
        }

        var out = Loaded()
        var segs: [(Seg, String)] = []
        var inEntities = false
        var cur: String? = nil
        var v: [Int: String] = [:]
        func num(_ c: Int) -> Double { Double(v[c] ?? "") ?? 0 }
        func flush() {
            guard let t = cur else { return }
            let layer = v[8] ?? "0"
            switch t {
            case "LINE":
                segs.append((.line(P2(x: num(10), y: num(20)), P2(x: num(11), y: num(21))), layer)); out.lines += 1
            case "ARC":
                segs.append((.arc(center: P2(x: num(10), y: num(20)), r: num(40), startDeg: num(50), endDeg: num(51)), layer)); out.arcs += 1
            case "CIRCLE":
                segs.append((.circle(center: P2(x: num(10), y: num(20)), r: num(40)), layer)); out.circles += 1
            default:
                break
            }
        }
        for (c, s) in pairs {
            if c == 0 {
                if inEntities { flush() }
                cur = nil
                v = [:]
                if s == "ENDSEC" { inEntities = false }
                else if inEntities { cur = s }
                continue
            }
            if !inEntities && c == 2 && s == "ENTITIES" { inEntities = true; continue }
            if inEntities && cur != nil { v[c] = s }
        }
        guard !segs.isEmpty else { return nil }

        // 全体の範囲(円弧のふくらみも含める)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        func norm(_ d: Double) -> Double { var x = d.truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x }
        for (sg, _) in segs {
            switch sg {
            case .line(let a, let b):
                add(a.x, a.y); add(b.x, b.y)
            case .circle(let c, let r):
                add(c.x - r, c.y - r); add(c.x + r, c.y + r)
            case .arc(let c, let r, let s0, let e0):
                let span = norm(e0 - s0)
                for a in [s0, e0] { add(c.x + r * cos(a * .pi / 180), c.y + r * sin(a * .pi / 180)) }
                for q in [0.0, 90, 180, 270] where norm(q - s0) <= span {
                    add(c.x + r * cos(q * .pi / 180), c.y + r * sin(q * .pi / 180))
                }
            }
        }
        // 左下を (0,0) にそろえて描く
        func sh(_ p: P2) -> P2 { P2(x: p.x - minX, y: p.y - minY) }
        for (sg, layer) in segs {
            let bend = layer.uppercased() == "BEND"
            switch sg {
            case .line(let a, let b):
                let n = Seg.line(sh(a), sh(b))
                if bend { out.built.bendLines.append(n) } else { out.built.outline.append(n) }
            case .arc(let c, let r, let s0, let e0):
                let n = Seg.arc(center: sh(c), r: r, startDeg: s0, endDeg: e0)
                if bend { out.built.bendLines.append(n) } else { out.built.outline.append(n) }
            case .circle(let c, let r):
                let p = sh(c)
                out.built.holes.append(.circle(center: p, r: r))
                out.built.holeLabels.append(HoleLabel(pos: p, text: "φ" + Fmt.num((r * 2 * 100).rounded() / 100),
                                                      position: "(\(Fmt.num((p.x * 10).rounded() / 10)), \(Fmt.num((p.y * 10).rounded() / 10)))",
                                                      boxW: r * 2, boxH: r * 2))
            }
        }
        out.built.width = maxX - minX
        out.built.height = maxY - minY
        return out
    }
}

/// 1つのDXFファイルを開いて見る
struct DXFFileView: View {
    let url: URL
    private let loaded: DXFReader.Loaded?
    @Environment(\.dismiss) private var dismiss
    @State private var showFull = false
    @State private var showShare = false

    init(url: URL) {
        self.url = url
        self.loaded = DXFReader.load(url)
    }

    var body: some View {
        NavigationStack {
            List {
                if let l = loaded {
                    Section {
                        PartPreview(built: l.built, showLabels: true)
                            .frame(height: 300)
                            .contentShape(Rectangle())
                            .onTapGesture { showFull = true }
                        Text("大きさ \(Fmt.num(l.built.width)) × \(Fmt.num(l.built.height)) mm").font(.subheadline.bold())
                        Text("線 \(l.lines)本・円弧 \(l.arcs)個・円 \(l.circles)個").font(.footnote)
                    } footer: {
                        Text("DXFファイルそのものを読み込んで描いています(会社のパソコンに送るファイルと同じ中身)。図をタップすると拡大できます。")
                    }
                    if !l.built.holeLabels.isEmpty {
                        Section("円(丸穴)の位置(左下が0,0)") {
                            ForEach(Array(l.built.holeLabels.enumerated()), id: \.offset) { p in
                                HStack {
                                    Text(p.element.text).bold()
                                    Spacer()
                                    Text(p.element.position).monospacedDigit()
                                }
                                .font(.footnote)
                            }
                        }
                    }
                    Section {
                        Button { showShare = true } label: {
                            Label("このファイルを送る・保存する", systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Text("このDXFファイルを読み込めませんでした").foregroundStyle(.red)
                }
            }
            .smScreen()
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
            }
            .sheet(isPresented: $showFull) {
                if let l = loaded { FullPreviewView(title: url.lastPathComponent, built: l.built) }
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
        }
    }
}

/// 「ファイル」アプリに保存したDXF(DXF → 会社 → 素材 → 板厚)の一覧
struct SavedDXFListView: View {
    struct FileItem: Identifiable {
        let url: URL
        let date: Date
        var id: String { url.path }
    }
    struct Folder: Identifiable {
        let name: String
        var files: [FileItem]
        var id: String { name }
    }
    @State private var folders: [Folder] = []
    @State private var viewing: DXFFileRef?

    var body: some View {
        List {
            if folders.isEmpty {
                Text("保存したDXFはまだありません。「③ DXFファイル」を開くと、ここに保存されます。")
                    .font(.footnote)
            }
            ForEach(folders) { f in
                Section(f.name) {
                    ForEach(f.files) { item in
                        Button {
                            viewing = DXFFileRef(url: item.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.lastPathComponent).font(.footnote.monospaced()).lineLimit(2)
                                Text(Self.dateText(item.date)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .smScreen()
        .navigationTitle("保存したDXF")
        .onAppear(perform: reload)
        .refreshable { reload() }
        .sheet(item: $viewing) { r in DXFFileView(url: r.url) }
    }

    private func reload() {
        let root = Exporter.dxfRoot
        let fm = FileManager.default
        var dict: [String: [FileItem]] = [:]
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            for case let u as URL in en where u.pathExtension.lowercased() == "dxf" {
                let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let dir = u.deletingLastPathComponent().standardizedFileURL.path
                let base = root.standardizedFileURL.path
                var rel = dir.hasPrefix(base) ? String(dir.dropFirst(base.count)) : dir
                if rel.hasPrefix("/") { rel.removeFirst() }
                let key = rel.isEmpty ? "DXF" : rel.replacingOccurrences(of: "/", with: " / ")
                dict[key, default: []].append(FileItem(url: u, date: date))
            }
        }
        folders = dict.keys.sorted().map { k in
            Folder(name: k, files: (dict[k] ?? []).sorted { $0.date > $1.date })
        }
    }

    private static func dateText(_ d: Date) -> String {
        guard d != Date.distantPast else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: d)
    }
}


// MARK: - v4.0 材質・板厚ごとにまとめて出す
//
// 何枚かの図面の部品を、同じ材質・板厚ごとに集めて、1回でDXFを作って送る(割付はアマダ側でまとめて行う)。
// 図面ごとに作るのとは別に、ここから材質・板厚の単位で送れる。

/// 材質・板厚ごとの一覧
struct BatchExportView: View {
    @Environment(AppStore.self) private var store
    @State private var includeProcessed = false

    var body: some View {
        let targets = store.drawings.filter { $0.reviewPending != true && (includeProcessed || $0.processed != true) }
        let groups = Exporter.groups(targets)
            .map { g in Exporter.ExportGroup(key: g.key, items: g.items.filter { $0.part.include }) }
            .filter { !$0.items.isEmpty }
        List {
            Section {
                Toggle("加工済みの図面も含める", isOn: $includeProcessed)
            } footer: {
                Text("同じ材質・板厚の部品を、図面をまたいでまとめます。押すと、その材質・板厚の部品の一覧とDXFの作成に進みます。")
            }
            if groups.isEmpty {
                Text("まとめられる部品がありません(展開まで済んだ図面の、レーザーの部品が対象です)。").font(.footnote)
            }
            ForEach(groups) { g in
                NavigationLink {
                    BatchGroupView(key: g.key, includeProcessed: includeProcessed)
                } label: {
                    BatchGroupRow(group: g)
                }
            }
        }
        .smScreen()
        .navigationTitle("材質・板厚ごと")
    }
}

/// 一覧の1行(材質・板厚、部品の種類・合計枚数・図面の数)
struct BatchGroupRow: View {
    let group: Exporter.ExportGroup

    var body: some View {
        let drawings = Set(group.items.map { $0.drawing.id }).count
        let notYet = group.items.filter { !$0.part.isConfirmed }.count
        VStack(alignment: .leading, spacing: 3) {
            Text(group.key).font(.title3.bold())
            Text("部品\(group.items.count)種・合計\(Exporter.sheetCount(group.items))枚・図面\(drawings)枚")
                .font(.subheadline)
            if notYet > 0 {
                Text("確認済みでない部品 \(notYet)種").font(.caption.bold()).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 1つの材質・板厚の部品を選んで、まとめてDXFを作って送る
struct BatchGroupView: View {
    @Environment(AppStore.self) private var store
    let key: String
    let includeProcessed: Bool
    /// 外した部品(初めは全部選んだ状態)
    @State private var unselected: Set<UUID> = []
    @State private var files: [Exporter.ExportedFile] = []
    @State private var skipped: [String] = []
    @State private var showShare = false
    @State private var made = false

    private var items: [Exporter.Item] {
        let targets = store.drawings.filter { $0.reviewPending != true && (includeProcessed || $0.processed != true) }
        return Exporter.groups(targets).first(where: { $0.key == key })?.items.filter { $0.part.include } ?? []
    }

    var body: some View {
        let all = items
        let chosen = all.filter { !unselected.contains($0.id) }
        let notYet = chosen.filter { !$0.part.isConfirmed }.count
        List {
            Section {
                Text(key).font(.title3.bold())
                Text("選んだ部品 \(chosen.count)種・合計\(Exporter.sheetCount(chosen))枚(勝手違いを含む)")
                    .font(.subheadline.bold())
                if notYet > 0 {
                    Text("確認済みでない部品が\(notYet)種あります(オレンジ)。図面と見比べてから送ってください。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("部品(タップで選ぶ・外す)") {
                ForEach(all) { it in
                    Button {
                        if unselected.contains(it.id) { unselected.remove(it.id) } else { unselected.insert(it.id) }
                        made = false
                    } label: {
                        BatchItemRow(item: it, on: !unselected.contains(it.id), settings: store.settings)
                    }
                }
            }
            Section {
                Button {
                    let r = Exporter.exportFiles(items: chosen, settings: store.settings)
                    files = r.files
                    skipped = r.skipped
                    made = true
                    if !files.isEmpty { showShare = true }
                } label: {
                    HStack {
                        Spacer()
                        Label("選んだ部品のDXFを作って送る", systemImage: "square.and.arrow.up").font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.red)
                .disabled(chosen.isEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("DXFは「ファイル」アプリの DXF → 会社 → 素材 → 板厚 のフォルダにも保存されます。")
            }
            if made {
                Section("できたファイル") {
                    Text("\(files.count)個のファイルを作りました").font(.footnote)
                    ForEach(skipped, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                    if !files.isEmpty {
                        Button("もう一度送る・保存する") { showShare = true }
                        Button("この部品の図面を、まとめて加工済みにする") { markProcessed(chosen) }
                    }
                }
            }
        }
        .smScreen()
        .navigationTitle("まとめて出す")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) { ShareSheet(items: files.map(\.url)) }
    }

    private func markProcessed(_ chosen: [Exporter.Item]) {
        let ids = Set(chosen.map { $0.drawing.id })
        for i in store.drawings.indices where ids.contains(store.drawings[i].id) {
            store.drawings[i].processed = true
            store.drawings[i].processedAt = Date()
        }
        store.save()
    }
}

/// まとめて出す画面の部品の1行
struct BatchItemRow: View {
    let item: Exporter.Item
    let on: Bool
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
            PartPreview(built: Geometry.build(part: item.part, settings: settings), showLabels: false)
                .frame(width: 70, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.part.partKey) \(item.part.name)").font(.subheadline.bold()).lineLimit(2)
                Text(item.drawing.drawingNumber + (item.drawing.company.map { "・" + $0 } ?? ""))
                    .font(.caption).lineLimit(1)
                Text("\(item.part.sheetCount)枚" + (item.part.mirrorPair ? "(勝手違い含む)" : ""))
                    .font(.caption)
                if !item.part.isConfirmed {
                    Text("確認済みでない").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }
}
