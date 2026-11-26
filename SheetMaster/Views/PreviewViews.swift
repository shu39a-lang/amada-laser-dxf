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
                    .foregroundStyle(.black)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .navigationDestination(isPresented: $showCompare) {
                CompareView(title: title, built: built, loadImages: loadImages ?? { [] })
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CompareView(title: title, built: built, loadImages: loadImages)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }
    }
}

// MARK: - v2.9 図面の写真と見比べる

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
/// AIが答えた「写真の中の穴の位置」と「データの穴の位置」から、縮尺・傾き・位置を最小二乗で求める。
///  複素数で 写真の点 w = a·z + b(z = x − i·y)
struct PhotoAlignment {
    let image: UIImage
    let photoNo: Int
    let ar: Double, ai: Double, br: Double, bi: Double
    /// 穴ごとの「写真の位置」と「データの位置」のずれ(mm)。キー = holeLabels の番号
    let residual: [Int: Double]
    /// 合わせに使った穴の数
    let used: Int

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
        // 画面 = (s / a)·w + (ox, oy) − (s / a)·b
        let den = ar * ar + ai * ai
        let cr = Double(m.s) * ar / den, ci = -Double(m.s) * ai / den
        let tr = Double(m.ox) - (cr * br - ci * bi)
        let ti = Double(m.oy) - (cr * bi + ci * br)
        return CGAffineTransform(a: cr, b: ci, c: -ci, d: cr, tx: tr, ty: ti)
    }

    func photoPixel(_ l: HoleLabel) -> CGPoint? {
        guard l.photoNo == photoNo, let p = l.photo else { return nil }
        return CGPoint(x: p.x * Double(image.size.width), y: p.y * Double(image.size.height))
    }

    static func make(built: BuiltPart, images: [UIImage]) -> PhotoAlignment? {
        // 穴の位置が一番多く付いている写真を使う
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
        guard z.count >= 2 else { return nil }
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
        guard sz > 1 else { return nil }   // 穴がほとんど同じ場所にしか無い
        let ar = sr / sz, ai = si / sz
        let k = hypot(ar, ai)
        guard k > 1e-6 else { return nil }
        let br = mwr - (ar * mzr - ai * mzi)
        let bi = mwi - (ar * mzi + ai * mzr)
        var res: [Int: Double] = [:]
        for j in 0..<z.count {
            let pr = ar * z[j].0 - ai * z[j].1 + br
            let pi = ar * z[j].1 + ai * z[j].0 + bi
            res[idx[j]] = hypot(pr - w[j].0, pi - w[j].1) / k
        }
        return PhotoAlignment(image: img, photoNo: no, ar: ar, ai: ai, br: br, bi: bi, residual: res, used: z.count)
    }
}

enum CompareColors {
    static let list: [Color] = [.yellow, .green, .cyan, .orange, .pink, .mint, .purple, .teal, .indigo, .brown]
    static func color(_ i: Int) -> Color { list[i % list.count] }
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

    var body: some View {
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
                    // 位置合わせができないときは、写真全体を枠に収める
                    let k = min(size.width / img.size.width, size.height / img.size.height)
                    let r = CGRect(x: (size.width - img.size.width * k) / 2, y: (size.height - img.size.height * k) / 2,
                                   width: img.size.width * k, height: img.size.height * k)
                    g.draw(Image(uiImage: img), in: r)
                }
            }

            // データ
            if kind != .photo {
                ctx.stroke(PartPreview.segPath(built.bendLines, m), with: .color(.cyan),
                           style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                ctx.stroke(PartPreview.segPath(built.outline, m), with: .color(.white), lineWidth: 1.6)
                ctx.stroke(PartPreview.segPath(built.holes, m), with: .color(.red), lineWidth: 1.3)
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
                if kind != .data, let al = align, let px = al.photoPixel(l) {
                    let c = m.pt(al.toMM(px))
                    let r = CGRect(x: c.x - bw / 2, y: c.y - bh / 2, width: bw, height: bh)
                    // 重ね表示では写真側の四角を点線にして区別する
                    let style = kind == .overlay ? StrokeStyle(lineWidth: lw, dash: [4, 3]) : StrokeStyle(lineWidth: lw)
                    ctx.stroke(Path(r), with: .color(color), style: style)
                    if kind == .photo {
                        ctx.draw(Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(color),
                                 at: CGPoint(x: r.minX + 1, y: r.minY - 7), anchor: .leading)
                    }
                }
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

    /// これ以上ずれていたら知らせる(mm)
    private var limit: Double { max(5, max(built.width, built.height) * 0.02) }

    var body: some View {
        VStack(spacing: 8) {
            Picker("表示", selection: $overlay) {
                Text("左右に並べる").tag(false)
                Text("重ねる").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Group {
                if !loaded {
                    ProgressView("写真を準備中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if images.isEmpty {
                    Text("元の図面の写真がありません").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if overlay {
                    pane(.overlay)
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

            if overlay && align != nil {
                HStack {
                    Text("写真の濃さ").font(.caption)
                    Slider(value: $photoOpacity, in: 0.1...1)
                }
                .padding(.horizontal)
            }

            if loaded && !images.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(align == nil ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            holeList

            Button("拡大を戻す") { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                .font(.footnote)
        }
        .padding(.vertical, 8)
        .navigationTitle("見比べる")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            // 大きな写真は描画が重いので縮める(向きもここで正す)
            images = loadImages().map { ImagePreprocessor.resized(ImagePreprocessor.normalized($0), maxEdge: 2400) }
            align = PhotoAlignment.make(built: built, images: images)
            loaded = true
        }
    }

    private func pane(_ k: ComparePane.Kind) -> some View {
        ComparePane(kind: k, built: built, image: align?.image ?? images.first, align: align,
                    selected: selected, photoOpacity: k == .overlay ? photoOpacity : 1)
            .scaleEffect(scale)
            .offset(offset)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        guard let al = align else {
            return "写真の中の穴の位置が分からないため、縮尺をそろえられません。「指示して読み直す」で読み直すと、位置付きで見比べられます(v2.9以降の読み取り)"
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
        if let al = align, let r = al.residual[i] {
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
