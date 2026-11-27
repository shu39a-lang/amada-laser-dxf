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

    var body: some View {
        List {
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
                Text("図面全体を真上から撮ってください。数字が小さい図面は、部分のアップ写真を足すと精度が上がります(最大4枚)。")
                    .font(.footnote).foregroundStyle(.secondary)
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
                .foregroundStyle(.black)
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
        .navigationTitle("SHEET MASTER")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
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
        .navigationDestination(item: $openID) { id in
            ResultView(drawingID: id)
        }
    }

    @MainActor private func run() async {
        errorText = nil
        running = true
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
            Text("\(number)")
                .font(.headline).foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.yellow))
            Text(title).font(.title3.bold()).foregroundStyle(.yellow)
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
