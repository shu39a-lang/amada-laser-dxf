import Foundation

/// 描画・DXF出力用の線分
enum Seg: Hashable {
    case line(P2, P2)
    /// 中心・半径・始点角・終点角(度)。DXFと同じく常に反時計回り(start→end)
    case arc(center: P2, r: Double, startDeg: Double, endDeg: Double)
    case circle(center: P2, r: Double)
}

struct HoleLabel: Hashable {
    var pos: P2
    var text: String
    var position: String
    /// v2.9: 穴を囲む四角の大きさ(mm、穴の外形の幅・高さ)
    var boxW: Double = 0
    var boxH: Double = 0
    /// v2.9: 写真の中の位置(何枚目、幅・高さに対する割合 0〜1)。無ければ nil
    var photoNo: Int? = nil
    var photo: P2? = nil
    /// v3.0: 推定した穴(要確認)の理由
    var check: String? = nil
}

/// v3.0: 推定した所(オレンジで表示する)
struct CheckMark: Hashable {
    var pos: P2
    var note: String
}

struct BuiltPart {
    var holeLabels: [HoleLabel] = []
    var outline: [Seg] = []
    var holes: [Seg] = []
    /// 曲げ線(参考)
    var bendLines: [Seg] = []
    var width: Double = 0
    var height: Double = 0
    var warnings: [String] = []
    var blocking: [String] = []   // これがあるとDXFを出さない
    /// v3.0: 推定した頂点・穴の位置と理由
    var checkMarks: [CheckMark] = []
    /// v3.0: 推定した穴の線(オレンジで重ね描き)
    var checkHoles: [Seg] = []
}

enum Geometry {

    // MARK: - 部品 → 展開済みの線分

    static func build(part: Part, settings: AppSettings, mirrored: Bool = false) -> BuiltPart {
        var out = BuiltPart()
        guard var f = part.flat else {
            out.blocking.append(part.readError ?? "展開形状がまだありません")
            return out
        }
        if part.thickness == nil { out.blocking.append("板厚が未確定です") }

        // v3.3: 前板+側壁 → 平らな外形に直してから、下の共通処理へ
        if f.developedBy == .plateWalls {
            guard let pm = f.plate else { out.blocking.append("前板と側壁のデータがありません"); return out }
            guard let t = part.thickness else { return out }
            guard let row = settings.deduction(material: part.material, thickness: t) else {
                out.blocking.append("控除表に \(materialGroup(part.material)) t\(Fmt.num(t)) がありません(設定で追加してください)")
                return out
            }
            if row.provisional { out.warnings.append("控除値が仮値です(\(row.materialGroup) t\(Fmt.num(t)) = \(Fmt.num(row.value90))mm)。設定で会社の表に直してください") }
            var w: [String] = []
            let r = PlateBuilder.flatten(pm, thickness: t, deduction90: row.value90, warnings: &w)
            out.warnings += w
            f.outline = r.outline
            f.holes = r.holes
            f.bends = r.bends
            f.keyDimensions = []        // 外寸の合計は展開後の大きさと違うので照合しない
            f.developedBy = .flat
            if f.outline.count < 3 { out.blocking.append("前板と側壁から外形を作れませんでした"); return out }
        }

        if f.developedBy == .faces {
            // 面モデル → 展開(v2.6)。控除・角の逃げ・切欠きはすべてアプリ側で計算する
            guard let fm = f.faces else { out.blocking.append("曲げ部品の面データがありません"); return out }
            guard let t = part.thickness else { return out }
            guard let row = settings.deduction(material: part.material, thickness: t) else {
                out.blocking.append("控除表に \(materialGroup(part.material)) t\(Fmt.num(t)) がありません(設定で追加してください)")
                return out
            }
            if row.provisional { out.warnings.append("控除値が仮値です(\(row.materialGroup) t\(Fmt.num(t)) = \(Fmt.num(row.value90))mm)。設定で会社の表に直してください") }
            var w: [String] = []
            let r = FaceBuilder.flatten(fm, thickness: t, deduction90: row.value90, warnings: &w)
            out.warnings += w
            for k in f.keyDimensions {
                let actual: Double? = k.axis == "x" ? r.outerW : (k.axis == "y" ? r.outerH : nil)
                if let a = actual, abs(a - k.value) > 0.6 {
                    out.warnings.append("全体寸法の不一致: \(k.label) 図面\(Fmt.num(k.value)) / 面の外寸合計\(Fmt.num(a))")
                }
            }
            f.outline = r.outline
            f.holes = r.holes
            f.bends = r.bends
            f.developedBy = .flat
            if f.outline.count < 3 { out.blocking.append("面のデータから外形を作れませんでした"); return out }
        } else {
        if f.outline.count < 3 { out.blocking.append("外形の頂点が3つ未満です"); return out }

        // 1) 展開前のサイズ確認(AIの検算)
        //  v2.9: 円弧のふくらみも含めて測る(頂点だけで測ると長円の板の縦が短く出ていた)
        let pre = outlineBBox(f.outline)
        for k in f.keyDimensions {
            let actual: Double? = k.axis == "x" ? pre.w : (k.axis == "y" ? pre.h : nil)
            if let a = actual, abs(a - k.value) > 0.6 {
                out.warnings.append("全体寸法の不一致: \(k.label) 図面\(Fmt.num(k.value)) / 外形\(Fmt.num(a))")
            }
        }
        // 円弧・斜め辺のある板(長円カバー等)は外寸並べが正しい方式。長方形だけの箱形のときだけ知らせる
        var hasCurveOrSlant = false
        for i in 0..<f.outline.count {
            let a = f.outline[i], b = f.outline[(i + 1) % f.outline.count]
            if a.arcToNext != nil || (abs(a.x - b.x) > 0.01 && abs(a.y - b.y) > 0.01) { hasCurveOrSlant = true; break }
        }
        if f.developedBy == .outerDims && !f.bends.isEmpty && !hasCurveOrSlant {
            out.warnings.append("旧方式(外寸並べ)の展開です。箱形の角の寸法がずれることがあります。「指示して読み直す」で新方式になります")
        }

        // 2) 曲げ控除
        if f.developedBy == .outerDims && !f.bends.isEmpty {
            if let t = part.thickness {
                if let row = settings.deduction(material: part.material, thickness: t) {
                    if row.provisional { out.warnings.append("控除値が仮値です(\(row.materialGroup) t\(Fmt.num(t)) = \(Fmt.num(row.value90))mm)。設定で会社の表に直してください") }
                    f = unfold(f, deduction90: row.value90, warnings: &out.warnings)
                } else {
                    out.blocking.append("控除表に \(materialGroup(part.material)) t\(Fmt.num(t)) がありません(設定で追加してください)")
                }
            }
        }
        }

        // 3) 原点を左下に合わせる
        //  v2.9: 頂点だけでなく円弧のふくらみも含めた範囲で合わせる。
        //  v2.8までは頂点だけで測っていたため、円弧の端の部品(長円の板など)は
        //  円弧が原点より下・はみ出した位置に描かれ、展開寸法(縦)も短く表示されていた(DXFも同じ)
        let b = outlineBBox(f.outline)
        f = translate(f, dx: -b.minX, dy: -b.minY)
        if mirrored { f = mirror(f, width: b.w) }

        out.width = b.w
        out.height = b.h
        var warns = out.warnings
        let outlineSegs = polygonSegments(f.outline, warnings: &warns)
        var holeSegs: [Seg] = []
        for h in f.holes { holeSegs += holeSegments(h, warnings: &warns) }
        out.outline = outlineSegs
        out.holes = holeSegs
        out.warnings = warns
        for bd in f.bends {
            if bd.axis == .x { out.bendLines.append(.line(P2(x: bd.position, y: bd.from ?? 0), P2(x: bd.position, y: bd.to ?? b.h))) }
            else { out.bendLines.append(.line(P2(x: bd.from ?? 0, y: bd.position), P2(x: bd.to ?? b.w, y: bd.position))) }
        }

        out.holeLabels = f.holes.map { h in
            let c = holeCenter(h)
            let t: String
            switch h.type {
            case .circle: t = "φ" + Fmt.num(h.d)
            case .slot: t = "長穴" + Fmt.num(h.width) + "×" + Fmt.num(dist(P2(x: h.x1, y: h.y1), P2(x: h.x2, y: h.y2)) + h.width)
            case .rect: t = "□" + Fmt.num(h.w) + "×" + Fmt.num(h.h)
            case .polygon: t = "異形"
            }
            var dummy: [String] = []
            let hb = bbox(of: extremePoints(holeSegments(h, warnings: &dummy)))
            var label = HoleLabel(pos: c, text: t, position: "(\(Fmt.num(c.x)), \(Fmt.num(c.y)))")
            label.boxW = max(hb.w, 2)
            label.boxH = max(hb.h, 2)
            if let no = h.photoNo, let px = h.photoX, let py = h.photoY {
                label.photoNo = no
                label.photo = P2(x: px, y: py)
            }
            label.check = h.check
            return label
        }

        // v3.0: 推定した所(頂点・穴)
        for v in f.outline {
            if let c = v.check, !c.isEmpty { out.checkMarks.append(CheckMark(pos: P2(x: v.x, y: v.y), note: c)) }
        }
        for h in f.holes {
            if let c = h.check, !c.isEmpty {
                out.checkMarks.append(CheckMark(pos: holeCenter(h), note: c))
                var dummy: [String] = []
                out.checkHoles += holeSegments(h, warnings: &dummy)
            }
        }

        // 4) 穴が外形の中にあるか
        let poly = sampled(out.outline)
        for (i, h) in f.holes.enumerated() {
            let c = holeCenter(h)
            if !pointInPolygon(c, poly) { out.warnings.append("穴\(i + 1)(\(h.type.label))が外形の外にあります") }
        }
        for i in 0..<f.holes.count {
            for j in (i + 1)..<max(i + 1, f.holes.count) where f.holes[i].type == .circle && f.holes[j].type == .circle {
                if dist(holeCenter(f.holes[i]), holeCenter(f.holes[j])) < 0.3 { out.warnings.append("穴\(i + 1)と穴\(j + 1)が重なっています") }
            }
        }
        // v2.9: 部品一覧では曲げがあるのに、展開に曲げ線が無い
        if part.bendsCount > 0 && out.bendLines.isEmpty {
            out.warnings.append("部品一覧では曲げが\(part.bendsCount)か所ありますが、展開に曲げ線がありません。フランジが抜けていないか確認してください(「指示して読み直す」で読み直せます)")
        }
        if !f.uncertain.isEmpty { out.warnings += f.uncertain.map { "AI確認事項: " + $0 } }
        return out
    }

    /// v2.9: 外形の範囲(円弧のふくらみ・角のRも含む)
    static func outlineBBox(_ vs: [OutlineVertex]) -> BBox {
        var dummy: [String] = []
        let pts = extremePoints(polygonSegments(vs, warnings: &dummy))
        return pts.isEmpty ? bbox(of: polygonPoints(vs)) : bbox(of: pts)
    }

    /// 線分の端点と、円弧の上下左右の一番外側の点(範囲をぴったり測るため)
    static func extremePoints(_ segs: [Seg]) -> [P2] {
        var pts: [P2] = []
        for sg in segs {
            switch sg {
            case .line(let a, let b):
                pts.append(a); pts.append(b)
            case .arc(let c, let r, let s0, let e0):
                var e = e0
                while e <= s0 { e += 360 }
                for a in [s0, e] {
                    let t = a * .pi / 180
                    pts.append(P2(x: c.x + r * cos(t), y: c.y + r * sin(t)))
                }
                // 始点〜終点(反時計回り)の間にある 0°・90°・180°・270°
                var k = (s0 / 90).rounded(.up) * 90
                while k < e {
                    let t = k * .pi / 180
                    pts.append(P2(x: c.x + r * cos(t), y: c.y + r * sin(t)))
                    k += 90
                }
            case .circle(let c, let r):
                pts += [P2(x: c.x - r, y: c.y - r), P2(x: c.x + r, y: c.y + r)]
            }
        }
        return pts
    }

    // MARK: - 曲げ控除(外寸合算座標 → 展開座標)

    static func unfold(_ f: FlatPattern, deduction90: Double, warnings: inout [String]) -> FlatPattern {
        func ded(_ b: Bend) -> Double {
            let a = b.angleDeg <= 0 ? 90 : b.angleDeg
            return deduction90 * a / 90
        }
        for b in f.bends where b.angleDeg > 0 && abs(b.angleDeg - 90) > 0.5 {
            warnings.append("\(Fmt.num(b.angleDeg))°曲げは90°の控除値から比例計算しています(要確認)")
        }
        let xs = f.bends.filter { $0.axis == .x }.sorted { $0.position < $1.position }
        let ys = f.bends.filter { $0.axis == .y }.sorted { $0.position < $1.position }
        let xd = xs.map { ($0.position, ded($0)) }
        let yd = ys.map { ($0.position, ded($0)) }
        // v2.7: 曲げ線の上の点(外寸の角)は、展開後の曲げ線の位置(控除の半分だけ手前)に寄せる。
        //  v2.6までは曲げ線上の点が動かず、長円の板の円弧の端とフランジの角が2mmほど食い違って外形が壊れていた
        func shift(_ v: Double, _ list: [(Double, Double)]) -> Double {
            var s = v
            for (pos, d) in list {
                if pos < v - 0.001 { s -= d }
                else if abs(pos - v) <= 0.001 { s -= d / 2 }
            }
            return s
        }
        func sx(_ x: Double) -> Double { shift(x, xd) }
        func sy(_ y: Double) -> Double { shift(y, yd) }
        func sp(_ p: P2) -> P2 { P2(x: sx(p.x), y: sy(p.y)) }

        var g = f
        g.outline = f.outline.map { v in
            var n = v
            n.x = sx(v.x); n.y = sy(v.y)
            if let a = v.arcToNext { n.arcToNext = ArcSpec(cx: sx(a.cx), cy: sy(a.cy), clockwise: a.clockwise) }
            return n
        }
        // 円弧が曲げ線をまたぐと半径が合わなくなるので知らせる
        let n0 = f.outline.count
        for i in 0..<n0 {
            guard let a = g.outline[i].arcToNext else { continue }
            let c = P2(x: a.cx, y: a.cy)
            let p = P2(x: g.outline[i].x, y: g.outline[i].y)
            let q = P2(x: g.outline[(i + 1) % n0].x, y: g.outline[(i + 1) % n0].y)
            if abs(dist(c, p) - dist(c, q)) > 0.05 {
                warnings.append("頂点\(i + 1)の円弧が曲げ線にかかっています(展開後の半径 \(Fmt.num(dist(c, p))) / \(Fmt.num(dist(c, q))))。逃げ・形を確認してください")
            }
        }
        g.holes = f.holes.map { h in
            var n = h
            let c = sp(P2(x: h.cx, y: h.cy)); n.cx = c.x; n.cy = c.y
            let p1 = sp(P2(x: h.x1, y: h.y1)); n.x1 = p1.x; n.y1 = p1.y
            let p2 = sp(P2(x: h.x2, y: h.y2)); n.x2 = p2.x; n.y2 = p2.y
            n.points = h.points.map(sp)
            return n
        }
        g.bends = f.bends.map { b in
            var n = b
            // 曲げ線上の点として寄せる(shift が控除の半分を引く)
            n.position = b.axis == .x ? sx(b.position) : sy(b.position)
            // 曲げ線の範囲(縦線ならY、横線ならX)も展開座標に直す
            if b.axis == .x { n.from = b.from.map(sy); n.to = b.to.map(sy) }
            else { n.from = b.from.map(sx); n.to = b.to.map(sx) }
            return n
        }
        g.developedBy = .flat
        return g
    }

    static func translate(_ f: FlatPattern, dx: Double, dy: Double) -> FlatPattern {
        var g = f
        g.outline = f.outline.map { v in
            var n = v; n.x += dx; n.y += dy
            if let a = v.arcToNext { n.arcToNext = ArcSpec(cx: a.cx + dx, cy: a.cy + dy, clockwise: a.clockwise) }
            return n
        }
        g.holes = f.holes.map { h in
            var n = h
            n.cx += dx; n.cy += dy; n.x1 += dx; n.y1 += dy; n.x2 += dx; n.y2 += dy
            n.points = h.points.map { P2(x: $0.x + dx, y: $0.y + dy) }
            return n
        }
        g.bends = f.bends.map { b in
            var n = b
            n.position += (b.axis == .x ? dx : dy)
            let along = b.axis == .x ? dy : dx
            n.from = b.from.map { $0 + along }
            n.to = b.to.map { $0 + along }
            return n
        }
        return g
    }

    /// 左右反転(勝手違い)。外形の回転方向を保つため頂点順も逆にする
    static func mirror(_ f: FlatPattern, width: Double) -> FlatPattern {
        var g = f
        let n = f.outline.count
        var verts: [OutlineVertex] = []
        for k in 0..<n {
            // 反転後は順番を逆にする。元の辺 i→i+1 の円弧は、新しい辺 (i+1)'→i' になる
            let i = (n - k) % n
            var v = f.outline[i]
            v.x = width - v.x
            let prevIdx = (i - 1 + n) % n
            if let a = f.outline[prevIdx].arcToNext {
                v.arcToNext = ArcSpec(cx: width - a.cx, cy: a.cy, clockwise: a.clockwise)
            } else {
                v.arcToNext = nil
            }
            verts.append(v)
        }
        g.outline = verts
        g.holes = f.holes.map { h in
            var m = h
            m.cx = width - h.cx; m.x1 = width - h.x1; m.x2 = width - h.x2
            m.angle = -h.angle
            m.points = h.points.reversed().map { P2(x: width - $0.x, y: $0.y) }
            return m
        }
        g.bends = f.bends.map { b in
            var m = b
            if b.axis == .x {
                m.position = width - b.position
            } else {
                m.from = b.to.map { width - $0 }
                m.to = b.from.map { width - $0 }
            }
            return m
        }
        return g
    }

    // MARK: - 外形(角の面取り・R・円弧辺)

    static func polygonSegments(_ vs: [OutlineVertex], warnings: inout [String]) -> [Seg] {
        let n = vs.count
        guard n >= 3 else { return [] }
        let pts = vs.map { P2(x: $0.x, y: $0.y) }
        var entry = pts, exit = pts
        var cornerSegs: [Seg?] = Array(repeating: nil, count: n)

        for i in 0..<n {
            let v = vs[i]
            let prevI = (i - 1 + n) % n
            guard v.cornerType != .none, v.cornerSize > 0 else { continue }
            if vs[prevI].arcToNext != nil || v.arcToNext != nil {
                warnings.append("頂点\(i + 1): 円弧の辺と面取り/Rが重なるため角処理を省略")
                continue
            }
            let p = pts[i], a = pts[prevI], c = pts[(i + 1) % n]
            let u = norm(sub(a, p)), w = norm(sub(c, p))
            let lenA = dist(a, p), lenC = dist(c, p)
            let cosPhi = max(-1, min(1, dot(u, w)))
            let phi = acos(cosPhi)
            if phi < 0.01 || phi > .pi - 0.01 { continue }
            var dd: Double
            if v.cornerType == .chamfer {
                dd = v.cornerSize
            } else {
                dd = v.cornerSize / tan(phi / 2)
            }
            let maxD = min(lenA, lenC) * 0.5
            if dd > maxD {
                warnings.append("頂点\(i + 1): \(v.cornerType.label)\(Fmt.num(v.cornerSize))が辺より大きいため縮小")
                dd = maxD
            }
            let p1 = add(p, mul(u, dd)), p2 = add(p, mul(w, dd))
            entry[i] = p1; exit[i] = p2
            if v.cornerType == .chamfer {
                cornerSegs[i] = .line(p1, p2)
            } else {
                let r = dd * tan(phi / 2)
                let center = add(p, mul(norm(add(u, w)), r / sin(phi / 2)))
                let din = sub(p, a), dout = sub(c, p)
                let ccw = cross(din, dout) > 0
                cornerSegs[i] = arcSeg(center: center, from: p1, to: p2, ccw: ccw)
            }
        }

        var segs: [Seg] = []
        for i in 0..<n {
            if let cs = cornerSegs[i] { segs.append(cs) }
            let j = (i + 1) % n
            let s = exit[i], e = entry[j]
            if let arc = vs[i].arcToNext {
                segs.append(arcSeg(center: P2(x: arc.cx, y: arc.cy), from: s, to: e, ccw: !arc.clockwise))
            } else if dist(s, e) > 1e-6 {
                segs.append(.line(s, e))
            }
        }
        return segs
    }

    static func arcSeg(center: P2, from s: P2, to e: P2, ccw: Bool) -> Seg {
        let r = dist(center, s)
        let a1 = deg(atan2(s.y - center.y, s.x - center.x))
        let a2 = deg(atan2(e.y - center.y, e.x - center.x))
        return ccw ? .arc(center: center, r: r, startDeg: a1, endDeg: a2)
                   : .arc(center: center, r: r, startDeg: a2, endDeg: a1)
    }

    // MARK: - 穴

    static func holeSegments(_ h: Hole, warnings: inout [String]) -> [Seg] {
        switch h.type {
        case .circle:
            guard h.d > 0 else { warnings.append("径0の丸穴を除外"); return [] }
            return [.circle(center: P2(x: h.cx, y: h.cy), r: h.d / 2)]
        case .slot:
            let p1 = P2(x: h.x1, y: h.y1), p2 = P2(x: h.x2, y: h.y2), r = h.width / 2
            guard r > 0 else { warnings.append("幅0の長穴を除外"); return [] }
            if dist(p1, p2) < 1e-6 { return [.circle(center: p1, r: r)] }
            let d = norm(sub(p2, p1)), nrm = P2(x: -d.y * r, y: d.x * r)
            return [
                .line(add(p1, nrm), add(p2, nrm)),
                arcSeg(center: p2, from: add(p2, nrm), to: sub(p2, nrm), ccw: false),
                .line(sub(p2, nrm), sub(p1, nrm)),
                arcSeg(center: p1, from: sub(p1, nrm), to: add(p1, nrm), ccw: false)
            ]
        case .rect:
            guard h.w > 0, h.h > 0 else { warnings.append("サイズ0の角穴を除外"); return [] }
            let t = h.angle * .pi / 180
            let corners = [(-h.w / 2, -h.h / 2), (h.w / 2, -h.h / 2), (h.w / 2, h.h / 2), (-h.w / 2, h.h / 2)].map { c in
                OutlineVertex(x: h.cx + c.0 * cos(t) - c.1 * sin(t),
                              y: h.cy + c.0 * sin(t) + c.1 * cos(t),
                              cornerType: h.cornerR > 0 ? .radius : .none,
                              cornerSize: h.cornerR)
            }
            return polygonSegments(corners, warnings: &warnings)
        case .polygon:
            guard h.points.count >= 3 else { warnings.append("頂点不足の多角形穴を除外"); return [] }
            return polygonSegments(h.points.map { OutlineVertex(x: $0.x, y: $0.y) }, warnings: &warnings)
        }
    }

    static func holeCenter(_ h: Hole) -> P2 {
        switch h.type {
        case .circle, .rect: return P2(x: h.cx, y: h.cy)
        case .slot: return P2(x: (h.x1 + h.x2) / 2, y: (h.y1 + h.y2) / 2)
        case .polygon:
            guard !h.points.isEmpty else { return P2(x: 0, y: 0) }
            let n = Double(h.points.count)
            return P2(x: h.points.map(\.x).reduce(0, +) / n, y: h.points.map(\.y).reduce(0, +) / n)
        }
    }

    // MARK: - 補助

    static func polygonPoints(_ vs: [OutlineVertex]) -> [P2] { vs.map { P2(x: $0.x, y: $0.y) } }

    struct BBox { var minX, minY, maxX, maxY: Double; var w: Double { maxX - minX }; var h: Double { maxY - minY } }

    static func bbox(of pts: [P2]) -> BBox {
        guard let f = pts.first else { return BBox(minX: 0, minY: 0, maxX: 0, maxY: 0) }
        var b = BBox(minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for p in pts { b.minX = min(b.minX, p.x); b.minY = min(b.minY, p.y); b.maxX = max(b.maxX, p.x); b.maxY = max(b.maxY, p.y) }
        return b
    }

    /// 円弧を細かい点に(プレビュー・内外判定用)
    static func sampled(_ segs: [Seg]) -> [P2] {
        var pts: [P2] = []
        for s in segs {
            switch s {
            case .line(let a, let b): pts.append(a); pts.append(b)
            case .arc(let c, let r, let s0, let e0):
                var e = e0; while e <= s0 { e += 360 }
                // 円弧の向きは start→end(反時計回り)。外形の進行方向とは逆の場合があるが、内外判定では点の集合として扱う
                let steps = max(4, Int((e - s0) / 10))
                var arcPts: [P2] = []
                for k in 0...steps {
                    let a = (s0 + (e - s0) * Double(k) / Double(steps)) * .pi / 180
                    arcPts.append(P2(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                }
                if let last = pts.last, let f = arcPts.first, let l = arcPts.last, dist(last, l) < dist(last, f) {
                    arcPts.reverse()
                }
                pts += arcPts
            case .circle(let c, let r):
                for k in 0..<36 {
                    let a = Double(k) * 10 * .pi / 180
                    pts.append(P2(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                }
            }
        }
        return pts
    }

    static func pointInPolygon(_ p: P2, _ poly: [P2]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func add(_ a: P2, _ b: P2) -> P2 { P2(x: a.x + b.x, y: a.y + b.y) }
    static func sub(_ a: P2, _ b: P2) -> P2 { P2(x: a.x - b.x, y: a.y - b.y) }
    static func mul(_ a: P2, _ k: Double) -> P2 { P2(x: a.x * k, y: a.y * k) }
    static func dot(_ a: P2, _ b: P2) -> Double { a.x * b.x + a.y * b.y }
    static func cross(_ a: P2, _ b: P2) -> Double { a.x * b.y - a.y * b.x }
    static func dist(_ a: P2, _ b: P2) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func norm(_ a: P2) -> P2 { let l = hypot(a.x, a.y); return l < 1e-12 ? a : P2(x: a.x / l, y: a.y / l) }
    static func deg(_ r: Double) -> Double { r * 180 / .pi }
}

// MARK: - 面モデル(基準面+フランジ)→ 展開形状  v2.6
//
// 考え方(基準面の外寸の左下を原点、外側を手前にして X右・Y上):
//  ・基準面上の点は外寸の座標のまま。曲げ線は外形線から「控除値の半分」内側に入る
//  ・フランジは辺から外へ並べる。外へ向かう距離 u = Σ(外寸 − 控除値) − (先端からの距離)
//  ・左右のフランジは基準面の曲げ線の範囲に縮め、角には逃げ(四角)を入れる
//  ・外形は長方形の和集合を格子で求め、そのあと角のR・C、辺の切欠き(U溝)を足す

enum FaceBuilder {
    struct Result {
        var outline: [OutlineVertex] = []
        var holes: [Hole] = []
        var bends: [Bend] = []
        /// 外寸の合計(展開前の全体寸法。AIの key_dimensions と照合)
        var outerW: Double = 0
        var outerH: Double = 0
    }

    struct Rect { var x0, y0, x1, y1: Double }

    static func flatten(_ fm: FaceModel, thickness t: Double, deduction90: Double, warnings: inout [String]) -> Result {
        var res = Result()
        let W = fm.width, H = fm.height
        guard W > 0, H > 0 else { warnings.append("基準面の寸法がありません"); return res }

        var byID: [String: FaceFlange] = [:]
        for f in fm.flanges { byID[f.id] = f }

        func ded(_ f: FaceFlange) -> Double {
            let a = f.angleDeg <= 0 ? 90 : f.angleDeg
            return deduction90 * a / 90
        }
        func len(_ f: FaceFlange) -> Double { f.length + (f.lengthInner ? t : 0) }
        /// 基準面から f までのフランジの列
        func chain(_ f: FaceFlange) -> [FaceFlange] {
            var c = [f]
            var cur = f
            var guardCount = 0
            while cur.parent != "base", let p = byID[cur.parent], guardCount < 20 {
                c.insert(p, at: 0); cur = p; guardCount += 1
            }
            return c
        }
        func edgeOf(_ f: FaceFlange) -> String { chain(f).first?.edge ?? "bottom" }
        func child(_ f: FaceFlange) -> FaceFlange? { fm.flanges.first { $0.parent == f.id } }
        func firstOn(_ e: String) -> FaceFlange? { fm.flanges.first { $0.parent == "base" && $0.edge == e } }

        for f in fm.flanges where f.parent != "base" && byID[f.parent] == nil {
            warnings.append("フランジ\(f.id)の親「\(f.parent)」が見つかりません")
        }
        for f in fm.flanges where f.angleDeg > 0 && abs(f.angleDeg - 90) > 0.5 {
            warnings.append("\(f.name.isEmpty ? f.id : f.name): \(Fmt.num(f.angleDeg))°曲げは90°の控除値から比例計算しています(要確認)")
        }

        let fb = firstOn("bottom"), ft = firstOn("top"), fl = firstOn("left"), fr = firstOn("right")
        let dB = fb.map(ded) ?? 0, dT = ft.map(ded) ?? 0, dL = fl.map(ded) ?? 0, dR = fr.map(ded) ?? 0
        // 基準面の平らな範囲(曲げ線〜曲げ線、自由な辺は外形のまま)
        let bx0 = fl != nil ? dL / 2 : 0
        let bx1 = fr != nil ? W - dR / 2 : W
        let by0 = fb != nil ? dB / 2 : 0
        let by1 = ft != nil ? H - dT / 2 : H

        /// (内側の曲げ線の u, 外側の端の u, 累積 C)
        func uRange(_ f: FaceFlange) -> (uin: Double, uout: Double, c: Double) {
            var c = 0.0, uin = 0.0
            for g in chain(f) {
                uin = c - ded(g) / 2
                c += len(g) - ded(g)
            }
            let uout = c - (child(f).map { ded($0) / 2 } ?? 0)
            return (uin, uout, c)
        }
        func declaredRange(_ f: FaceFlange) -> (Double, Double) {
            let e = edgeOf(f)
            let full = (e == "left" || e == "right") ? H : W
            return (f.start ?? 0, f.end ?? full)
        }
        /// 実際に使う範囲(左右のフランジは基準面の曲げ線の間に縮める)
        func alongRange(_ f: FaceFlange) -> (Double, Double) {
            var (lo, hi) = declaredRange(f)
            let e = edgeOf(f)
            if e == "left" || e == "right" { lo = max(lo, by0); hi = min(hi, by1) }
            return (lo, hi)
        }
        func mapEdge(_ e: String, _ a: Double, _ u: Double) -> P2 {
            switch e {
            case "top": return P2(x: a, y: H + u)
            case "left": return P2(x: -u, y: a)
            case "right": return P2(x: W + u, y: a)
            default: return P2(x: a, y: -u)
            }
        }
        /// 面の座標 (a, d) → 展開座標
        func facePoint(_ face: String, _ a: Double, _ d: Double) -> P2? {
            if face == "base" { return P2(x: a, y: d) }
            guard let f = byID[face] else { return nil }
            return mapEdge(edgeOf(f), a, uRange(f).c - d)
        }
        func isVertical(_ face: String) -> Bool {
            guard face != "base", let f = byID[face] else { return false }
            let e = edgeOf(f)
            return e == "left" || e == "right"
        }

        // 外寸の合計
        func chainLen(_ e: String) -> Double {
            var s = 0.0
            var cur = firstOn(e)
            var n = 0
            while let c = cur, n < 20 { s += len(c); cur = child(c); n += 1 }
            return s
        }
        res.outerW = W + chainLen("left") + chainLen("right")
        res.outerH = H + chainLen("bottom") + chainLen("top")

        // 1) 長方形を集める
        var inc: [Rect] = [Rect(x0: bx0, y0: by0, x1: bx1, y1: by1)]
        for f in fm.flanges where f.parent == "base" || byID[f.parent] != nil {
            let e = edgeOf(f)
            let r = uRange(f)
            let (lo, hi) = alongRange(f)
            guard hi - lo > 0.01, r.uout - r.uin > 0.01 else {
                warnings.append("\(f.name.isEmpty ? f.id : f.name): 寸法が小さすぎるため省略")
                continue
            }
            let p1 = mapEdge(e, lo, r.uin), p2 = mapEdge(e, hi, r.uout)
            inc.append(Rect(x0: min(p1.x, p2.x), y0: min(p1.y, p2.y), x1: max(p1.x, p2.x), y1: max(p1.y, p2.y)))
            // 曲げ線(1段目は基準面の平らな範囲に合わせる)
            var blo = lo, bhi = hi
            if f.parent == "base" {
                if e == "bottom" || e == "top" { blo = max(lo, bx0); bhi = min(hi, bx1) }
            }
            let q1 = mapEdge(e, blo, r.uin), q2 = mapEdge(e, bhi, r.uin)
            var bend = Bend()
            if e == "left" || e == "right" {
                bend.axis = .x; bend.position = q1.x; bend.from = min(q1.y, q2.y); bend.to = max(q1.y, q2.y)
            } else {
                bend.axis = .y; bend.position = q1.y; bend.from = min(q1.x, q2.x); bend.to = max(q1.x, q2.x)
            }
            bend.angleDeg = f.angleDeg <= 0 ? 90 : f.angleDeg
            bend.up = f.up
            bend.note = f.name
            res.bends.append(bend)
        }

        // 2) 角の逃げ(隣り合う2辺にフランジがある角)
        var exc: [Rect] = []
        let corners: [(FaceFlange?, FaceFlange?, Double, Double)] = [
            (fb, fl, bx0, by0), (fb, fr, bx1, by0), (ft, fl, bx0, by1), (ft, fr, bx1, by1)
        ]
        for (a, b, cx, cy) in corners {
            guard let fa = a, let fbb = b else { continue }
            let s = max(ded(fa), ded(fbb)) / 2 + 0.5
            exc.append(Rect(x0: cx - s, y0: cy - s, x1: cx + s, y1: cy + s))
        }

        // 3) 外形(和集合)
        let loop = union(inc, minus: exc, warnings: &warnings)
        var verts = loop.map { OutlineVertex(x: $0.x, y: $0.y) }

        func setCorner(_ p: P2, _ c: FaceCorner) {
            if let i = verts.firstIndex(where: { abs($0.x - p.x) < 0.01 && abs($0.y - p.y) < 0.01 }) {
                verts[i].cornerType = c.type
                verts[i].cornerSize = c.size
            } else {
                warnings.append("角(\(c.at))の\(c.type.label)\(Fmt.num(c.size))をつける頂点が見つかりません")
            }
        }
        // フランジ先端の角
        for f in fm.flanges where child(f) == nil && !f.corners.isEmpty {
            let (lo, hi) = alongRange(f)
            let c = uRange(f).c
            for k in f.corners where k.size > 0 && k.type != .none {
                setCorner(mapEdge(edgeOf(f), k.at == "start" ? lo : hi, c), k)
            }
        }
        // 基準面の角(フランジの無い角だけ)
        for k in fm.baseCorners where k.size > 0 && k.type != .none {
            let p: P2
            switch k.at {
            case "bottom_right": p = P2(x: W, y: 0)
            case "top_left": p = P2(x: 0, y: H)
            case "top_right": p = P2(x: W, y: H)
            default: p = P2(x: 0, y: 0)
            }
            setCorner(p, k)
        }

        func insertNotch(_ ft: FaceFeature, into verts: inout [OutlineVertex], warnings: inout [String]) {
            guard ft.width > 0, ft.depth >= 0 else { warnings.append("切欠きの寸法が不正です"); return }
            let hw = ft.width / 2
            var m1: P2?, m2: P2?, ctr: P2?
            if ft.face == "base" {
                switch ft.edge {
                case "top":
                    m1 = P2(x: ft.center - hw, y: H); m2 = P2(x: ft.center + hw, y: H); ctr = P2(x: ft.center, y: H - ft.depth)
                case "left":
                    m1 = P2(x: 0, y: ft.center - hw); m2 = P2(x: 0, y: ft.center + hw); ctr = P2(x: ft.depth, y: ft.center)
                case "right":
                    m1 = P2(x: W, y: ft.center - hw); m2 = P2(x: W, y: ft.center + hw); ctr = P2(x: W - ft.depth, y: ft.center)
                default:
                    m1 = P2(x: ft.center - hw, y: 0); m2 = P2(x: ft.center + hw, y: 0); ctr = P2(x: ft.center, y: ft.depth)
                }
            } else if let f = byID[ft.face] {
                let (lo, hi) = alongRange(f)
                let (dlo, dhi) = declaredRange(f)
                switch ft.edge {
                case "start":
                    m1 = facePoint(f.id, lo, ft.center - hw); m2 = facePoint(f.id, lo, ft.center + hw)
                    ctr = facePoint(f.id, dlo + ft.depth, ft.center)
                case "end":
                    m1 = facePoint(f.id, hi, ft.center - hw); m2 = facePoint(f.id, hi, ft.center + hw)
                    ctr = facePoint(f.id, dhi - ft.depth, ft.center)
                default:
                    m1 = facePoint(f.id, ft.center - hw, 0); m2 = facePoint(f.id, ft.center + hw, 0)
                    ctr = facePoint(f.id, ft.center, ft.depth)
                }
            }
            guard let a1 = m1, let a2 = m2, let cc = ctr else { warnings.append("切欠きの面「\(ft.face)」が見つかりません"); return }
            if !placeNotch(&verts, a1, a2, cc, radius: hw, round: ft.roundEnd, mouthR: ft.mouthR) {
                warnings.append("切欠き(\(ft.face) 幅\(Fmt.num(ft.width)))を外形の辺に置けませんでした")
            }
        }

        // 4) 穴と切欠き
        for ft in fm.features {
            if ft.kind == "notch" {
                insertNotch(ft, into: &verts, warnings: &warnings)
                continue
            }
            var h = ft.hole
            let vert = isVertical(ft.face)
            switch h.type {
            case .circle, .rect:
                guard let c = facePoint(ft.face, h.cx, h.cy) else { warnings.append("穴の面「\(ft.face)」が見つかりません"); continue }
                h.cx = c.x; h.cy = c.y
                if vert && h.type == .rect { let w0 = h.w; h.w = h.h; h.h = w0 }
            case .slot:
                guard let p1 = facePoint(ft.face, h.x1, h.y1), let p2 = facePoint(ft.face, h.x2, h.y2) else {
                    warnings.append("長穴の面「\(ft.face)」が見つかりません"); continue
                }
                h.x1 = p1.x; h.y1 = p1.y; h.x2 = p2.x; h.y2 = p2.y
            case .polygon:
                h.points = h.points.compactMap { facePoint(ft.face, $0.x, $0.y) }
            }
            res.holes.append(h)
        }

        res.outline = verts
        return res
    }

    /// 外形の辺の上に U溝(丸端)/角溝を差し込む
    static func placeNotch(_ verts: inout [OutlineVertex], _ m1: P2, _ m2: P2, _ ctr: P2,
                           radius r: Double, round: Bool, mouthR: Double) -> Bool {
        let n = verts.count
        for i in 0..<n {
            let p = P2(x: verts[i].x, y: verts[i].y)
            let q = P2(x: verts[(i + 1) % n].x, y: verts[(i + 1) % n].y)
            if verts[i].arcToNext != nil { continue }
            let L = Geometry.dist(p, q)
            guard L > 1e-6 else { continue }
            let tx = (q.x - p.x) / L, ty = (q.y - p.y) / L
            func on(_ m: P2) -> (Bool, Double) {
                let cr = (m.x - p.x) * ty - (m.y - p.y) * tx
                let s = (m.x - p.x) * tx + (m.y - p.y) * ty
                return (abs(cr) < 0.01 && s > 0.01 && s < L - 0.01, s)
            }
            let (o1, s1) = on(m1), (o2, s2) = on(m2)
            guard o1, o2 else { continue }
            let a = s1 < s2 ? m1 : m2
            let e = s1 < s2 ? m2 : m1
            // 反時計回りの外形では、材料は進行方向の左側
            let nx = -ty, ny = tx
            let dep = (ctr.x - a.x) * nx + (ctr.y - a.y) * ny
            guard dep > -0.001 else { return false }
            let b = P2(x: a.x + nx * dep, y: a.y + ny * dep)
            let c = P2(x: e.x + nx * dep, y: e.y + ny * dep)
            let mid = P2(x: ctr.x + nx * r, y: ctr.y + ny * r)
            let cw = ((b.x - ctr.x) * (mid.y - ctr.y) - (b.y - ctr.y) * (mid.x - ctr.x)) < 0
            var va = OutlineVertex(x: a.x, y: a.y)
            var vb = OutlineVertex(x: b.x, y: b.y)
            let vc = OutlineVertex(x: c.x, y: c.y)
            var ve = OutlineVertex(x: e.x, y: e.y)
            if mouthR > 0 {
                va.cornerType = .radius; va.cornerSize = mouthR
                ve.cornerType = .radius; ve.cornerSize = mouthR
            }
            if round { vb.arcToNext = ArcSpec(cx: ctr.x, cy: ctr.y, clockwise: cw) }
            verts.insert(contentsOf: [va, vb, vc, ve], at: i + 1)
            return true
        }
        return false
    }

    // MARK: 長方形の和集合(格子法)→ 反時計回りの外形

    private struct GK: Hashable { let x: Int64; let y: Int64 }
    private static func key(_ x: Double, _ y: Double) -> GK { GK(x: Int64((x * 10000).rounded()), y: Int64((y * 10000).rounded())) }
    private static func val(_ k: GK) -> P2 { P2(x: Double(k.x) / 10000, y: Double(k.y) / 10000) }

    static func union(_ inc: [Rect], minus exc: [Rect], warnings: inout [String]) -> [P2] {
        func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        let all = inc + exc
        let xs = Array(Set(all.flatMap { [r4($0.x0), r4($0.x1)] })).sorted()
        let ys = Array(Set(all.flatMap { [r4($0.y0), r4($0.y1)] })).sorted()
        let nx = xs.count - 1, ny = ys.count - 1
        guard nx > 0, ny > 0 else { return [] }
        func inside(_ r: Rect, _ x: Double, _ y: Double) -> Bool { r.x0 < x && x < r.x1 && r.y0 < y && y < r.y1 }
        var cov = Array(repeating: Array(repeating: false, count: ny), count: nx)
        for i in 0..<nx {
            for j in 0..<ny {
                let cx = (xs[i] + xs[i + 1]) / 2, cy = (ys[j] + ys[j + 1]) / 2
                cov[i][j] = inc.contains(where: { inside($0, cx, cy) }) && !exc.contains(where: { inside($0, cx, cy) })
            }
        }
        func c(_ i: Int, _ j: Int) -> Bool { i >= 0 && i < nx && j >= 0 && j < ny && cov[i][j] }
        var edges: [GK: [GK]] = [:]
        func add(_ a: GK, _ b: GK) { edges[a, default: []].append(b) }
        for i in 0..<nx {
            for j in 0..<ny where cov[i][j] {
                let x0 = xs[i], x1 = xs[i + 1], y0 = ys[j], y1 = ys[j + 1]
                if !c(i, j - 1) { add(key(x0, y0), key(x1, y0)) }
                if !c(i + 1, j) { add(key(x1, y0), key(x1, y1)) }
                if !c(i, j + 1) { add(key(x1, y1), key(x0, y1)) }
                if !c(i - 1, j) { add(key(x0, y1), key(x0, y0)) }
            }
        }
        var loops: [[P2]] = []
        var safety = 0
        while let start = edges.keys.first, safety < 100 {
            safety += 1
            var loop: [GK] = [start]
            var cur = start
            var prev: GK? = nil
            var steps = 0
            while steps < 100000 {
                steps += 1
                guard var outs = edges[cur], !outs.isEmpty else { break }
                if outs.count > 1, let pv = prev {
                    // 左へ曲がる辺を優先(角だけで接する所で別の輪に分ける)
                    let dx = Double(cur.x - pv.x), dy = Double(cur.y - pv.y)
                    outs.sort { a, b in
                        let ca = dx * Double(a.y - cur.y) - dy * Double(a.x - cur.x)
                        let cb = dx * Double(b.y - cur.y) - dy * Double(b.x - cur.x)
                        return ca > cb
                    }
                }
                let nxt = outs.removeFirst()
                if outs.isEmpty { edges[cur] = nil } else { edges[cur] = outs }
                prev = cur
                cur = nxt
                if cur == start { break }
                loop.append(cur)
            }
            // 一直線上の点を除く
            let pts = loop.map(val)
            var merged: [P2] = []
            let m = pts.count
            for k in 0..<m {
                let a = pts[(k - 1 + m) % m], b = pts[k], d = pts[(k + 1) % m]
                let cr = (b.x - a.x) * (d.y - b.y) - (b.y - a.y) * (d.x - b.x)
                if abs(cr) > 1e-9 { merged.append(b) }
            }
            if merged.count >= 3 { loops.append(merged) }
        }
        func area(_ l: [P2]) -> Double {
            var s = 0.0
            for k in 0..<l.count { let a = l[(k - 1 + l.count) % l.count], b = l[k]; s += a.x * b.y - b.x * a.y }
            return s / 2
        }
        guard let best = loops.max(by: { area($0) < area($1) }) else { return [] }
        let outerCount = loops.filter { area($0) > 0.01 }.count
        if outerCount > 1 { warnings.append("展開形状が\(outerCount)つに分かれています(面のつながりを確認してください)") }
        return best
    }
}

// MARK: - 前板+側壁 → 展開形状  v3.3
//
// 考え方(前板の外寸の座標をそのまま使う。原点合わせは Geometry.build が行う):
//  ・側壁のある辺は、曲げ線が外形から「控除値の半分」内側に入る。側壁の展開長 = 奥行(外寸) − 控除値の半分
//  ・前板(曲げ線で囲まれた多角形)と側壁(長方形)の和集合が外形。凸の角では側壁どうしの間が自動で切り欠きになる
//  ・内角(へこんだ角)をはさむ2つの側壁は展開図の上で重なり、1枚板では作れない。
//    短い方の辺の側壁を本体から外し、別部品(帯板・溶接)にする
//  ・残した側壁が内角で前板の辺に接する所は、逃げ(幅 relief)を空けて切り離す

enum PlateBuilder {
    static let relief = 1.0

    struct Strip: Hashable {
        var edge: Int
        var length: Double
        var depth: Double
        var holes: [Hole]
    }

    struct Result {
        var outline: [OutlineVertex] = []
        var holes: [Hole] = []
        var bends: [Bend] = []
        /// 本体から外した側壁(別部品にする)
        var strips: [Strip] = []
    }

    /// 反時計回りにそろえる(辺の番号も付け直す)
    static func normalized(_ pm: PlateModel) -> PlateModel {
        let pts = pm.outline
        let n = pts.count
        guard n >= 3 else { return pm }
        var area = 0.0
        for k in 0..<n { let a = pts[k], b = pts[(k + 1) % n]; area += a.x * b.y - b.x * a.y }
        guard area < 0 else { return pm }
        var m = pm
        m.outline = Array(pts.reversed())
        // 元の辺 i(頂点 i → i+1)は、逆順では 辺 n−2−i
        func remap(_ i: Int) -> Int { ((n - 2 - i) % n + n) % n }
        m.walls = pm.walls.map { var w = $0; w.edge = remap($0.edge); return w }
        m.wallHoles = pm.wallHoles.map { var h = $0; h.edge = remap($0.edge); return h }
        return m
    }

    static func isConcave(_ pts: [P2], _ k: Int) -> Bool {
        let n = pts.count
        let a = pts[(k - 1 + n) % n], b = pts[k], c = pts[(k + 1) % n]
        return Geometry.cross(Geometry.sub(b, a), Geometry.sub(c, b)) < -1e-9
    }

    /// 本体に残す側壁と、外す側壁(内角で重なる短い方)
    static func plan(_ pm: PlateModel) -> (kept: [Int: PlateWall], removed: [Int: PlateWall]) {
        let pts = pm.outline
        let n = pts.count
        var kept: [Int: PlateWall] = [:]
        for w in pm.walls where w.edge >= 0 && w.edge < n && w.depth > 0 { kept[w.edge] = w }
        var removed: [Int: PlateWall] = [:]
        guard n >= 3 else { return (kept, removed) }
        func len(_ i: Int) -> Double { Geometry.dist(pts[i], pts[(i + 1) % n]) }
        for k in 0..<n where isConcave(pts, k) {
            let e0 = (k - 1 + n) % n, e1 = k
            guard let w0 = kept[e0], let w1 = kept[e1] else { continue }
            let drop = len(e0) < len(e1) - 1e-9 ? e0 : e1
            removed[drop] = drop == e0 ? w0 : w1
            kept[drop] = nil
        }
        return (kept, removed)
    }

    /// 本体から外す側壁の帯板(長さ = 辺の外寸、幅 = 奥行の外寸、穴は先端から測る)
    static func strips(_ pm0: PlateModel) -> [Strip] {
        let pm = normalized(pm0)
        let pts = pm.outline
        let n = pts.count
        guard n >= 3 else { return [] }
        let (_, removed) = plan(pm)
        return removed.keys.sorted().compactMap { i -> Strip? in
            guard let w = removed[i] else { return nil }
            let a = pts[i], b = pts[(i + 1) % n]
            let horizontal = abs(a.y - b.y) < 0.01
            let lo = horizontal ? min(a.x, b.x) : min(a.y, b.y)
            var holes: [Hole] = []
            for wh in pm.wallHoles where wh.edge == i {
                var h = wh.hole
                h.type = .circle
                h.cx = wh.along - lo
                h.cy = wh.fromFree
                holes.append(h)
            }
            return Strip(edge: i, length: Geometry.dist(a, b), depth: w.depth, holes: holes)
        }
    }

    static func flatten(_ pm0: PlateModel, thickness t: Double, deduction90: Double, warnings: inout [String]) -> Result {
        var res = Result()
        let pm = normalized(pm0)
        let pts = pm.outline
        let n = pts.count
        guard n >= 3 else { warnings.append("前板の外形の頂点が3つ未満です"); return res }
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            if abs(a.x - b.x) > 0.01 && abs(a.y - b.y) > 0.01 {
                warnings.append("前板の辺\(i + 1)が斜めです(前板+側壁の計算は縦横の辺だけ対応)。「指示して読み直す」で外寸並べ(outer_dims)にしてください")
                return res
            }
        }
        let (kept, removed) = plan(pm)
        res.strips = strips(pm)
        for i in removed.keys.sorted() {
            warnings.append("辺\(i + 1)の側壁(長さ\(Fmt.num(Geometry.dist(pts[i], pts[(i + 1) % n]))))は内角で隣の側壁と重なるため、別部品(溶接)にしました")
        }

        func ded(_ w: PlateWall) -> Double { deduction90 * (w.angleDeg <= 0 ? 90 : w.angleDeg) / 90 }
        func horizontal(_ i: Int) -> Bool { abs(pts[i].y - pts[(i + 1) % n].y) < 0.01 }
        func dir(_ i: Int) -> P2 { Geometry.norm(Geometry.sub(pts[(i + 1) % n], pts[i])) }
        func inward(_ i: Int) -> P2 { let u = dir(i); return P2(x: -u.y, y: u.x) }
        /// 曲げ線(側壁が無い辺は外形のまま)の位置。横の辺ならY、縦の辺ならX
        func line(_ i: Int) -> Double {
            let o = kept[i].map { ded($0) / 2 } ?? 0
            let nn = inward(i)
            return horizontal(i) ? pts[i].y + nn.y * o : pts[i].x + nn.x * o
        }

        // 1) 前板(曲げ線で囲まれた多角形)
        var q: [P2] = []
        for k in 0..<n {
            let e0 = (k - 1 + n) % n, e1 = k
            if horizontal(e0) != horizontal(e1) {
                q.append(horizontal(e1) ? P2(x: line(e0), y: line(e1)) : P2(x: line(e1), y: line(e0)))
            } else {
                // 一直線上の頂点
                q.append(horizontal(e1) ? P2(x: pts[k].x, y: line(e1)) : P2(x: line(e1), y: pts[k].y))
            }
        }
        var inc: [FaceBuilder.Rect] = []
        let xs = Array(Set(q.map { ($0.x * 10000).rounded() / 10000 })).sorted()
        let ys = Array(Set(q.map { ($0.y * 10000).rounded() / 10000 })).sorted()
        if xs.count >= 2 && ys.count >= 2 {
            for i in 0..<(xs.count - 1) {
                for j in 0..<(ys.count - 1) {
                    let c = P2(x: (xs[i] + xs[i + 1]) / 2, y: (ys[j] + ys[j + 1]) / 2)
                    if Geometry.pointInPolygon(c, q) {
                        inc.append(FaceBuilder.Rect(x0: xs[i], y0: ys[j], x1: xs[i + 1], y1: ys[j + 1]))
                    }
                }
            }
        }
        let plateRects = inc

        // 2) 側壁(長方形)と曲げ線
        var wallRects: [(Int, FaceBuilder.Rect)] = []
        for i in kept.keys.sorted() {
            guard let w = kept[i] else { continue }
            let L = w.depth - ded(w) / 2
            guard L > 0.1 else { warnings.append("辺\(i + 1)の側壁が短すぎるため省略"); continue }
            let u = dir(i), nn = inward(i)
            var s = q[i], e = q[(i + 1) % n]
            // 内角で、隣の辺に側壁が無い(外した)ときは逃げを空ける
            if isConcave(pts, i) && kept[(i - 1 + n) % n] == nil { s = Geometry.add(s, Geometry.mul(u, relief)) }
            if isConcave(pts, (i + 1) % n) && kept[(i + 1) % n] == nil { e = Geometry.sub(e, Geometry.mul(u, relief)) }
            let s2 = Geometry.sub(s, Geometry.mul(nn, L)), e2 = Geometry.sub(e, Geometry.mul(nn, L))
            let all = [s, e, s2, e2]
            let r = FaceBuilder.Rect(x0: all.map(\.x).min()!, y0: all.map(\.y).min()!,
                                     x1: all.map(\.x).max()!, y1: all.map(\.y).max()!)
            wallRects.append((i, r))
            var bend = Bend()
            bend.axis = horizontal(i) ? .y : .x
            bend.position = line(i)
            bend.angleDeg = w.angleDeg
            bend.up = w.up
            bend.from = horizontal(i) ? min(s.x, e.x) : min(s.y, e.y)
            bend.to = horizontal(i) ? max(s.x, e.x) : max(s.y, e.y)
            res.bends.append(bend)
            // 側壁の穴
            for wh in pm.wallHoles where wh.edge == i {
                let base = horizontal(i) ? P2(x: wh.along, y: line(i)) : P2(x: line(i), y: wh.along)
                let c = Geometry.sub(base, Geometry.mul(nn, L - wh.fromFree))
                var h = wh.hole
                h.type = .circle
                h.cx = c.x
                h.cy = c.y
                if wh.fromFree > L - h.d / 2 - t {
                    warnings.append("辺\(i + 1)の側壁の穴が曲げ線に近すぎます(曲げで穴が変形するおそれ)")
                }
                res.holes.append(h)
            }
        }
        // 側壁どうし・前板との重なり(読み取りの誤りの目安)
        func overlap(_ a: FaceBuilder.Rect, _ b: FaceBuilder.Rect) -> Double {
            max(0, min(a.x1, b.x1) - max(a.x0, b.x0)) * max(0, min(a.y1, b.y1) - max(a.y0, b.y0))
        }
        for x in 0..<wallRects.count {
            for y in (x + 1)..<max(x + 1, wallRects.count) where overlap(wallRects[x].1, wallRects[y].1) > 0.5 {
                warnings.append("辺\(wallRects[x].0 + 1)と辺\(wallRects[y].0 + 1)の側壁が展開図で重なっています")
            }
            if plateRects.contains(where: { overlap($0, wallRects[x].1) > 0.5 }) {
                warnings.append("辺\(wallRects[x].0 + 1)の側壁が前板に重なっています")
            }
        }

        // 3) 外形 = 前板 ∪ 側壁
        let loop = FaceBuilder.union(plateRects + wallRects.map { $0.1 }, minus: [], warnings: &warnings)
        res.outline = loop.map { OutlineVertex(x: $0.x, y: $0.y) }
        // 4) 前板の穴(座標はそのまま)
        res.holes = pm.holes + res.holes
        return res
    }
}
