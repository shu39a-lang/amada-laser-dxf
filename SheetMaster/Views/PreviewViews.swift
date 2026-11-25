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
            func path(_ segs: [Seg]) -> Path {
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
            ctx.stroke(path(built.bendLines), with: .color(.cyan), style: StrokeStyle(lineWidth: 1 * lineScale, dash: [5, 4]))
            ctx.stroke(path(built.outline), with: .color(.white), lineWidth: 1.6 * lineScale)
            ctx.stroke(path(built.holes), with: .color(.red), lineWidth: 1.3 * lineScale)

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
                    ctx.draw(Text(l.text).font(.system(size: 9 * max(1, lineScale * 0.8))).foregroundStyle(.red),
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

struct PreviewLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legend(.white, "外形")
            legend(.red, "穴・切り抜き")
            legend(.cyan, "曲げ線(切らない)")
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
    @Environment(\.dismiss) private var dismiss
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
                PreviewLegend()
                Toggle("穴の位置(X, Y)を表示", isOn: $showPositions).padding(.horizontal)
                Text("展開寸法 \(Fmt.num(built.width)) × \(Fmt.num(built.height)) mm ・ 穴 \(built.holeLabels.count)個 ・ 原点は左下")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("拡大を戻す") { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    .font(.footnote)
            }
            .padding(.vertical)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }
    }
}
