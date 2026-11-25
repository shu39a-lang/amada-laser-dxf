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

            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Spacer()
                        if running { ProgressView().tint(.black) }
                        Text(running ? progressText : "読み取る").font(.title3.bold())
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
                .disabled(images.isEmpty || running)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if let e = errorText {
                    Text(e).foregroundStyle(.red).font(.footnote)
                }
            } footer: {
                if running { Text("曲げのある図面は3〜5分ほどかかります。受信している文字数が増えていれば正常です。画面を閉じずにお待ちください。") }
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
            let result = try await reader.read(images: images, into: rec) { text in progressText = text }
            store.upsert(result)
            images = []
            picks = []
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
