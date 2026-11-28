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
                        // v4.0: 材質が空なら赤(必須)
                        HStack {
                            TextField("材質(例: SUS304)", text: binding.material)
                            AttentionTag(level: part.material.isEmpty ? .required : .ok)
                        }
                        .attention(part.material.isEmpty ? .required : .ok)
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
                    } else if flat.wrappedValue.developedBy == .plateWalls, flat.wrappedValue.plate != nil {
                        PlateEditor(plate: Binding<PlateModel>(
                            get: { flat.wrappedValue.plate ?? PlateModel() },
                            set: { flat.wrappedValue.plate = $0 }
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
                    if flat.wrappedValue.developedBy != .faces && flat.wrappedValue.developedBy != .plateWalls {
                    Section {
                        DisclosureGroup("外形の頂点(上級者向け)") {
                            ForEach(flat.outline) { $v in
                                VStack(alignment: .leading) {
                                    if let c = v.check {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text("要確認: " + c).font(.caption2).foregroundStyle(.orange)
                                            Spacer()
                                            Button("確定") { v.check = nil }
                                                .font(.caption2).buttonStyle(.bordered)
                                        }
                                    }
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
                                .attention(v.check != nil ? .check : .ok)   // v4.0: 推定した頂点はオレンジ
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
                .smScreen() // v3.9: アマダの赤の背景
                .navigationTitle(part.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") {
                            // v3.3: 側壁を直したら、分けた帯板も作り直す
                            if part.flat?.plate != nil { DrawingReader.syncStrips(in: &store.drawings[di], parentID: partID) }
                            store.save()
                            dismiss()
                        }.bold()
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
            if let c = hole.check {
                HStack(alignment: .firstTextBaseline) {
                    Text("要確認: " + c).font(.caption2).foregroundStyle(.orange)
                    Spacer()
                    // v3.6: 実物・図面で確かめたら確定にする(オレンジの印が消える)
                    Button("確定") { hole.check = nil }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }
        }
        .attention(hole.check != nil ? .check : .ok)   // v4.0: 推定した穴はオレンジ
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
                        guard !running else { return }
                        Task { await run() }
                    } label: {
                        HStack {
                            Spacer()
                            if running { SpinningGear(size: 20) }
                            Text(running ? (progressText.isEmpty ? "読み取り中…(数分かかります)" : progressText) : "読み直す").bold()
                            Spacer()
                        }
                    }
                    if let e = errorText { Text(e).foregroundStyle(.red).font(.footnote) }
                }
            }
            .smScreen() // v3.9: アマダの赤の背景
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
                let pid = store.drawings[di2].parts[pi2].id
                DrawingReader.syncStrips(in: &store.drawings[di2], parentID: pid)
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
            // v3.6: 形から作った部品などに、面を選んで丸穴を足す
            Menu {
                Button(faces.baseName) { addHole("base") }
                ForEach(faces.flanges) { f in
                    Button(f.name.isEmpty ? f.id : f.name) { addHole(f.id) }
                }
            } label: {
                Label("丸穴を追加(面を選ぶ)", systemImage: "plus.circle")
            }
        } header: {
            Text("穴・切欠き(\(faces.features.count))")
        } footer: {
            Text("a = 辺に沿った位置、d = その面の先端からの距離(基準面は左下からの X, Y)。")
        }
    }

    private func addHole(_ face: String) {
        var ft = FaceFeature()
        ft.face = face
        ft.kind = "hole"
        var h = Hole(type: .circle, d: 10)
        if face == "base" {
            h.cx = (faces.width / 2 * 10).rounded() / 10
            h.cy = (faces.height / 2 * 10).rounded() / 10
        } else {
            h.cx = 20
            h.cy = 10
        }
        ft.hole = h
        faces.features.append(ft)
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

/// v3.0: 部品表に無い板を足して、その板だけ読みに行く
struct AddPartSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let drawingID: UUID
    @State private var name = "妻板"
    @State private var hint = ""
    @State private var sameAsMain = true
    @State private var material = ""
    @State private var thicknessText = ""
    @State private var quantity = 2
    @State private var running = false
    @State private var errorText: String?
    @State private var progressText = ""

    /// 本体(1つ目のレーザー部品)
    private var mainPart: Part? {
        store.drawings.first { $0.id == drawingID }?.parts.first { $0.process == .laser }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前(例: 妻板)", text: $name)
                    TextField("例: ①の矢印の下の台形も板。樋の両端をふさぐ", text: $hint, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("どの板か(一言でOK)")
                } footer: {
                    Text("図面のどこに描かれている板かを普通の言葉で書いてください。寸法が無くても、本体の断面などから計算して形を作ります。推定した所はオレンジで表示されます。")
                }
                Section("材質・板厚・数量") {
                    Toggle("本体と同じ材質・板厚", isOn: $sameAsMain)
                    if sameAsMain {
                        if let m = mainPart {
                            Text("\(m.material.isEmpty ? "材質未確定" : m.material)  t\(m.thickness.map(Fmt.num) ?? "?")")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("材質(例: SPCC)", text: $material)
                        TextField("板厚(例: 2.3)", text: $thicknessText).keyboardType(.decimalPad)
                    }
                    Stepper("数量 \(quantity)枚", value: $quantity, in: 1...999)
                }
                Section {
                    Button {
                        guard !running else { return }
                        Task { await run() }
                    } label: {
                        HStack {
                            Spacer()
                            if running { SpinningGear(size: 20) }
                            Text(running ? (progressText.isEmpty ? "読み取り中…(数分かかります)" : progressText) : "追加して読む").bold()
                            Spacer()
                        }
                    }
                    .disabled(!running && hint.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let e = errorText { Text(e).foregroundStyle(.red).font(.footnote) }
                }
            }
            .smScreen() // v3.9: アマダの赤の背景
            .navigationTitle("板を追加して読む")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("閉じる") { dismiss() }.disabled(running) } }
        }
    }

    @MainActor private func run() async {
        guard let di = store.drawings.firstIndex(where: { $0.id == drawingID }) else { return }
        running = true
        errorText = nil
        progressText = ""
        let keep = KeepAwake()
        keep.begin()
        defer { running = false; keep.end() }

        var p = Part()
        let laserCount = store.drawings[di].parts.filter { $0.process == .laser }.count
        p.partKey = "P\(store.drawings[di].parts.count + 1)"
        p.name = (name.isEmpty ? "追加の板\(laserCount + 1)" : name) + "(追加)"
        p.process = .laser
        p.include = true
        p.quantity = quantity
        p.addedBy = "user"
        p.userHint = hint
        if sameAsMain, let m = mainPart {
            p.material = m.material
            p.thickness = m.thickness
            p.thicknessSource = m.thickness == nil ? "unknown" : "user"
        } else {
            p.material = material
            p.thickness = Double(thicknessText.replacingOccurrences(of: ",", with: "."))
            p.thicknessSource = p.thickness == nil ? "unknown" : "user"
        }
        // 先に部品を足しておく(読み取りに失敗しても「指示して読み直す」でやり直せる)
        store.drawings[di].parts.append(p)
        store.save()

        let d = store.drawings[di]
        let imgs = d.imageFiles.compactMap { store.loadImage($0) }
        guard !imgs.isEmpty else { errorText = "元の写真がありません"; return }
        let reader = DrawingReader(apiKey: store.apiKey, settings: store.settings)
        do {
            let f = try await reader.reread(part: p, drawing: d, images: imgs) { text in progressText = text }
            if let di2 = store.drawings.firstIndex(where: { $0.id == drawingID }),
               let pi2 = store.drawings[di2].parts.firstIndex(where: { $0.id == p.id }) {
                store.drawings[di2].parts[pi2].flat = f
                store.drawings[di2].parts[pi2].readError = nil
                let pid = store.drawings[di2].parts[pi2].id
                DrawingReader.syncStrips(in: &store.drawings[di2], parentID: pid)
                store.save()
            }
            dismiss()
        } catch {
            if let di2 = store.drawings.firstIndex(where: { $0.id == drawingID }),
               let pi2 = store.drawings[di2].parts.firstIndex(where: { $0.id == p.id }) {
                store.drawings[di2].parts[pi2].readError = error.localizedDescription
                store.save()
            }
            errorText = error.localizedDescription + "(部品は追加済みです。カードの「指示して読み直す」でやり直せます)"
        }
    }
}

/// v3.3: 前板+側壁の数値を直す
struct PlateEditor: View {
    @Binding var plate: PlateModel

    private func edgeLabel(_ i: Int) -> String {
        let n = plate.outline.count
        guard n > 0, i < n else { return "辺\(i + 1)" }
        let a = plate.outline[i], b = plate.outline[(i + 1) % n]
        let len = hypot(b.x - a.x, b.y - a.y)
        return "辺\(i + 1)(長さ\(Fmt.num(len)))"
    }

    var body: some View {
        Section {
            ForEach($plate.walls, id: \.edge) { $w in
                HStack {
                    Text(edgeLabel(w.edge)).font(.caption.bold())
                    NumField(label: "奥行", value: $w.depth)
                }
            }
            .onDelete { plate.walls.remove(atOffsets: $0) }
        } header: {
            Text("側壁(奥行は外寸)")
        } footer: {
            Text("内角で重なる側壁は、自動で別部品(帯板)になります。完了を押すと帯板も作り直します。")
        }
        Section("前板の穴(\(plate.holes.count)個)") {
            ForEach($plate.holes) { $hole in
                HoleEditor(index: (plate.holes.firstIndex { $0.id == hole.id } ?? 0) + 1, hole: $hole)
            }
            .onDelete { plate.holes.remove(atOffsets: $0) }
            Button("丸穴を追加") { plate.holes.append(Hole(type: .circle, d: 10)) }
        }
        Section {
            ForEach(plate.wallHoles.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text("側壁の穴 \(edgeLabel(plate.wallHoles[i].edge))").font(.caption.bold()).foregroundStyle(.red)
                    HStack {
                        NumField(label: "位置", value: $plate.wallHoles[i].along)
                        NumField(label: "先端から", value: $plate.wallHoles[i].fromFree)
                        NumField(label: "φ", value: $plate.wallHoles[i].hole.d)
                    }
                    if let c = plate.wallHoles[i].hole.check {
                        Text("要確認: " + c).font(.caption2).foregroundStyle(.orange)
                    }
                }
                .attention(plate.wallHoles[i].hole.check != nil ? .check : .ok)   // v4.0
            }
            .onDelete { plate.wallHoles.remove(atOffsets: $0) }
        } header: {
            Text("側壁の穴(\(plate.wallHoles.count)個)")
        } footer: {
            Text("位置 = 辺に沿った位置(前板と同じ座標)、先端から = 側壁の先端(前板から遠い縁)からの距離。")
        }
    }
}


// MARK: - v3.6 形から部品を作る

/// 形の種類を選び、外寸を入れて部品を作る(AIは使わない)。
///  曲げのある形は面モデルにして、展開・控除・角の逃げは既存の計算(FaceBuilder)に任せる
struct ShapePartSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let drawingID: UUID
    @State private var kind: ShapeKind = .channel
    @State private var values: [Double] = ShapeKind.channel.fields.map { $0.value }
    @State private var name = ""
    @State private var sameAsMain = true
    @State private var material = ""
    @State private var thicknessText = ""
    @State private var quantity = 1
    @State private var mirror = false

    /// 本体(1つ目のレーザー部品)
    private var mainPart: Part? {
        store.drawings.first { $0.id == drawingID }?.parts.first { $0.process == .laser && $0.thickness != nil }
    }
    private var useMaterial: String { sameAsMain ? (mainPart?.material ?? "") : material }
    private var useThickness: Double? {
        sameAsMain ? mainPart?.thickness : Double(thicknessText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func valueBinding(_ i: Int) -> Binding<Double> {
        Binding(get: { i < values.count ? values[i] : 0 },
                set: { if i < values.count { values[i] = $0 } })
    }

    /// 入力中の形で作った部品(プレビュー用)
    private var draft: (part: Part?, error: String?) {
        let r = ShapeTemplates.make(kind, values)
        guard let f = r.flat else { return (nil, r.error) }
        var p = Part()
        p.name = name.isEmpty ? kind.label : name
        p.material = useMaterial
        p.thickness = useThickness
        p.thicknessSource = useThickness == nil ? "unknown" : "user"
        p.process = .laser
        p.include = true
        p.quantity = quantity
        p.mirrorPair = mirror
        p.addedBy = "user"
        p.shapeKind = kind.rawValue
        p.bendsCount = f.faces?.flanges.count ?? 0
        p.flat = f
        return (p, nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("形", selection: $kind) {
                        ForEach(ShapeKind.allCases) { Text($0.label).tag($0) }
                    }
                    Text(kind.help).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(kind.fields.indices, id: \.self) { i in
                        NumField(label: kind.fields[i].label, value: valueBinding(i))
                    }
                } header: {
                    Text("寸法(mm・外寸)")
                }
                Section("プレビュー") {
                    let dr = draft
                    if let p = dr.part {
                        if p.thickness == nil {
                            Text("板厚を入れると展開のプレビューが出ます").font(.footnote).foregroundStyle(.yellow)
                        } else {
                            let built = Geometry.build(part: p, settings: store.settings)
                            if built.outline.isEmpty {
                                ForEach(built.blocking, id: \.self) { Text("・" + $0).font(.caption).foregroundStyle(.red) }
                            } else {
                                PartPreview(built: built, showLabels: true)
                                    .frame(height: 220)
                                Text("展開寸法 \(Fmt.num(built.width)) × \(Fmt.num(built.height)) mm")
                                    .font(.subheadline)
                                ForEach(built.warnings, id: \.self) { Text("・" + $0).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    } else if let e = dr.error {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("名前(例: 本体コの字板)", text: $name)
                    Toggle("本体と同じ材質・板厚", isOn: $sameAsMain)
                    if sameAsMain {
                        if let m = mainPart {
                            Text("\(m.material.isEmpty ? "材質未確定" : m.material)  t\(m.thickness.map(Fmt.num) ?? "?")")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("板厚の決まった部品がまだありません。下のスイッチを切って入れてください").font(.caption).foregroundStyle(.yellow)
                        }
                    } else {
                        TextField("材質(例: SUS304)", text: $material)
                        TextField("板厚(例: 1.5)", text: $thicknessText).keyboardType(.decimalPad)
                    }
                    Stepper("数量 \(quantity)枚", value: $quantity, in: 1...999)
                    Toggle("勝手違い(左右反転)も作る", isOn: $mirror)
                } header: {
                    Text("名前・材質・板厚・数量")
                } footer: {
                    Text("穴は、作ったあとの「数値を直す」で面を選んで足せます。")
                }
            }
            .onChange(of: kind) { _, k in values = k.fields.map { $0.value } }
            .smScreen() // v3.9: アマダの赤の背景
            .navigationTitle("形から部品を作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("作る") { add() }
                        .bold()
                        .disabled(draft.part == nil)
                }
            }
        }
    }

    private func add() {
        guard var p = draft.part,
              let di = store.drawings.firstIndex(where: { $0.id == drawingID }) else { return }
        p.partKey = PartOps.newKey(store.drawings[di])
        store.drawings[di].parts.append(p)
        store.save()
        dismiss()
    }
}
