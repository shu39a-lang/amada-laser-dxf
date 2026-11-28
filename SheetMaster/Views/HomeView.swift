import SwiftUI
import PhotosUI

/// ① 図面を入れる
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var picks: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var showCamera = false
    @State private var running = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var openID: UUID?
    @State private var showSettings = false
    /// v3.6: 読み取りの前提(わかれば)
    @State private var hints = ""
    /// v3.9: 使い方の画面
    @State private var showHelp = false
    /// v3.9: 今月読み取った写真の枚数(月が変わると0に戻る)
    @AppStorage("photoCountMonth") private var photoCountMonth = ""
    @AppStorage("photoCount") private var photoCount = 0
    @AppStorage("photoCountPrev") private var photoCountPrev = 0

    var body: some View {
        List {
            // v3.9: アプリ名の下のサブタイトル
            Section {
                Text("図面を、確かなデータに")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            }
            Section {
                StepHeader(number: 1, title: "図面を入れる")
                HStack(spacing: 12) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: {
                            Label("撮る", systemImage: "camera").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(images.count >= 4 || running)
                    }
                    PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .images) {
                        Label("写真を選ぶ", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(running)
                }
                if !images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(images.indices, id: \.self) { i in
                                Image(uiImage: images[i]).resizable().scaledToFit().frame(height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .topTrailing) {
                                        Button { images.remove(at: i) } label: {
                                            Image(systemName: "xmark.circle.fill").font(.title3)
                                                .foregroundStyle(.white, .red)
                                        }
                                        .disabled(running)
                                    }
                            }
                        }
                    }
                }
                Text("図面全体を真上から撮ってください。数字が小さい図面は、部分のアップ写真を足すと精度が上がります(最大4枚)。以前に抜いた実物の板の写真があれば一緒に入れると、板の分け方が正確になります。")
                    .font(.footnote).foregroundStyle(.secondary)
                // v3.9: 今月読み取った写真の枚数(1日〜月末。月が変わると0から数え直す)
                HStack {
                    Image(systemName: "photo.stack")
                    Text("今月(\(monthRangeText))の読み取り")
                    Spacer()
                    Text("\(photoCount)枚").font(.headline.monospacedDigit())
                }
                .font(.footnote)
                if photoCountPrev > 0 {
                    Text("先月: \(photoCountPrev)枚").font(.caption).foregroundStyle(.secondary)
                }
            }

            // v3.6: 図面の前提を先に伝える(部品の分け方の読み違いを減らす)
            Section {
                TextField("例: 部品は8種類。板厚が違うのは1種類(t3)だけ。大きい板をコの字に曲げて3面を覆う", text: $hints, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(running)
            } header: {
                Text("前提(わかれば・空でもOK)")
            } footer: {
                Text("部品の数・板厚の種類・どう曲げて作るかなど、わかっていることを書くと、その通りに部品を分けます。")
            }

            Section {
                Button {
                    guard !running else { return }
                    Task { await run() }
                } label: {
                    HStack {
                        Spacer()
                        if running { SpinningGear(size: 26) }
                        Text(running ? progressText : "読み取る").font(.title3.bold())
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.red)
                // v3.5: 読み取り中に無効にすると、ボタン全体が薄くなって歯車が止まって見えたので、無効にしない(二重押しは上で防ぐ)
                .disabled(images.isEmpty && !running)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if let e = errorText {
                    Text(e).foregroundStyle(.red).font(.footnote)
                }
            } footer: {
                if running { Text("まず部品を洗い出します(1〜2分)。次の画面で部品の分け方を確かめてから、展開を読みます。受信している文字数が増えていれば正常です。") }
            }

            if !store.drawings.isEmpty {
                Section("これまでの図面") {
                    ForEach(store.drawings) { d in
                        NavigationLink {
                            ResultView(drawingID: d.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.title.isEmpty ? "(品名なし)" : d.title).font(.headline)
                                Text("\(d.drawingNumber)  板 \(d.parts.filter { $0.process == .laser }.count)種類")
                                    .font(.caption).foregroundStyle(.secondary)
                                if d.reviewPending == true {
                                    Text("部品の確認中(展開はまだ)").font(.caption2.bold()).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        let targets = idx.map { store.drawings[$0] }
                        for d in targets { store.delete(d) }
                    }
                }
            }
        }
        .smScreen() // v3.9: アマダの赤の背景
        .navigationTitle("SHEET MASTER")
        .toolbar {
            // v3.9: 右上に「使い方」(使う段取り・注意点・送るときの注意)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "questionmark.circle")
                        Text("使い方").font(.subheadline.bold())
                    }
                }
                .accessibilityLabel("使い方")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("設定")
            }
        }
        .onAppear { rollPhotoMonth() }
        .onChange(of: picks) { _, newValue in
            Task {
                var out: [UIImage] = []
                for item in newValue {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { out.append(img) }
                }
                images = Array(out.prefix(4))
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in if let img { images.append(img) } }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack { HelpView() }
        }
        .navigationDestination(item: $openID) { id in
            ResultView(drawingID: id)
        }
    }

    // MARK: v3.9 今月の読み取り枚数

    private static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// 例: 「11月1日〜30日」
    private var monthRangeText: String {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now)
        let last = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        return "\(m)月1日〜\(last)日"
    }

    /// 月が変わっていたら、今月の枚数を0に戻す(先月の分は「先月」に残す)
    private func rollPhotoMonth() {
        let now = Date()
        let key = Self.monthKey(now)
        guard photoCountMonth != key else { return }
        let prevKey = Calendar.current.date(byAdding: .month, value: -1, to: now).map(Self.monthKey) ?? ""
        photoCountPrev = (photoCountMonth == prevKey) ? photoCount : 0
        photoCount = 0
        photoCountMonth = key
    }

    @MainActor private func run() async {
        errorText = nil
        running = true
        // v3.9: 「読み取る」を押した写真の枚数を今月の分に足す(読み取りに失敗しても数える)
        rollPhotoMonth()
        photoCount += images.count
        let keep = KeepAwake()
        keep.begin()
        defer { running = false; keep.end() }
        var rec = DrawingRecord()
        rec.imageFiles = images.compactMap { store.storeImage($0) }
        let reader = DrawingReader(apiKey: store.apiKey, settings: store.settings)
        do {
            // v3.6: ここでは部品の洗い出しまで。展開は「部品を確かめる」画面で確かめてから読む
            let result = try await reader.readInventory(images: images, into: rec, hints: hints) { text in progressText = text }
            store.upsert(result)
            images = []
            picks = []
            hints = ""
            openID = result.id
        } catch {
            errorText = error.localizedDescription
            for f in rec.imageFiles { try? FileManager.default.removeItem(at: store.imagesDir.appendingPathComponent(f)) }
        }
    }
}

struct StepHeader: View {
    let number: Int
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            // v3.9: 白い丸に赤い数字(アマダのロゴの色)
            Text("\(number)")
                .font(.headline).foregroundStyle(Theme.red)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white))
            Text(title).font(.title3.bold()).foregroundStyle(.white)
        }
    }
}

/// v3.5: 読み取り中の歯車。色付きで、常に回り続ける(時計で角度を決めるので、画面の更新に左右されない)
struct SpinningGear: View {
    var size: CGFloat = 24
    var color: Color = .red

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Image(systemName: "gearshape.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
                .rotationEffect(.degrees((t * 240).truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: size + 4, height: size + 4)
        .accessibilityLabel("読み取り中")
    }
}

// MARK: - v3.9 使い方(最初の画面の右上から開く)

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Topic: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let items: [String]
    }

    private let topics: [Topic] = [
        Topic(title: "はじめに(最初の1回だけ)", icon: "gearshape", items: [
            "右上の歯車 →「Claude APIキー」にキーを入れて「保存」を押す",
            "歯車 →「曲げ控除表」を、会社の曲げ控除表の数値に入れ替える(初期値は仮の値。入れ替えたら「仮マークをすべて外す」)",
            "歯車 →「タップ下穴表」で下穴の径を確かめる(例: M3 → φ2.5)",
        ]),
        Topic(title: "使う段取り", icon: "list.number", items: [
            "① 図面を入れる:「撮る」か「写真を選ぶ」(最大4枚)。図面全体を真上から、影や光の反射が入らないように撮る。数字が小さい所はアップの写真を足す",
            "以前に同じ品物を作ったことがあれば、抜いた実物の板の写真も一緒に入れる(向き・角度はそのままでよい)。AIが板の分け方と形を実物に合わせる",
            "図面に手書きした曲げの寸法(「260/141.4/170 L=570.6」など)や控除(「−0.8」)は、AIがそのまま使う。わかっている所は書き込んでから撮ると正確になる",
            "「前提」欄に、部品の数・板厚の種類・どう曲げて作るかなど、わかっていることを書く(空でもよい)",
            "「読み取る」を押す。まず部品を洗い出す(1〜2分)",
            "② 部品を確かめる: いらない部品は削除、足りない部品は「形から部品を作る」、1枚の板を曲げて作る部品は2つ以上選んで「1枚にまとめる」。説明の【作り方】(曲げ・溶接)も確かめる",
            "「この部品で展開を読む」を押す",
            "② 形を確かめる: 部品ごとに形と穴の位置を見る。「図面と見比べる」で写真と並べて確かめる。違っていれば「数値を直す」か「指示して読み直す」",
            "③「DXFファイルを作る」: この画面を開いた時点で、iPhoneに自動で保存される(「ファイル」アプリ → このiPhone内 → SHEET MASTER → DXF → 会社 → 素材 → 板厚)。フォルダ名をタップするとそのフォルダが開く",
        ]),
        Topic(title: "注意点", icon: "exclamationmark.triangle", items: [
            "AIの読み取りには推定が入る。黄色・オレンジの「推定」「要確認」の所は、必ず図面と見比べる",
            "板厚が「未確定」の部品はDXFを作れない。板厚を入れてから作る",
            "展開寸法は曲げ控除表の値で決まる。表が仮の値のままだと寸法がずれる",
            "会社名の読み取りが違うと、別のフォルダに保存される。③の画面で会社名を直して「この会社名で保存し直す」を押す",
            "同じ名前のファイルは上書きされる(古いデータは残らない)",
            "加工の前に、アマダのソフトで寸法を確かめ、必要なら試し切りをする",
            "読み取りにはインターネットとAPIの料金がかかる。今月読み取った写真の枚数は、最初の画面の「① 図面を入れる」の下に出る",
        ]),
        Topic(title: "データを送るときの注意", icon: "paperplane", items: [
            "③の画面の「まとめて送る・保存する」から、OneDrive・Googleドライブ・メールなどを選ぶ",
            "「\"ファイル\"に保存」を選ぶと、前回保存した場所が選ばれた状態で開く。保存先を確かめてから「保存」を押す(自動保存の分があるので、ふだんは不要)",
            "Gmailアプリでは、DXFをそのまま添付できないことがある。「ファイル」アプリでファイルかフォルダを長押し →「圧縮」→ できたZIPを添付する。iPhoneの「メール」アプリなら、DXFのまま添付できる",
            "会社のパソコンでは、ZIPを右クリック →「すべて展開」してから使う",
            "ファイル名は「材質_板厚_図番_部品_x枚数.dxf」。_x2 は2枚必要という意味。_MIRROR 付きは勝手違い(左右反転)",
            "DXFは AutoCAD R12 形式・単位mm・原点は左下・切る線はすべて CUT レイヤー。アマダのソフトで読み込み、割付・加工条件を設定する",
            "図面は取引先の大切な情報。送り先を間違えないようにする",
        ]),
    ]

    var body: some View {
        List {
            ForEach(topics) { t in
                Section {
                    ForEach(Array(t.items.enumerated()), id: \.offset) { pair in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(t.title == "使う段取り" ? "\(pair.offset + 1)." : "・")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(Theme.redText)
                            Text(pair.element).font(.subheadline)
                        }
                    }
                } header: {
                    Label(t.title, systemImage: t.icon).font(.headline).foregroundStyle(.white)
                }
            }
            Section {
                NavigationLink("会社のパソコンへの送り方") { TransferGuideView() }
                LabeledContent("バージョン", value: AppInfo.version)
            }
        }
        .smScreen()
        .navigationTitle("使い方")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる") { dismiss() }
            }
        }
    }
}
