import UIKit

/// 図面写真 → DrawingRecord(部品一覧+各部品の展開形状)
struct DrawingReader {
    let client: ClaudeClient
    let settings: AppSettings

    /// 回答を控えられたとき用のもう一方のモデル
    let fallbackClient: ClaudeClient

    init(apiKey: String, settings: AppSettings) {
        self.client = ClaudeClient(apiKey: apiKey, model: settings.model)
        let other = settings.model == "claude-opus-5-5" ? "claude-sonnet-5-5" : "claude-opus-5-5"
        self.fallbackClient = ClaudeClient(apiKey: apiKey, model: other)
        self.settings = settings
    }

    func read(images: [UIImage],
              into base: DrawingRecord,
              progress: @escaping @MainActor (String) -> Void) async throws -> DrawingRecord {
        await progress("写真を拡大タイルに分割中…")
        let prepared = ImagePreprocessor.prepare(images, grid: settings.tileMode.grid)
        guard !prepared.isEmpty else { throw ClaudeError.noToolResult("画像を読み込めませんでした") }

        // 段階A
        await progress("部品を洗い出し中(材質・板厚・数量)…")
        var rec = base
        let counterA = ReceiveCounter()
        let inv = try await inventory(prepared) { n in
            if let total = counterA.add(n) {
                Task { @MainActor in progress("部品を洗い出し中…(受信 \(total)字)") }
            }
        }
        apply(inventory: inv, to: &rec)
        rec.rawInventory = J.pretty(inv)

        // v2.8: 板の部品が0件なら、理由を添えて1回だけ洗い出しをやり直す
        if !rec.parts.contains(where: { $0.process == .laser }) {
            await progress("板の部品が見つからなかったので、もう一度洗い出し中…")
            let found = rec.parts.map { "\($0.name)(\($0.process.rawValue))" }.joined(separator: "、")
            let note = """
            前回の回答では、レーザーで抜く板の部品が0件でした(返ってきた部品: \(found.isEmpty ? "なし" : found))。
            表題欄の品名の部品(カバー・ブラケット・板など)は、溶接ナット・溶接・焼け取り・みがきの指示があっても板金部品なので、必ず parts に process="laser" で入れてください。
            溶接ナット・ボルトなどは process="purchased" で別の行にします。parts は配列で返してください(文字列にしない)。
            """
            if let inv2 = try? await inventory(prepared, retryNote: note, onProgress: { _ in }) {
                var rec2 = base
                apply(inventory: inv2, to: &rec2)
                if rec2.parts.contains(where: { $0.process == .laser }) {
                    rec = rec2
                    rec.rawInventory = J.pretty(inv2)
                }
            }
        }

        // それでも0件なら、表題欄の品名で板を1つ作って展開を読みに行く(1枚もの図面が大半のため)
        if !rec.parts.contains(where: { $0.process == .laser }) {
            var p = Part()
            p.partKey = "P\(rec.parts.count + 1)"
            p.name = rec.title.isEmpty ? "部品1(自動追加)" : rec.title + "(自動追加)"
            p.material = J.str(inv["default_material"])
            p.process = .laser
            p.include = true
            p.quantity = 1
            p.thicknessSource = "unknown"
            rec.parts.insert(p, at: 0)
            rec.questions.insert("板の部品を自動で見つけられなかったため、品名の板を1つ追加して読みました。材質・板厚・数量を確認してください", at: 0)
        }

        // 段階B(レーザー部品だけ、並列)
        let targets = rec.parts.filter { $0.process == .laser }
        await progress("展開形状を読み取り中(0/\(targets.count))…")
        var done = 0
        let snapshot = rec
        let counterB = ReceiveCounter()
        let total = targets.count
        var results: [UUID: Result<FlatPattern, Error>] = [:]
        try await withThrowingTaskGroup(of: (UUID, Result<FlatPattern, Error>).self) { group in
            for p in targets {
                group.addTask {
                    do {
                        let f = try await flatPattern(for: p, drawing: snapshot, images: prepared) { n in
                            if let chars = counterB.add(n) {
                                Task { @MainActor in progress("展開形状を読み取り中(\(total)部品)…受信 \(chars)字") }
                            }
                        }
                        return (p.id, .success(f))
                    }
                    catch { return (p.id, .failure(error)) }
                }
            }
            for try await (id, r) in group {
                results[id] = r
                done += 1
                await progress("展開形状を読み取り中(\(done)/\(total))…")
            }
        }
        for i in rec.parts.indices {
            switch results[rec.parts[i].id] {
            case .success(let f)?: rec.parts[i].flat = f; rec.parts[i].readError = nil
            case .failure(let e)?: rec.parts[i].readError = e.localizedDescription
            case nil: break
            }
        }
        rec.appVersion = AppInfo.version
        return rec
    }

    /// 1部品だけ読み直す(ユーザーのヒント付き)
    func reread(part: Part, drawing: DrawingRecord, images: [UIImage],
                progress: (@MainActor (String) -> Void)? = nil) async throws -> FlatPattern {
        let prepared = ImagePreprocessor.prepare(images, grid: settings.tileMode.grid)
        let counter = ReceiveCounter()
        return try await flatPattern(for: part, drawing: drawing, images: prepared) { n in
            if let p = progress, let chars = counter.add(n) {
                Task { @MainActor in p("読み取り中…受信 \(chars)字") }
            }
        }
    }

    // MARK: - 段階A

    private func inventory(_ images: [PreparedImage], retryNote: String? = nil,
                           onProgress: @escaping (Int) -> Void) async throws -> [String: Any] {
        var content = ClaudeClient.imageBlocks(images, cacheLast: false)
        var text = "この図面のレーザー加工対象の板部品をすべて洗い出してください。"
        if let n = retryNote { text += "\n\n【読み直しの理由】\n" + n }
        content.append(["type": "text", "text": text])
        do {
            return try await client.callTool(system: Prompts.inventorySystem, content: content,
                                             toolName: "report_inventory",
                                             toolDescription: "図面から部品一覧を報告する",
                                             inputSchemaJSON: Prompts.inventorySchema, maxTokens: 16000,
                                             thinkingBudget: 5000, onProgress: onProgress)
        } catch ClaudeError.truncated {
            return try await client.callTool(system: Prompts.inventorySystem, content: content,
                                             toolName: "report_inventory",
                                             toolDescription: "図面から部品一覧を報告する",
                                             inputSchemaJSON: Prompts.inventorySchema, maxTokens: 32000,
                                             thinkingBudget: 5000, onProgress: onProgress)
        }
    }

    private func apply(inventory o: [String: Any], to rec: inout DrawingRecord) {
        rec.analysis = J.str(o["analysis"])
        rec.drawingNumber = J.str(o["drawing_number"])
        rec.title = J.str(o["title"])
        rec.productNumber = J.str(o["product_number"])
        rec.notes = J.strs(o["notes"])
        rec.questions = J.strs(o["questions"])
        let defMat = J.str(o["default_material"])
        rec.parts = J.arr(o["parts"]).enumerated().map { pair -> Part in
            let i = pair.offset
            let p = pair.element
            var part = Part()
            part.partKey = J.str(p["id"]).isEmpty ? "P\(i + 1)" : J.str(p["id"])
            part.name = J.str(p["name"])
            let m = J.str(p["material"])
            part.material = m.isEmpty ? defMat : m
            part.thickness = J.num(p["thickness_mm"])
            part.thicknessSource = J.str(p["thickness_source"]).isEmpty ? "unknown" : J.str(p["thickness_source"])
            part.thicknessEvidence = J.str(p["thickness_evidence"])
            part.process = PartProcess(rawValue: J.str(p["process"])) ?? .laser
            part.quantity = max(1, Int(J.num(p["quantity"]) ?? 1))
            part.mirrorPair = (p["mirror_pair"] as? Bool) ?? (J.str(p["mirror_pair"]).lowercased() == "true")
            part.bendsCount = Int(J.num(p["bends_count"]) ?? 0)
            part.viewsDescription = J.str(p["views"])
            part.confidence = J.num(p["confidence"]) ?? 0
            part.include = part.process == .laser
            return part
        }
    }

    // MARK: - 段階B

    /// v2.7: 1回目の回答から外形が作れなければ、理由を添えて1回だけ自動で読み直す
    ///  (長円・円弧の板に曲げがある部品などで「形を読み取れませんでした」になっていた対策)
    private func flatPattern(for part: Part, drawing: DrawingRecord, images: [PreparedImage],
                             onProgress: @escaping (Int) -> Void) async throws -> FlatPattern {
        let first: FlatPattern
        do {
            first = try await flatPatternOnce(for: part, drawing: drawing, images: images,
                                              retryNote: nil, onProgress: onProgress)
        } catch ClaudeError.truncated {
            // 64000でも切れた → 説明を短くさせて再送
            return try await flatPatternOnce(for: part, drawing: drawing, images: images,
                                             retryNote: "前回は回答が長すぎて途中で切れました。analysis は200字以内、uncertain は5件以内にして、座標だけを確実に返してください。",
                                             onProgress: onProgress)
        }
        let problem = Self.shapeProblem(first, part: part, settings: settings)
        guard let reason = problem else { return first }
        let note = """
        前回の回答では展開形状を作れませんでした(理由: \(reason))。
        ・基準面に円弧の端・長円・斜めカットがあり、一部の辺にだけフランジがある部品は developed_by="outer_dims" で、outline(円弧は arc_to_next)と bends(start/end付き)を書く。
        ・曲げの無い板(帯板を含む)は developed_by="flat" で outline を3点以上書く。
        ・faces を使う場合は width・height・flanges を必ず入れる。
        """
        do {
            let second = try await flatPatternOnce(for: part, drawing: drawing, images: images,
                                                   retryNote: note, onProgress: onProgress)
            return Self.shapeProblem(second, part: part, settings: settings) == nil ? second : first
        } catch {
            return first
        }
    }

    /// 外形が作れない・頂点が足りない等の、読み直しが必要な問題(無ければ nil)
    static func shapeProblem(_ f: FlatPattern, part: Part, settings: AppSettings) -> String? {
        var tmp = part
        tmp.flat = f
        if tmp.thickness == nil { tmp.thickness = 1 }   // 板厚未確定は読み直しの理由にしない
        let b = Geometry.build(part: tmp, settings: settings)
        if b.outline.isEmpty {
            let r = b.blocking.filter { !$0.contains("控除表") && !$0.contains("板厚") }
            return r.isEmpty ? (b.blocking.isEmpty ? "外形が空でした" : nil) : r.joined(separator: " / ")
        }
        if b.width < 1 || b.height < 1 { return "外形の大きさが0でした" }
        // v2.9: 部品一覧では曲げがあるのに、展開に曲げ線が1本も無い(フランジの読み落とし)
        if part.bendsCount > 0 && b.bendLines.isEmpty {
            return "部品一覧では曲げが\(part.bendsCount)か所あるのに、展開形状に曲げ線(フランジ)がありませんでした。二重線で描かれた辺・側面図の立ち上がりを確認し、フランジを含めた展開にしてください"
        }
        return nil
    }

    private func flatPatternOnce(for part: Part, drawing: DrawingRecord, images: [PreparedImage],
                                 retryNote: String?,
                                 onProgress: @escaping (Int) -> Void) async throws -> FlatPattern {
        var content = ClaudeClient.imageBlocks(images, cacheLast: true)
        let others = drawing.parts.filter { $0.id != part.id }
            .map { "\($0.partKey) \($0.name)(\($0.process.label)、t\($0.thickness.map(Fmt.num) ?? "?"))" }
            .joined(separator: " / ")
        var text = """
        対象部品: \(part.partKey)「\(part.name)」
        材質: \(part.material)  板厚: \(part.thickness.map { "t" + Fmt.num($0) } ?? "未確定")  曲げ回数(参考): \(part.bendsCount)
        描かれている場所: \(part.viewsDescription)
        図面の注記: \(drawing.notes.joined(separator: " / "))
        同じ図面の他の部品(これらは出さない): \(others.isEmpty ? "なし" : others)
        この部品1つだけの展開形状を出してください。
        """
        if !part.userHint.isEmpty {
            text += "\n\n【作業者からの指示(最優先)】\n\(part.userHint)"
        }
        if let note = retryNote {
            text += "\n\n【読み直しの理由】\n\(note)"
        }
        content.append(["type": "text", "text": text])
        let system = Prompts.flatSystem(tapTable: settings.tapDrills)
        let out: [String: Any]
        let budget = 12000
        do {
            out = try await client.callTool(system: system, content: content, toolName: "report_flat_pattern",
                                            toolDescription: "1部品の展開形状を報告する",
                                            inputSchemaJSON: Prompts.flatSchema, maxTokens: 32000,
                                            thinkingBudget: budget, onProgress: onProgress)
        } catch ClaudeError.truncated {
            out = try await client.callTool(system: system, content: content, toolName: "report_flat_pattern",
                                            toolDescription: "1部品の展開形状を報告する",
                                            inputSchemaJSON: Prompts.flatSchema, maxTokens: 64000,
                                            thinkingBudget: budget, onProgress: onProgress)
        } catch ClaudeError.refused {
            // 何度送っても回答を控えられた場合は、もう一方のモデルで1回だけ試す
            out = try await fallbackClient.callTool(system: system, content: content, toolName: "report_flat_pattern",
                                                    toolDescription: "1部品の展開形状を報告する",
                                                    inputSchemaJSON: Prompts.flatSchema, maxTokens: 32000,
                                                    thinkingBudget: budget, onProgress: onProgress)
        } catch ClaudeError.noToolResult(_) {
            out = try await fallbackClient.callTool(system: system, content: content, toolName: "report_flat_pattern",
                                                    toolDescription: "1部品の展開形状を報告する",
                                                    inputSchemaJSON: Prompts.flatSchema, maxTokens: 32000,
                                                    thinkingBudget: budget, onProgress: onProgress)
        }
        var f = Self.parseFlat(out)
        Self.normalizePhotos(&f, images: images)
        f.rawJSON = J.pretty(out)
        return f
    }

    static func parseFlat(_ o: [String: Any]) -> FlatPattern {
        var f = FlatPattern()
        f.analysis = J.str(o["analysis"])
        switch J.str(o["developed_by"]) {
        case "faces": f.developedBy = .faces
        case "outer_dims": f.developedBy = .outerDims
        default: f.developedBy = .flat
        }
        if let fo = J.obj(o["faces"]) {
            f.faces = parseFaces(fo)
            if f.developedBy != .faces, f.faces != nil, J.arr(o["outline"]).count < 3 { f.developedBy = .faces }
        }
        if f.developedBy == .faces && f.faces == nil { f.developedBy = .flat }
        f.outline = J.arr(o["outline"]).compactMap { (v) -> OutlineVertex? in
            guard let x = J.num(v["x"]), let y = J.num(v["y"]) else { return nil }
            var ov = OutlineVertex(x: x, y: y)
            ov.cornerType = CornerType(rawValue: J.str(v["corner_type"])) ?? .none
            ov.cornerSize = J.num(v["corner_size"]) ?? 0
            if ov.cornerSize <= 0 { ov.cornerType = .none }
            if let a = J.obj(v["arc_to_next"]), let cx = J.num(a["cx"]), let cy = J.num(a["cy"]) {
                ov.arcToNext = ArcSpec(cx: cx, cy: cy, clockwise: (a["clockwise"] as? Bool) ?? false)
            }
            return ov
        }
        // 最後の頂点が最初と同じなら除く
        if f.outline.count > 2, let a = f.outline.first, let b = f.outline.last,
           abs(a.x - b.x) < 0.001, abs(a.y - b.y) < 0.001 { f.outline.removeLast() }

        f.holes = J.arr(o["holes"]).compactMap { (h) -> Hole? in
            guard let t = HoleType(rawValue: J.str(h["type"])) else { return nil }
            var hole = Hole(type: t)
            hole.cx = J.num(h["cx"]) ?? 0; hole.cy = J.num(h["cy"]) ?? 0; hole.d = J.num(h["d"]) ?? 0
            hole.x1 = J.num(h["x1"]) ?? 0; hole.y1 = J.num(h["y1"]) ?? 0
            hole.x2 = J.num(h["x2"]) ?? 0; hole.y2 = J.num(h["y2"]) ?? 0
            hole.width = J.num(h["width"]) ?? 0
            hole.w = J.num(h["w"]) ?? 0; hole.h = J.num(h["h"]) ?? 0
            hole.angle = J.num(h["angle"]) ?? 0; hole.cornerR = J.num(h["corner_r"]) ?? 0
            hole.points = J.list(h["points"]).compactMap { (p) -> P2? in
                guard let a = p as? [Any], a.count >= 2, let x = J.num(a[0]), let y = J.num(a[1]) else { return nil }
                return P2(x: x, y: y)
            }
            hole.note = J.str(h["note"])
            parsePhoto(h, into: &hole)
            return hole
        }
        f.bends = J.arr(o["bends"]).compactMap { (b) -> Bend? in
            guard let pos = J.num(b["position"]) else { return nil }
            var bend = Bend()
            bend.axis = J.str(b["axis"]) == "y" ? .y : .x
            bend.position = pos
            bend.angleDeg = J.num(b["angle_deg"]) ?? 90
            bend.up = J.str(b["direction"]) != "down"
            bend.note = J.str(b["note"])
            bend.from = J.num(b["start"])
            bend.to = J.num(b["end"])
            if let a = bend.from, let z = bend.to, a > z { bend.from = z; bend.to = a }
            return bend
        }
        f.keyDimensions = J.arr(o["key_dimensions"]).compactMap { (k) -> KeyDimension? in
            guard let v = J.num(k["value"]) else { return nil }
            return KeyDimension(label: J.str(k["label"]), value: v, axis: J.str(k["axis"]))
        }
        f.uncertain = J.strs(o["uncertain"])
        f.confidence = J.num(o["confidence"]) ?? 0
        return f
    }
}

extension DrawingReader {
    /// v2.9: 穴の「写真上の位置」(全体画像のピクセル)をいったんそのまま入れる。割合への変換は normalizePhotos
    static func parsePhoto(_ h: [String: Any], into hole: inout Hole) {
        guard let p = J.obj(h["photo"]), let no = J.num(p["no"]),
              let px = J.num(p["px"]), let py = J.num(p["py"]) else { return }
        hole.photoNo = Int(no)
        hole.photoX = px
        hole.photoY = py
    }

    /// v2.9: ピクセル → 写真の幅・高さに対する割合(0〜1)。おかしな値は捨てる
    static func normalizePhotos(_ f: inout FlatPattern, images: [PreparedImage]) {
        var sizes: [Int: CGSize] = [:]
        for im in images { if let sz = im.fullSize { sizes[im.photoNo] = sz } }
        func fix(_ h: inout Hole) {
            defer {
                if h.photoX == nil || h.photoY == nil { h.photoNo = nil; h.photoX = nil; h.photoY = nil }
            }
            guard let no = h.photoNo, let x = h.photoX, let y = h.photoY,
                  let sz = sizes[no], sz.width > 0, sz.height > 0 else { h.photoX = nil; return }
            // すでに割合(0〜1)で返ってきた場合はそのまま
            let u = (x <= 1 && y <= 1) ? x : x / Double(sz.width)
            let v = (x <= 1 && y <= 1) ? y : y / Double(sz.height)
            if u < 0 || u > 1 || v < 0 || v > 1 { h.photoX = nil; return }
            h.photoX = u
            h.photoY = v
        }
        for i in f.holes.indices { fix(&f.holes[i]) }
        if var fm = f.faces {
            for i in fm.features.indices where fm.features[i].kind == "hole" { fix(&fm.features[i].hole) }
            f.faces = fm
        }
    }

    static func parseFaces(_ o: [String: Any]) -> FaceModel? {
        var m = FaceModel()
        m.baseName = J.str(o["base_name"]).isEmpty ? "基準面" : J.str(o["base_name"])
        guard let w = J.num(o["width"]), let h = J.num(o["height"]), w > 0, h > 0 else { return nil }
        m.width = w
        m.height = h
        func corners(_ a: Any?) -> [FaceCorner] {
            J.arr(a).compactMap { c -> FaceCorner? in
                guard let size = J.num(c["size"]), size > 0,
                      let type = CornerType(rawValue: J.str(c["type"])), type != .none else { return nil }
                return FaceCorner(at: J.str(c["at"]), type: type, size: size)
            }
        }
        m.baseCorners = corners(o["base_corners"])
        m.flanges = J.arr(o["flanges"]).enumerated().compactMap { pair -> FaceFlange? in
            let x = pair.element
            guard let len = J.num(x["length"]), len > 0 else { return nil }
            let id = J.str(x["id"]).isEmpty ? "F\(pair.offset + 1)" : J.str(x["id"])
            var f = FaceFlange(id: id)
            f.name = J.str(x["name"])
            f.parent = J.str(x["parent"]).isEmpty ? "base" : J.str(x["parent"])
            f.edge = J.str(x["edge"]).isEmpty ? (f.parent == "base" ? "bottom" : "free") : J.str(x["edge"])
            f.length = len
            f.lengthInner = J.str(x["length_ref"]) == "inner"
            f.angleDeg = J.num(x["angle_deg"]) ?? 90
            f.up = J.str(x["direction"]) == "up"
            f.start = J.num(x["start"])
            f.end = J.num(x["end"])
            f.corners = corners(x["corners"])
            return f
        }
        var feats: [FaceFeature] = []
        for x in J.arr(o["holes"]) {
            guard let t = HoleType(rawValue: J.str(x["type"])) else { continue }
            var ft = FaceFeature()
            ft.face = J.str(x["face"]).isEmpty ? "base" : J.str(x["face"])
            ft.kind = "hole"
            var hole = Hole(type: t)
            hole.cx = J.num(x["a"]) ?? 0
            hole.cy = J.num(x["d"]) ?? 0
            hole.d = J.num(x["dia"]) ?? 0
            hole.x1 = J.num(x["a"]) ?? 0
            hole.y1 = J.num(x["d"]) ?? 0
            hole.x2 = J.num(x["a2"]) ?? 0
            hole.y2 = J.num(x["d2"]) ?? 0
            hole.width = J.num(x["width"]) ?? 0
            hole.w = J.num(x["w"]) ?? 0
            hole.h = J.num(x["h"]) ?? 0
            hole.cornerR = J.num(x["corner_r"]) ?? 0
            hole.note = J.str(x["note"])
            parsePhoto(x, into: &hole)
            ft.hole = hole
            feats.append(ft)
        }
        for x in J.arr(o["notches"]) {
            guard let width = J.num(x["width"]), width > 0 else { continue }
            var ft = FaceFeature()
            ft.face = J.str(x["face"]).isEmpty ? "base" : J.str(x["face"])
            ft.kind = "notch"
            ft.edge = J.str(x["edge"]).isEmpty ? "free" : J.str(x["edge"])
            ft.center = J.num(x["center"]) ?? 0
            ft.width = width
            ft.depth = J.num(x["depth"]) ?? 0
            ft.roundEnd = (x["round_end"] as? Bool) ?? true
            ft.mouthR = J.num(x["mouth_r"]) ?? 0
            feats.append(ft)
        }
        m.features = feats
        return m
    }
}

/// 型がぶれても読めるJSONヘルパー(数値が文字列で来ても可)
enum J {
    static func pretty(_ o: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "\(o)" }
        return s
    }
    static func str(_ a: Any?) -> String {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }
    /// v2.8: AIが配列・オブジェクトを「JSONの文字列」で返すことがあるので、文字列なら中身を解析して使う
    ///  (v2.7までは部品一覧が文字列で返ると0件扱いになり「板の部品が見つかりませんでした」になっていた)
    static func decoded(_ a: Any?) -> Any? {
        guard let s = a as? String else { return a }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first, f == "[" || f == "{", let d = t.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: d) else { return a }
        return v
    }
    static func strs(_ a: Any?) -> [String] { (decoded(a) as? [Any] ?? []).map { str($0) }.filter { !$0.isEmpty } }
    static func arr(_ a: Any?) -> [[String: Any]] {
        let v = decoded(a)
        if let x = v as? [[String: Any]] { return x }
        if let x = v as? [Any] { return x.compactMap { decoded($0) as? [String: Any] } }
        if let x = v as? [String: Any] { return [x] }      // 1件だけオブジェクトで返った場合
        return []
    }
    static func obj(_ a: Any?) -> [String: Any]? { decoded(a) as? [String: Any] }
    static func list(_ a: Any?) -> [Any] { decoded(a) as? [Any] ?? [] }
    static func num(_ a: Any?) -> Double? {
        if let n = a as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let s = a as? String {
            let cleaned = s.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " tTφΦmMR"))
            return Double(cleaned)
        }
        return nil
    }
}
