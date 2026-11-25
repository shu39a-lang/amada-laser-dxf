import Foundation

/// AutoCAD R12 形式(AC1009)のASCII DXF。LINE / ARC / CIRCLE だけを使う(古いCAM・アマダ系ソフトでも読める形)
enum DXFWriter {
    static func dxf(_ b: BuiltPart, includeBendLayer: Bool) -> String {
        var e: [String] = []
        func g(_ code: Int, _ v: String) { e.append(String(code)); e.append(v) }
        func n(_ v: Double) -> String { String(format: "%.4f", v) }

        // HEADER
        g(0, "SECTION"); g(2, "HEADER")
        g(9, "$ACADVER"); g(1, "AC1009")
        g(9, "$EXTMIN"); g(10, n(0)); g(20, n(0)); g(30, n(0))
        g(9, "$EXTMAX"); g(10, n(b.width)); g(20, n(b.height)); g(30, n(0))
        g(0, "ENDSEC")

        // TABLES
        g(0, "SECTION"); g(2, "TABLES")
        g(0, "TABLE"); g(2, "LTYPE"); g(70, "1")
        g(0, "LTYPE"); g(2, "CONTINUOUS"); g(70, "0"); g(3, "Solid line"); g(72, "65"); g(73, "0"); g(40, n(0))
        g(0, "ENDTAB")
        let layers: [(String, Int)] = includeBendLayer ? [("0", 7), ("CUT", 7), ("BEND", 1)] : [("0", 7), ("CUT", 7)]
        g(0, "TABLE"); g(2, "LAYER"); g(70, String(layers.count))
        for (name, color) in layers {
            g(0, "LAYER"); g(2, name); g(70, "0"); g(62, String(color)); g(6, "CONTINUOUS")
        }
        g(0, "ENDTAB")
        g(0, "ENDSEC")

        // ENTITIES
        g(0, "SECTION"); g(2, "ENTITIES")
        func put(_ s: Seg, layer: String) {
            switch s {
            case .line(let a, let c):
                g(0, "LINE"); g(8, layer)
                g(10, n(a.x)); g(20, n(a.y)); g(30, n(0))
                g(11, n(c.x)); g(21, n(c.y)); g(31, n(0))
            case .arc(let c, let r, let s0, let e0):
                g(0, "ARC"); g(8, layer)
                g(10, n(c.x)); g(20, n(c.y)); g(30, n(0)); g(40, n(r))
                g(50, n(normDeg(s0))); g(51, n(normDeg(e0)))
            case .circle(let c, let r):
                g(0, "CIRCLE"); g(8, layer)
                g(10, n(c.x)); g(20, n(c.y)); g(30, n(0)); g(40, n(r))
            }
        }
        for s in b.outline { put(s, layer: "CUT") }
        for s in b.holes { put(s, layer: "CUT") }
        if includeBendLayer { for s in b.bendLines { put(s, layer: "BEND") } }
        g(0, "ENDSEC")
        g(0, "EOF")
        return e.joined(separator: "\r\n") + "\r\n"
    }

    static func normDeg(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        return x
    }
}

/// 板厚・材質ごとのまとめ書き出し
enum Exporter {
    struct Item: Identifiable {
        let drawing: DrawingRecord
        let part: Part
        var id: UUID { part.id }
    }

    struct ExportGroup: Identifiable {
        let key: String
        let items: [Item]
        var id: String { key }
    }

    static func groups(_ drawings: [DrawingRecord]) -> [ExportGroup] {
        var dict: [String: [Item]] = [:]
        for d in drawings {
            for p in d.parts where p.process == .laser {
                dict[p.groupKey, default: []].append(Item(drawing: d, part: p))
            }
        }
        return dict.keys.sorted().map { ExportGroup(key: $0, items: dict[$0] ?? []) }
    }

    struct ExportedFile: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let quantity: Int
        let built: BuiltPart
    }

    /// DXFファイルを一時フォルダに書き出す。失敗した部品は理由を返す
    static func export(items: [Item], settings: AppSettings) -> (urls: [URL], skipped: [String]) {
        let r = exportFiles(items: items, settings: settings)
        return (r.files.map(\.url), r.skipped)
    }

    static func exportFiles(items: [Item], settings: AppSettings) -> (files: [ExportedFile], skipped: [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dxf_" + stamp(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [ExportedFile] = []
        var skipped: [String] = []
        for it in items where it.part.include {
            let variants: [(Bool, String)] = it.part.mirrorPair ? [(false, ""), (true, "_MIRROR")] : [(false, "")]
            for (mir, suffix) in variants {
                let built = Geometry.build(part: it.part, settings: settings, mirrored: mir)
                if !built.blocking.isEmpty {
                    skipped.append("\(it.drawing.drawingNumber) \(it.part.partKey) \(it.part.name): \(built.blocking.joined(separator: "、"))")
                    break
                }
                let name = fileName(it, suffix: suffix, ascii: settings.asciiFileNames)
                let url = dir.appendingPathComponent(name)
                let text = DXFWriter.dxf(built, includeBendLayer: settings.includeBendLayer)
                if (try? text.data(using: .ascii, allowLossyConversion: true)?.write(to: url)) != nil {
                    let title = "\(it.part.partKey) \(it.part.name)" + (mir ? "(勝手違い)" : "")
                    files.append(ExportedFile(url: url, title: title, quantity: it.part.quantity, built: built))
                }
            }
        }
        return (files, skipped)
    }

    static func fileName(_ it: Item, suffix: String, ascii: Bool) -> String {
        let p = it.part
        let mat = asciiOnly(p.material.isEmpty ? "MAT" : p.material)
        let t = p.thickness.map { "t" + Fmt.num($0) } ?? "t-"
        let dwg = asciiOnly(it.drawing.drawingNumber.isEmpty ? "DWG" : it.drawing.drawingNumber)
        var base = "\(mat)_\(t)_\(dwg)_\(p.partKey)\(suffix)_x\(p.quantity)"
        if !ascii { base += "_" + safe(p.name) }
        return base + ".dxf"
    }

    static func asciiOnly(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return mapped.isEmpty ? "X" : mapped
    }

    static func safe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>| ")).joined(separator: "-")
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
