import SwiftUI

/// 認識した形のプレビュー
/// 白 = 外形、赤 = 穴・切り抜き、水色 = 曲げ線(切らない)
struct PartPreview: View {
    let built: BuiltPart
    var showLabels: Bool = true
    var showPositions: Bool = false
    var lineScale: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = showLabels ? 30 : 4
            let w = max(built.width, 1), h = max(built.height, 1)
            let s = min((size.width - pad * 2) / w, (size.height - pad * 2) / h)
            let ox = (size.width - w * s) / 2, oy = (size.height + h * s) / 2
            func pt(_ p: P2) -> CGPoint { CGPoint(x: ox + p.x * s, y: oy - p.y * s) }
            func path(_ segs: [Seg]) -> Path { PartPreview.segPath(segs, s: s, pt: pt) }
            ctx.stroke(path(built.bendLines), with: .color(.cyan), style: StrokeStyle(lineWidth: 1 * lineScale, dash: [5, 4]))
            ctx.stroke(path(built.outline), with: .color(.white), lineWidth: 1.6 * lineScale)
            ctx.stroke(path(built.holes), with: .color(.red), lineWidth: 1.3 * lineScale)
            // v3.0: 推定した所はオレンジ(穴はオレンジで重ね描き、頂点は丸で囲む)
            if !built.checkHoles.isEmpty {
                ctx.stroke(path(built.checkHoles), with: .color(.orange), lineWidth: 2 * lineScale)
            }
            for m in built.checkMarks {
                let c = pt(m.pos)
                let r: CGFloat = 7 * max(1, lineScale * 0.8)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(.orange), lineWidth: 1.8)
            }

            if showLabels {
                // 全体寸法
                let yb = oy + 14
                var dim = Path()
                dim.move(to: CGPoint(x: ox, y: yb)); dim.addLine(to: CGPoint(x: ox + w * s, y: yb))
                let xl = ox - 14
                dim.move(to: CGPoint(x: xl, y: oy)); dim.addLine(to: CGPoint(x: xl, y: oy - h * s))
                ctx.stroke(dim, with: .color(.yellow.opacity(0.7)), lineWidth: 0.8)
                ctx.draw(Text(Fmt.num(built.width)).font(.caption.bold()).foregroundStyle(.yellow),
                         at: CGPoint(x: ox + w * s / 2, y: yb + 9))
                var c2 = ctx
                c2.translateBy(x: xl - 9, y: oy - h * s / 2)
                c2.rotate(by: .degrees(-90))
                c2.draw(Text(Fmt.num(built.height)).font(.caption.bold()).foregroundStyle(.yellow), at: .zero)
                // 穴の径・位置
                for l in built.holeLabels {
                    let p = pt(l.pos)
                    ctx.draw(Text(l.text).font(.system(size: 9 * max(1, lineScale * 0.8)))
                                .foregroundStyle(l.check == nil ? Color.red : Color.orange),
                             at: CGPoint(x: p.x, y: p.y - 10))
                    if showPositions {
                        ctx.draw(Text(l.position).font(.system(size: 8 * max(1, lineScale * 0.8))).foregroundStyle(.orange),
                                 at: CGPoint(x: p.x, y: p.y + 10))
                    }
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension PartPreview {
    /// 線分 → 画面のパス(プレビューと見比べ画面で共通)
    static func segPath(_ segs: [Seg], s: CGFloat, pt: (P2) -> CGPoint) -> Path {
        var path = Path()
        for seg in segs {
            switch seg {
            case .line(let a, let b):
                path.move(to: pt(a)); path.addLine(to: pt(b))
            case .arc(let c, let r, let s0, let e0):
                // 画面はY下向きなので角度の符号を反転
                var sub = Path()
                sub.addArc(center: pt(c), radius: r * s,
                           startAngle: .degrees(-s0), endAngle: .degrees(-e0), clockwise: true)
                path.addPath(sub)
            case .circle(let c, let r):
                let cc = pt(c)
                path.addEllipse(in: CGRect(x: cc.x - r * s, y: cc.y - r * s, width: r * 2 * s, height: r * 2 * s))
            }
        }
        return path
    }

    static func segPath(_ segs: [Seg], _ m: PaneMap) -> Path {
        segPath(segs, s: m.s, pt: m.pt)
    }
}

struct PreviewLegend: View {
    /// v3.0: 推定した所があるときは「要確認」も出す
    var showCheck: Bool = false
    var body: some View {
        HStack(spacing: 12) {
            legend(.white, "外形")
            legend(.red, "穴・切り抜き")
            legend(.cyan, "曲げ線(切らない)")
            if showCheck { legend(.orange, "要確認") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Rectangle().fill(c).frame(width: 14, height: 3); Text(t) }
    }
}

/// 拡大表示(ピンチで拡大、ドラッグで移動)
struct FullPreviewView: View {
    let title: String
    let built: BuiltPart
    /// v2.9: 元の図面の写真を読み込む(渡されたときだけ「図面と見比べる」ボタンを出す)
    var loadImages: (() -> [UIImage])? = nil
    /// v3.1: 手で合わせた写真の位置(部品ごとに保存)
    var savedAlign: [Double]? = nil
    var onSaveAlign: (([Double]?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showCompare = false
    @State private var showPositions = true
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                PartPreview(built: built, showLabels: true, showPositions: showPositions)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { v in scale = max(1, min(8, lastScale * v.magnification)) }
                            .onEnded { _ in lastScale = scale }
                            .simultaneously(with: DragGesture()
                                .onChanged { v in
                                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                                    height: lastOffset.height + v.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset })
                    )
                    .clipped()
                PreviewLegend(showCheck: !built.checkMarks.isEmpty)
                Toggle("穴の位置(X, Y)を表示", isOn: $showPositions).padding(.horizontal)
                Text("展開寸法 \(Fmt.num(built.width)) × \(Fmt.num(built.height)) mm ・ 穴 \(built.holeLabels.count)個 ・ 原点は左下")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("拡大を戻す") { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    .font(.footnote)
                if loadImages != nil {
                    Button {
                        showCompare = true
                    } label: {
                        Label("図面と見比べる", systemImage: "rectangle.split.2x1")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.red)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .navigationDestination(isPresented: $showCompare) {
                CompareView(title: title, built: built, loadImages: loadImages ?? { [] },
                            savedAlign: savedAlign, onSaveAlign: onSaveAlign)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if loadImages != nil {
                    // v2.9: 画面の上にも「見比べる」(下のボタンが画面外に隠れる機種でも押せるように)
                    ToolbarItem(placement: .topBarLeading) { Button("見比べる") { showCompare = true } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

/// v2.9: 部品カードから直接開く見比べ画面(閉じるボタン付き)
struct CompareSheet: View {
    let title: String
    let built: BuiltPart
    let loadImages: () -> [UIImage]
    var savedAlign: [Double]? = nil
    var onSaveAlign: (([Double]?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CompareView(title: title, built: built, loadImages: loadImages,
                        savedAlign: savedAlign, onSaveAlign: onSaveAlign)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }
    }
}

// MARK: - v2.9 図面の写真と見比べる / v3.1 手で合わせる

/// 部品の座標(mm)→ 画面の座標
struct PaneMap {
    let s: CGFloat
    let ox: CGFloat
    let oy: CGFloat

    init(size: CGSize, w: Double, h: Double, pad: CGFloat) {
        let ww = max(w, 1), hh = max(h, 1)
        s = max(0.0001, min((size.width - pad * 2) / ww, (size.height - pad * 2) / hh))
        ox = (size.width - ww * s) / 2
        oy = (size.height + hh * s) / 2
    }

    func pt(_ p: P2) -> CGPoint { CGPoint(x: ox + p.x * s, y: oy - p.y * s) }
}

/// 写真(ピクセル・Y下向き)と部品の座標(mm・Y上向き)の位置合わせ。
///  複素数で 写真の点 w = a·z + b(z = x − i·y)
///  自動: AIが答えた「写真の中の穴の位置」から最小二乗で求める
///  手動(v3.1): 作業者が写真の上で A・B の2点をタップして求める
struct PhotoAlignment {
    let image: UIImage
    let photoNo: Int
    let ar: Double, ai: Double, br: Double, bi: Double
    /// 穴ごとの「写真の位置」と「データの位置」のずれ(mm)。キー = holeLabels の番号
    var residual: [Int: Double] = [:]
    /// 合わせに使った穴の数(手動は0)
    var used: Int = 0
    var manual: Bool = false

    /// 写真のピクセル → mm
    func toMM(_ w: CGPoint) -> P2 {
        let dx = Double(w.x) - br, dy = Double(w.y) - bi
        let den = ar * ar + ai * ai
        let zr = (dx * ar + dy * ai) / den
        let zi = (dy * ar - dx * ai) / den
        return P2(x: zr, y: -zi)
    }

    /// 写真を画面に描くための変換(写真のピクセル → 画面)
    func screenTransform(_ m: PaneMap) -> CGAffineTransform {
        let den = ar * ar + ai * ai
        let cr = Double(m.s) * ar / den, ci = -Double(m.s) * ai / den
        let tr = Double(m.ox) - (cr * br - ci * bi)
        let ti = Double(m.oy) - (cr * bi + ci * br)
        return CGAffineTransform(a: cr, b: ci, c: -ci, d: cr, tx: tr, ty: ti)
    }

    func photoPixel(_ l: HoleLabel) -> CGPoint? {
        guard !manual, l.photoNo == photoNo, let p = l.photo else { return nil }
        return CGPoint(x: p.x * Double(image.size.width), y: p.y * Double(image.size.height))
    }

    /// 保存用: [写真番号, ar, ai, br, bi, 写真の幅(ピクセル)]
    var saved: [Double] { [Double(photoNo), ar, ai, br, bi, Double(image.size.width)] }

    static func fromSaved(_ v: [Double]?, images: [UIImage]) -> PhotoAlignment? {
        guard let v, v.count == 6, v[5] > 0 else { return nil }
        let no = Int(v[0])
        guard no >= 1, no <= images.count else { return nil }
        let img = images[no - 1]
        let f = Double(img.size.width) / v[5]
        guard hypot(v[1], v[2]) > 1e-9 else { return nil }
        return PhotoAlignment(image: img, photoNo: no, ar: v[1] * f, ai: v[2] * f, br: v[3] * f, bi: v[4] * f, manual: true)
    }

    /// 点の組(z = mm を x − i·y にしたもの、w = 写真のピクセル)から a, b を求める
    static func solve(_ z: [(Double, Double)], _ w: [(Double, Double)]) -> (Double, Double, Double, Double)? {
        guard z.count >= 2, z.count == w.count else { return nil }
        let n = Double(z.count)
        let mzr = z.map { $0.0 }.reduce(0, +) / n, mzi = z.map { $0.1 }.reduce(0, +) / n
        let mwr = w.map { $0.0 }.reduce(0, +) / n, mwi = w.map { $0.1 }.reduce(0, +) / n
        var sr = 0.0, si = 0.0, sz = 0.0
        for k in 0..<z.count {
            let zr = z[k].0 - mzr, zi = z[k].1 - mzi
            let wr = w[k].0 - mwr, wi = w[k].1 - mwi
            sr += wr * zr + wi * zi
            si += wi * zr - wr * zi
            sz += zr * zr + zi * zi
        }
        guard sz > 1 else { return nil }
        let ar = sr / sz, ai = si / sz
        guard hypot(ar, ai) > 1e-6 else { return nil }
        let br = mwr - (ar * mzr - ai * mzi)
        let bi = mwi - (ar * mzi + ai * mzr)
        return (ar, ai, br, bi)
    }

    /// 手動: データの2点と、写真上でタップした2点から
    static func manual(image: UIImage, photoNo: Int, data: [P2], photo: [CGPoint]) -> PhotoAlignment? {
        guard data.count == 2, photo.count == 2 else { return nil }
        guard let r = solve(data.map { ($0.x, -$0.y) }, photo.map { (Double($0.x), Double($0.y)) }) else { return nil }
        return PhotoAlignment(image: image, photoNo: photoNo, ar: r.0, ai: r.1, br: r.2, bi: r.3, manual: true)
    }

    /// 自動: 穴の位置から
    static func make(built: BuiltPart, images: [UIImage]) -> PhotoAlignment? {
        var count: [Int: Int] = [:]
        for l in built.holeLabels {
            if let n = l.photoNo, n >= 1, n <= images.count, l.photo != nil { count[n, default: 0] += 1 }
        }
        guard let no = count.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first?.key
        else { return nil }
        let img = images[no - 1]
        var idx: [Int] = []
        var z: [(Double, Double)] = []
        var w: [(Double, Double)] = []
        for (i, l) in built.holeLabels.enumerated() where l.photoNo == no {
            guard let p = l.photo else { continue }
            idx.append(i)
            z.append((l.pos.x, -l.pos.y))
            w.append((p.x * Double(img.size.width), p.y * Double(img.size.height)))
        }
        guard let r = solve(z, w) else { return nil }
        let (ar, ai, br, bi) = r
        let k = hypot(ar, ai)
        var res: [Int: Double] = [:]
        for j in 0..<z.count {
            let pr = ar * z[j].0 - ai * z[j].1 + br
            let pi = ar * z[j].1 + ai * z[j].0 + bi
            res[idx[j]] = hypot(pr - w[j].0, pi - w[j].1) / k
        }
        return PhotoAlignment(image: img, photoNo: no, ar: ar, ai: ai, br: br, bi: bi,
                              residual: res, used: z.count, manual: false)
    }
}

enum CompareColors {
    static let list: [Color] = [.yellow, .green, .cyan, .orange, .pink, .mint, .purple, .teal, .indigo, .brown]
    static func color(_ i: Int) -> Color { list[i % list.count] }
}

/// 位置合わせ前の写真の表示範囲(枠に収める+タップした所を中心に拡大)
struct PhotoFit {
    let rect: CGRect
    let k: CGFloat

    init(size: CGSize, image: UIImage, focus: CGPoint?, zoom: CGFloat) {
        let base = min(size.width / image.size.width, size.height / image.size.height)
        if let f = focus {
            k = base * zoom
            rect = CGRect(x: size.width / 2 - f.x * k, y: size.height / 2 - f.y * k,
                          width: image.size.width * k, height: image.size.height * k)
        } else {
            k = base
            rect = CGRect(x: (size.width - image.size.width * k) / 2, y: (size.height - image.size.height * k) / 2,
                          width: image.size.width * k, height: image.size.height * k)
        }
    }

    func toPixel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - rect.minX) / k, y: (p.y - rect.minY) / k) }
    func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k) }
}

/// 見比べ画面の1枚(写真 / データ / 重ね)
struct ComparePane: View {
    enum Kind { case photo, data, overlay }
    let kind: Kind
    let built: BuiltPart
    let image: UIImage?
    let align: PhotoAlignment?
    let selected: Int?
    var photoOpacity: Double = 1
    // v3.1 手で合わせる
    var focus: CGPoint? = nil
    var focusZoom: CGFloat = 1
    var pickPoints: [P2] = []
    var activePick: Int? = nil
    var tapped: [CGPoint] = []
    var onTapPhoto: ((CGPoint) -> Void)? = nil
    /// v3.2: 指でなぞって四角で囲んだ範囲(写真のピクセル)
    var onDragBox: ((CGRect) -> Void)? = nil
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    /// v3.4: 合わせる間の写真の拡大・移動(2本指で拡大、1本指で移動)。boxMode のときは1本指で四角を描く
    var boxMode: Bool = false
    var onViewChange: ((CGPoint, CGFloat) -> Void)? = nil
    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let m = PaneMap(size: size, w: built.width, h: built.height, pad: 16)

                // 写真
                if kind != .data, let img = image {
                    var g = ctx
                    if kind == .overlay { g.opacity = photoOpacity }
                    if let al = align {
                        g.concatenate(al.screenTransform(m))
                        g.draw(Image(uiImage: img), in: CGRect(origin: .zero, size: img.size))
                    } else {
                        let fit = PhotoFit(size: size, image: img, focus: focus, zoom: focusZoom)
                        g.draw(Image(uiImage: img), in: fit.rect)
                        // なぞっている四角
                        if let a = dragStart, let b = dragNow {
                            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                            ctx.fill(Path(r), with: .color(.orange.opacity(0.15)))
                            ctx.stroke(Path(r), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                        // タップした点(A, B)
                        for (i, p) in tapped.enumerated() {
                            let c = fit.toScreen(p)
                            var cross = Path()
                            cross.move(to: CGPoint(x: c.x - 12, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 12, y: c.y))
                            cross.move(to: CGPoint(x: c.x, y: c.y - 12)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 12))
                            ctx.stroke(cross, with: .color(.orange), lineWidth: 2)
                            ctx.draw(Text(i == 0 ? "A" : "B").font(.caption.bold()).foregroundStyle(.orange),
                                     at: CGPoint(x: c.x + 14, y: c.y - 12))
                        }
                    }
                }

                // データ
                if kind != .photo {
                    ctx.stroke(PartPreview.segPath(built.bendLines, m), with: .color(.cyan),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    ctx.stroke(PartPreview.segPath(built.outline, m), with: .color(.white), lineWidth: 1.6)
                    ctx.stroke(PartPreview.segPath(built.holes, m), with: .color(.red), lineWidth: 1.3)
                    // 合わせる点 A・B
                    for (i, p) in pickPoints.enumerated() {
                        let c = m.pt(p)
                        let r: CGFloat = activePick == i ? 11 : 8
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                   with: .color(.orange), lineWidth: activePick == i ? 3 : 1.5)
                        ctx.draw(Text(i == 0 ? "A" : "B").font(.caption.bold()).foregroundStyle(.orange),
                                 at: CGPoint(x: c.x, y: c.y - r - 9))
                    }
                }

                // 穴を囲む四角(写真とデータで同じ色・同じ番号)
                for (i, l) in built.holeLabels.enumerated() {
                    let color = CompareColors.color(i)
                    let lw: CGFloat = selected == i ? 3.2 : 1.4
                    let bw = l.boxW * m.s + 10, bh = l.boxH * m.s + 10
                    if kind != .photo {
                        let c = m.pt(l.pos)
                        let r = CGRect(x: c.x - bw / 2, y: c.y - bh / 2, width: bw, height: bh)
                        ctx.stroke(Path(r), with: .color(color), lineWidth: lw)
                        ctx.draw(Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(color),
                                 at: CGPoint(x: r.minX + 1, y: r.minY - 7), anchor: .leading)
                    }
                    if kind != .data, let al = align {
                        // 自動合わせは写真上の位置、手動合わせはデータと同じ位置に四角を出す
                        let c: CGPoint
                        if let px = al.photoPixel(l) { c = m.pt(al.toMM(px)) } else if al.manual { c = m.pt(l.pos) } else { continue }
                        let r = CGRect(x: c.x - bw / 2, y: c.y - bh / 2, width: bw, height: bh)
                        let style = kind == .overlay ? StrokeStyle(lineWidth: lw, dash: [4, 3]) : StrokeStyle(lineWidth: lw)
                        ctx.stroke(Path(r), with: .color(color), style: style)
                        if kind == .photo {
                            ctx.draw(Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(color),
                                     at: CGPoint(x: r.minX + 1, y: r.minY - 7), anchor: .leading)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard let img = image else { return }
                        if boxMode && onDragBox != nil {
                            dragStart = v.startLocation
                            dragNow = v.location
                        } else if let cb = onViewChange {
                            // 1本指で写真を動かす
                            let fit = PhotoFit(size: geo.size, image: img, focus: focus, zoom: focusZoom)
                            let center = focus ?? CGPoint(x: img.size.width / 2, y: img.size.height / 2)
                            if panStart == nil { panStart = center }
                            let p0 = panStart ?? center
                            let nx = min(max(p0.x - v.translation.width / fit.k, 0), img.size.width)
                            let ny = min(max(p0.y - v.translation.height / fit.k, 0), img.size.height)
                            cb(CGPoint(x: nx, y: ny), focusZoom)
                        }
                    }
                    .onEnded { v in
                        panStart = nil
                        defer { dragStart = nil; dragNow = nil }
                        guard boxMode, let cb = onDragBox, let img = image else { return }
                        let fit = PhotoFit(size: geo.size, image: img, focus: focus, zoom: focusZoom)
                        let a = fit.toPixel(v.startLocation), b = fit.toPixel(v.location)
                        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        if r.width > 8 || r.height > 8 { cb(r) }
                    },
                including: (kind == .photo && align == nil && (onDragBox != nil || onViewChange != nil)) ? .all : .none
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        guard let cb = onViewChange, let img = image else { return }
                        if zoomStart == nil { zoomStart = focusZoom }
                        let z = min(max((zoomStart ?? 1) * v.magnification, 1), 25)
                        cb(focus ?? CGPoint(x: img.size.width / 2, y: img.size.height / 2), z)
                    }
                    .onEnded { _ in zoomStart = nil },
                including: (kind == .photo && align == nil && onViewChange != nil) ? .all : .none
            )
            .onTapGesture { loc in
                guard let cb = onTapPhoto, kind == .photo, align == nil, let img = image else { return }
                let fit = PhotoFit(size: geo.size, image: img, focus: focus, zoom: focusZoom)
                let px = fit.toPixel(loc)
                guard px.x >= 0, px.y >= 0, px.x <= img.size.width, px.y <= img.size.height else { return }
                cb(px)
            }
        }
        .background(kind == .data ? Color.black : Color(white: 0.12))
    }
}

/// 図面の写真と出したデータを、同じ縮尺で左右に並べて(または重ねて)見比べる
struct CompareView: View {
    let title: String
    let built: BuiltPart
    let loadImages: () -> [UIImage]
    var savedAlign: [Double]? = nil
    var onSaveAlign: (([Double]?) -> Void)? = nil

    /// 合わせる手順
    ///  choose = タップ(AIが探す)か、なぞって囲む / fineArea〜pointB = A・Bの2点で細かく合わせる
    enum Step { case none, choose, fineArea, pointA, pointB }
    @Environment(AppStore.self) private var store

    @State private var images: [UIImage] = []
    @State private var loaded = false
    @State private var align: PhotoAlignment?
    @State private var overlay = false
    @State private var photoOpacity = 0.55
    @State private var selected: Int?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    // v3.1
    @State private var step: Step = .none
    @State private var photoIndex = 0
    @State private var focus: CGPoint?
    @State private var focusZoom: CGFloat = 1
    @State private var tapped: [CGPoint] = []
    @State private var locating = false
    @State private var boxMode = false
    @State private var locateError: String?

    /// これ以上ずれていたら知らせる(mm)
    private var limit: Double { max(5, max(built.width, built.height) * 0.02) }

    /// 写真の上で合わせる2点(データの外形の、いちばん離れた2つの角)
    private var pickPoints: [P2] {
        var pts: [P2] = []
        for sg in built.outline {
            switch sg {
            case .line(let a, let b): pts += [a, b]
            case .arc(let c, let r, let s0, let e0):
                for a in [s0, e0] {
                    let t = a * .pi / 180
                    pts.append(P2(x: c.x + r * cos(t), y: c.y + r * sin(t)))
                }
            case .circle: break
            }
        }
        guard pts.count >= 2 else { return [] }
        var best = (pts[0], pts[1]), bd = -1.0
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = Geometry.dist(pts[i], pts[j])
                if d > bd { bd = d; best = (pts[i], pts[j]) }
            }
        }
        // 左側を A にする
        return best.0.x <= best.1.x ? [best.0, best.1] : [best.1, best.0]
    }

    private var currentImage: UIImage? {
        if let al = align { return al.image }
        return images.indices.contains(photoIndex) ? images[photoIndex] : images.first
    }

    var body: some View {
        VStack(spacing: 8) {
            if align != nil {
                Picker("表示", selection: $overlay) {
                    Text("左右に並べる").tag(false)
                    Text("重ねる").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            } else if images.count > 1 && step != .none {
                Picker("写真", selection: $photoIndex) {
                    ForEach(images.indices, id: \.self) { Text("写真\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: photoIndex) { _, _ in startAlign() }
            }

            Group {
                if !loaded {
                    ProgressView("写真を準備中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if images.isEmpty {
                    Text("元の図面の写真がありません").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if overlay && align != nil {
                    pane(.overlay)
                } else if step != .none {
                    // v3.4: 合わせる間は写真を大きく。データは右上に小さく(A・Bの位置の確認用)
                    ZStack(alignment: .topTrailing) {
                        pane(.photo)
                        pane(.data)
                            .frame(width: 130, height: 130)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 1))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 4)
                } else {
                    HStack(spacing: 4) {
                        VStack(spacing: 2) {
                            Text("図面の写真").font(.caption2).foregroundStyle(.secondary)
                            pane(.photo)
                        }
                        VStack(spacing: 2) {
                            Text("出したデータ").font(.caption2).foregroundStyle(.secondary)
                            pane(.data)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if locating {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("AIが写真の中の部品を探しています…(10〜30秒)").font(.caption.bold())
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { v in scale = max(1, min(8, lastScale * v.magnification)) }
                    .onEnded { _ in lastScale = scale }
                    .simultaneously(with: DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }),
                including: step == .none ? .all : .subviews
            )

            if overlay && align != nil {
                HStack {
                    Text("写真の濃さ").font(.caption)
                    Slider(value: $photoOpacity, in: 0.1...1)
                }
                .padding(.horizontal)
            }

            if loaded && !images.isEmpty {
                guide
            }

            if !built.holeLabels.isEmpty { holeList }

            Button("拡大を戻す") { resetZoom() }
                .font(.footnote)
        }
        .padding(.vertical, 8)
        .navigationTitle("見比べる")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            // 大きな写真は描画が重いので縮める(向きもここで正す)
            images = loadImages().map { ImagePreprocessor.resized(ImagePreprocessor.normalized($0), maxEdge: 2400) }
            align = PhotoAlignment.fromSaved(savedAlign, images: images) ?? PhotoAlignment.make(built: built, images: images)
            loaded = true
            // 写真の位置が分からないときは、すぐ手で合わせる手順に入る
            if align == nil && !images.isEmpty && pickPoints.count == 2 { startAlign() }
        }
    }

    // MARK: 手で合わせる

    private func startAlign() {
        align = nil
        overlay = false
        focus = nil
        focusZoom = 1
        tapped = []
        locateError = nil
        boxMode = false
        step = .choose
        resetZoom()
    }

    private var photoNo: Int {
        guard let img = currentImage else { return 1 }
        return (images.firstIndex(of: img) ?? photoIndex) + 1
    }

    private func finish(_ al: PhotoAlignment) {
        align = al
        step = .none
        overlay = true          // 合ったかどうかが一目で分かるよう、重ねて見せる
        resetZoom()
        onSaveAlign?(al.saved)
    }

    /// v3.2: なぞって囲んだ四角に、データの外形がぴったり入るように合わせる(すぐ・AIなし)
    private func alignToBox(_ r: CGRect) {
        guard let img = currentImage else { return }
        let W = max(built.width, 1), H = max(built.height, 1)
        let kw = Double(r.width) / W, kh = Double(r.height) / H
        // 細長い部品は長い方の辺で縮尺を決める(短い方は囲み方のずれが大きく出るため)
        let k: Double
        if W / H > 3 || r.height < 10 { k = kw }
        else if H / W > 3 || r.width < 10 { k = kh }
        else { k = (kw + kh) / 2 }
        guard k > 0 else { return }
        // 中心を合わせる。z = x − i·y(mm)、w = k·z + b
        let br = Double(r.midX) - k * (W / 2)
        let bi = Double(r.midY) - k * (-H / 2)
        finish(PhotoAlignment(image: img, photoNo: photoNo, ar: k, ai: 0, br: br, bi: bi, manual: true))
    }

    /// v3.2: タップした所の部品をAIに探してもらって合わせる
    private func locateByTap(_ px: CGPoint) {
        guard let img = currentImage, !locating else { return }
        locating = true
        locateError = nil
        let key = store.apiKey, model = store.settings.model, no = photoNo
        Task { @MainActor in
            defer { locating = false }
            do {
                if let al = try await PartLocator.locate(apiKey: key, model: model, image: img, photoNo: no,
                                                         tap: px, partName: title, built: built) {
                    finish(al)
                } else {
                    locateError = "写真の中でこの部品を見つけられませんでした。部品の形を指でなぞって四角で囲んでください"
                }
            } catch {
                locateError = "AIに聞けませんでした(\(error.localizedDescription))。部品の形を指でなぞって四角で囲んでください"
            }
        }
    }

    private func resetZoom() { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }

    private func handleTap(_ px: CGPoint) {
        switch step {
        case .choose:
            if !boxMode { locateByTap(px) }
        case .fineArea, .pointA:
            tapped = [px]
            step = .pointB
        case .pointB:
            tapped.append(px)
            guard let img = currentImage,
                  let al = PhotoAlignment.manual(image: img, photoNo: (images.firstIndex(of: img) ?? photoIndex) + 1,
                                                 data: pickPoints, photo: tapped) else {
                tapped = []
                step = .pointA
                return
            }
            finish(al)
        case .none:
            break
        }
    }

    @ViewBuilder
    private var guide: some View {
        VStack(spacing: 6) {
            switch step {
            case .choose:
                guideText(boxMode
                          ? "部品の形を指でなぞって四角で囲んでください(すぐ合います)"
                          : "写真の中の部品の所をタップしてください(AIが探して自動で合わせます)")
                if let e = locateError {
                    Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }
                zoomBar
                HStack {
                    Toggle("四角で囲む", isOn: $boxMode).toggleStyle(.button)
                    Button("A・Bの2点で合わせる") { tapped = []; boxMode = false; step = .pointA }
                }
                .font(.caption).buttonStyle(.bordered)
            case .fineArea, .pointA:
                guideText("右上のデータの「A」の角と同じ所を、写真を拡大してタップしてください")
                zoomBar
                Button("簡単な合わせ方に戻る") { startAlign() }.font(.caption).buttonStyle(.bordered)
            case .pointB:
                guideText("次に「B」の角と同じ所をタップしてください")
                zoomBar
                Button("Aからやり直す") { tapped = []; step = .pointA }.font(.caption).buttonStyle(.bordered)
            case .none:
                if let al = align {
                    Text(statusText(al)).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button {
                        startAlign()
                    } label: {
                        Label(al.manual ? "写真を合わせ直す" : "写真を手で合わせ直す", systemImage: "hand.tap")
                    }
                    .font(.caption).buttonStyle(.bordered)
                } else if pickPoints.count == 2 {
                    Button {
                        startAlign()
                    } label: {
                        Label("写真をタップして合わせる", systemImage: "hand.tap").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.red).padding(.horizontal)
                }
            }
        }
    }

    /// v3.4: 写真の拡大・縮小(2本指でも拡大、1本指で移動できる)
    private var zoomBar: some View {
        HStack(spacing: 10) {
            Text("2本指で拡大・1本指で移動").font(.caption2).foregroundStyle(.secondary)
            Button { focusZoom = max(focusZoom / 1.6, 1) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { focusZoom = min(focusZoom * 1.6, 25) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("全体") { focus = nil; focusZoom = 1 }
            Text("×\(Fmt.num((Double(focusZoom) * 10).rounded() / 10))").font(.caption2.monospacedDigit())
        }
        .font(.caption)
        .buttonStyle(.bordered)
    }

    private func guideText(_ t: String) -> some View {
        Text(t).font(.subheadline.bold()).foregroundStyle(.orange)
            .multilineTextAlignment(.center).padding(.horizontal)
    }

    private func pane(_ k: ComparePane.Kind) -> some View {
        let aligning = step != .none && !locating
        let fine = step == .fineArea || step == .pointA || step == .pointB
        return ComparePane(kind: k, built: built, image: currentImage, align: align,
                           selected: selected, photoOpacity: k == .overlay ? photoOpacity : 1,
                           focus: focus, focusZoom: focusZoom,
                           pickPoints: fine ? pickPoints : [],
                           activePick: step == .pointA ? 0 : (step == .pointB ? 1 : nil),
                           tapped: tapped,
                           onTapPhoto: aligning ? { handleTap($0) } : nil,
                           onDragBox: (aligning && step == .choose) ? { alignToBox($0) } : nil,
                           boxMode: boxMode && step == .choose,
                           onViewChange: aligning ? { f, z in focus = f; focusZoom = z } : nil)
            .scaleEffect(scale)
            .offset(offset)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusText(_ al: PhotoAlignment) -> String {
        if al.manual {
            return "写真をデータと同じ大きさ・向きに合わせて重ねています(写真\(al.photoNo))。白い線と図面の線がずれていたら「写真を合わせ直す」を押してください"
        }
        let bad = al.residual.values.filter { $0 > limit }.count
        var t = "穴\(al.used)か所の位置で、写真の縮尺・傾きをデータに合わせています(写真\(al.photoNo))"
        if al.used >= 3 && bad > 0 { t += "。ずれの大きい穴が\(bad)か所あります" }
        return t
    }

    private var holeList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Array(built.holeLabels.enumerated()), id: \.offset) { pair in
                    let i = pair.offset, l = pair.element
                    Button {
                        selected = selected == i ? nil : i
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4).fill(CompareColors.color(i)))
                            Text(l.text).font(.caption.bold())
                            Text(l.position).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            judge(i, l).font(.caption)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected == i ? Color.white.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 150)
    }

    @ViewBuilder
    private func judge(_ i: Int, _ l: HoleLabel) -> some View {
        if let al = align, al.manual {
            Text("写真の穴と比べてください").foregroundStyle(.secondary)
        } else if let al = align, let r = al.residual[i] {
            if al.used < 3 {
                Text("位置合わせに使用").foregroundStyle(.secondary)
            } else if r > limit {
                Text("⚠︎ ずれ約\(Fmt.num((r * 10).rounded() / 10))mm").foregroundStyle(.orange)
            } else {
                Text("写真と一致").foregroundStyle(.green)
            }
        } else if l.photo != nil {
            Text("別の写真").foregroundStyle(.secondary)
        } else {
            Text("写真の位置なし").foregroundStyle(.secondary)
        }
    }
}
