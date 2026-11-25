import SwiftUI

/// 数値を直す(変更はプレビューにすぐ反映)
struct PartEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let drawingID: UUID
    let partID: UUID
    @State private var showPositions = true

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            if let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
               let pi = store.drawings[di].parts.firstIndex(where: { $0.id == partID }) {
                let binding = $store.drawings[di].parts[pi]
                let part = store.drawings[di].parts[pi]
                let built = Geometry.build(part: part, settings: store.settings)
                let flat = Binding<FlatPattern>(
                    get: { binding.wrappedValue.flat ?? FlatPattern() },
                    set: { binding.wrappedValue.flat = $0 }
                )
                Form {
                    Section {
                        if !built.outline.isEmpty {
                            PartPreview(built: built, showLabels: true, showPositions: showPositions)
                                .frame(height: 200)
                            Toggle("穴の位置(X, Y)を表示", isOn: $showPositions).font(.footnote)
                        }
                        Text("位置は左下の角を(0, 0)として、右がX、上がYです(mm)。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("板") {
                        TextField("名前", text: binding.name)
                        TextField("材質(例: SUS304)", text: binding.material)
                        HStack {
                            Text("板厚 t")
                            ThicknessField(part: binding)
                        }
                        Stepper("数量 \(part.quantity)枚", value: binding.quantity, in: 1...999)
                        Toggle("勝手違い(左右反転)も作る", isOn: binding.mirrorPair)
                    }
                    if flat.wrappedValue.developedBy == .faces, flat.wrappedValue.faces != nil {
                        FacesEditor(faces: Binding<FaceModel>(
                            get: { flat.wrappedValue.faces ?? FaceModel() },
                            set: { flat.wrappedValue.faces = $0 }
                        ))
                    } else {
                    Section("穴(\(flat.wrappedValue.holes.count)個)") {
                        ForEach(flat.holes) { $hole in
                            HoleEditor(index: (flat.wrappedValue.holes.firstIndex { $0.id == hole.id } ?? 0) + 1, hole: $hole)
                        }
                        .onDelete { flat.wrappedValue.holes.remove(atOffsets: $0) }
                        Button("丸穴を追加") { flat.wrappedValue.holes.append(Hole(type: .circle, d: 10)) }
                    }
                    if flat.wrappedValue.developedBy == .outerDims || !flat.wrappedValue.bends.isEmpty {
                        Section {
                            ForEach(flat.bends) { $bend in
                                HStack {
                                    Text(bend.axis == .x ? "縦線 X" : "横線 Y").font(.caption)
                                    NumField(label: "位置", value: $bend.position)
                                    NumField(label: "角度", value: $bend.angleDeg)
                                }
                            }
                            .onDelete { flat.wrappedValue.bends.remove(atOffsets: $0) }
                        } header: {
                            Text("曲げ線")
                        } footer: {
                            Text("曲げ線の位置は外寸で入れます。展開長は設定の曲げ控除表で自動計算します。")
                        }
                    }
                    }
                    if flat.wrappedValue.developedBy != .faces {
                    Section {
                        DisclosureGroup("外形の頂点(上級者向け)") {
                            ForEach(flat.outline) { $v in
                                VStack(alignment: .leading) {
                                    HStack {
                                        NumField(label: "X", value: $v.x)
                                        NumField(label: "Y", value: $v.y)
                                    }
                                    HStack {
                                        Picker("角", selection: $v.cornerType) {
                                            ForEach(CornerType.allCases) { Text($0.label).tag($0) }
                                        }
                                        if v.cornerType != .none {
                                            NumField(label: "大きさ", value: $v.cornerSize)
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                            .onDelete { flat.wrappedValue.outline.remove(atOffsets: $0) }
                        }
                    } footer: {
                        Text("外形が大きく違うときは、ここを直すより「指示して読み直す」の方が簡単です。")
                    }
                    }
                    Section {
                        Picker("区分", selection: binding.process) {
                            ForEach(PartProcess.allCases) { Text($0.label).tag($0) }
                        }
                        NavigationLink("AIの返答(生データ)") {
                            RawTextView(title: "AIの返答", text: part.flat?.rawJSON ?? (part.readError ?? "まだ返答がありません"))
                        }
                    }
                }
                .navigationTitle(part.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { store.save(); dismiss() }.bold()
                    }
                }
            } else {
                Text("部品が見つかりません")
            }
        }
    }
}

struct HoleEditor: View {
    let index: Int
    @Binding var hole: Hole

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("穴\(index)").font(.caption.bold()).foregroundStyle(.red)
                Picker("", selection: $hole.type) {
                    ForEach(HoleType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            switch hole.type {
            case .circle:
                HStack { NumField(label: "X", value: $hole.cx); NumField(label: "Y", value: $hole.cy); NumField(label: "φ", value: $hole.d) }
            case .slot:
                HStack { NumField(label: "X1", value: $hole.x1); NumField(label: "Y1", value: $hole.y1) }
                HStack { NumField(label: "X2", value: $hole.x2); NumField(label: "Y2", value: $hole.y2); NumField(label: "幅", value: $hole.width) }
            case .rect:
                HStack { NumField(label: "X", value: $hole.cx); NumField(label: "Y", value: $hole.cy) }
                HStack { NumField(label: "幅", value: $hole.w); NumField(label: "高", value: $hole.h); NumField(label: "R", value: $hole.cornerR) }
            case .polygon:
                Text("異形の穴(数値の変更は「指示して読み直す」で)").font(.caption)
            }
            if !hole.note.isEmpty { Text(hole.note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// 指示して読み直す
struct RereadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let drawingID: UUID
    let partID: UUID
    @State private var hint = ""
    @State private var running = false
    @State private var errorText: String?
    @State private var progressText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例: 下の正面図の板だけ。U溝は2か所、左端から51と503。板厚t4", text: $hint, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("AIへの指示(空でも可)")
                } footer: {
                    Text("違っている所を普通の言葉で書いてください。この部品だけ読み直します。")
                }
                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        HStack {
                            Spacer()
                            if running { ProgressView() }
                            Text(running ? (progressText.isEmpty ? "読み取り中…(数分かかります)" : progressText) : "読み直す").bold()
                            Spacer()
                        }
                    }
                    .disabled(running)
                    if let e = errorText { Text(e).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("指示して読み直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("閉じる") { dismiss() }.disabled(running) } }
            .onAppear {
                if let d = store.drawings.first(where: { $0.id == drawingID }),
                   let p = d.parts.first(where: { $0.id == partID }) { hint = p.userHint }
            }
        }
    }

    @MainActor private func run() async {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }),
              let pi = store.drawings[di].parts.firstIndex(where: { $0.id == partID }) else { return }
        running = true
        errorText = nil
        progressText = ""
        let keep = KeepAwake()
        keep.begin()
        defer { running = false; keep.end() }
        store.drawings[di].parts[pi].userHint = hint
        let d = store.drawings[di]
        let part = d.parts[pi]
        let imgs = d.imageFiles.compactMap { store.loadImage($0) }
        guard !imgs.isEmpty else { errorText = "元の写真がありません"; return }
        let reader = DrawingReader(apiKey: store.apiKey, settings: store.settings)
        do {
            let f = try await reader.reread(part: part, drawing: d, images: imgs) { text in progressText = text }
            if let di2 = store.drawings.firstIndex(where: { $0.id == drawingID }),
               let pi2 = store.drawings[di2].parts.firstIndex(where: { $0.id == partID }) {
                store.drawings[di2].parts[pi2].flat = f
                store.drawings[di2].parts[pi2].readError = nil
                store.save()
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 曲げ部品(面モデル)の数値を直す
struct FacesEditor: View {
    @Binding var faces: FaceModel

    private func faceName(_ id: String) -> String {
        if id == "base" { return faces.baseName }
        return faces.flanges.first { $0.id == id }.map { $0.name.isEmpty ? $0.id : $0.name } ?? id
    }

    var body: some View {
        Section {
            HStack {
                Text(faces.baseName).font(.caption.bold())
                NumField(label: "横", value: $faces.width)
                NumField(label: "縦", value: $faces.height)
            }
            ForEach($faces.flanges) { $f in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(f.name.isEmpty ? f.id : f.name)(\(edgeLabel(f.edge))・\(f.up ? "手前へ" : "奥へ")\(Fmt.num(f.angleDeg))°)")
                        .font(.caption.bold())
                    HStack {
                        NumField(label: "長さ", value: $f.length)
                        Toggle("内寸", isOn: $f.lengthInner).font(.caption2).fixedSize()
                    }
                }
            }
        } header: {
            Text("面の寸法(外寸)")
        } footer: {
            Text("曲げのある部品は、面ごとの外寸から展開長・角の逃げをアプリが計算します。「内寸」は図面の寸法が反対側の面から測られている場合(板厚を足します)。")
        }
        Section {
            ForEach($faces.features) { $ft in
                VStack(alignment: .leading, spacing: 4) {
                    if ft.kind == "notch" {
                        Text("切欠き(\(faceName(ft.face)))").font(.caption.bold()).foregroundStyle(.red)
                        HStack {
                            NumField(label: "位置", value: $ft.center)
                            NumField(label: "幅", value: $ft.width)
                            NumField(label: "深さ", value: $ft.depth)
                        }
                    } else {
                        Text("穴(\(faceName(ft.face)))").font(.caption.bold()).foregroundStyle(.red)
                        switch ft.hole.type {
                        case .circle:
                            HStack { NumField(label: "a", value: $ft.hole.cx); NumField(label: "d", value: $ft.hole.cy); NumField(label: "φ", value: $ft.hole.d) }
                        case .slot:
                            HStack { NumField(label: "a1", value: $ft.hole.x1); NumField(label: "d1", value: $ft.hole.y1) }
                            HStack { NumField(label: "a2", value: $ft.hole.x2); NumField(label: "d2", value: $ft.hole.y2); NumField(label: "幅", value: $ft.hole.width) }
                        case .rect:
                            HStack { NumField(label: "a", value: $ft.hole.cx); NumField(label: "d", value: $ft.hole.cy) }
                            HStack { NumField(label: "幅", value: $ft.hole.w); NumField(label: "高", value: $ft.hole.h); NumField(label: "R", value: $ft.hole.cornerR) }
                        case .polygon:
                            Text("異形の穴").font(.caption)
                        }
                    }
                }
            }
            .onDelete { faces.features.remove(atOffsets: $0) }
        } header: {
            Text("穴・切欠き(\(faces.features.count))")
        } footer: {
            Text("a = 辺に沿った位置、d = その面の先端からの距離(基準面は左下からの X, Y)。")
        }
    }

    private func edgeLabel(_ e: String) -> String {
        switch e {
        case "bottom": return "下辺"
        case "top": return "上辺"
        case "left": return "左辺"
        case "right": return "右辺"
        default: return "先端"
        }
    }
}
