import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// v2.2 で読めなかった主な原因への対策:
///  1. iPhoneの写真(4032×3024)を丸ごと送ると、APIの内部で約1568pxに縮小され、小さい寸法数字が潰れる
///  2. 画像が大きすぎる(5MB超)とAPIエラーになる
/// → 「全体1枚 + 拡大タイル(2×2 or 3×3、重なり付き)」に分け、各画像を1568px以内・JPEGで送る
struct PreparedImage {
    let label: String
    let jpeg: Data
}

enum ImagePreprocessor {
    static let maxEdge: CGFloat = 1568
    private static let ctx = CIContext()

    static func prepare(_ images: [UIImage], grid: Int) -> [PreparedImage] {
        var out: [PreparedImage] = []
        // 1リクエストの画像上限(20枚)を超えないように、写真が多いときはタイルを減らす
        let perPhoto = 1 + grid * grid
        let effectiveGrid = images.count * perPhoto > 20 ? 2 : grid
        for (pi, raw) in images.enumerated() {
            let img = normalized(raw)
            let photoNo = pi + 1
            if let full = jpeg(resized(img, maxEdge: maxEdge), quality: 0.85) {
                out.append(PreparedImage(label: "写真\(photoNo)・全体", jpeg: full))
            }
            if images.count * (1 + effectiveGrid * effectiveGrid) > 20 { continue } // それでも多いときは全体のみ
            let enhanced = enhance(img) ?? img
            for t in tiles(enhanced, grid: effectiveGrid) {
                if let d = jpeg(resized(t.image, maxEdge: maxEdge), quality: 0.85) {
                    out.append(PreparedImage(label: "写真\(photoNo)・拡大\(t.name)", jpeg: d))
                }
            }
        }
        return out
    }

    /// 向きを正す(EXIFの回転を反映)
    static func normalized(_ img: UIImage) -> UIImage {
        if img.imageOrientation == .up { return img }
        let r = UIGraphicsImageRenderer(size: img.size, format: fmt(scale: img.scale))
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
    }

    static func resized(_ img: UIImage, maxEdge: CGFloat) -> UIImage {
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        let s = min(1, maxEdge / max(w, h))
        if s >= 1 { return img }
        let size = CGSize(width: floor(w * s), height: floor(h * s))
        let r = UIGraphicsImageRenderer(size: size, format: fmt(scale: 1))
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// 白黒化+コントラスト強調(細い線・薄い数字を読みやすく)
    static func enhance(_ img: UIImage) -> UIImage? {
        guard let ci = CIImage(image: img) else { return nil }
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.saturation = 0
        f.contrast = 1.35
        f.brightness = 0.02
        let s = CIFilter.sharpenLuminance()
        s.inputImage = f.outputImage
        s.sharpness = 0.6
        guard let o = s.outputImage, let cg = ctx.createCGImage(o, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    struct Tile { let name: String; let image: UIImage }

    static func tiles(_ img: UIImage, grid: Int) -> [Tile] {
        guard let cg = img.cgImage else { return [] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let overlap: CGFloat = 0.12
        let tw = W / CGFloat(grid) * (1 + overlap), th = H / CGFloat(grid) * (1 + overlap)
        let rowNames = grid == 2 ? ["上", "下"] : ["上", "中", "下"]
        let colNames = grid == 2 ? ["左", "右"] : ["左", "中", "右"]
        var out: [Tile] = []
        for r in 0..<grid {
            for c in 0..<grid {
                let cxc = W * (CGFloat(c) + 0.5) / CGFloat(grid)
                let cyc = H * (CGFloat(r) + 0.5) / CGFloat(grid)
                var rect = CGRect(x: cxc - tw / 2, y: cyc - th / 2, width: tw, height: th)
                rect = rect.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
                if let crop = cg.cropping(to: rect) {
                    out.append(Tile(name: "(\(rowNames[r])\(colNames[c]))", image: UIImage(cgImage: crop)))
                }
            }
        }
        return out
    }

    static func jpeg(_ img: UIImage, quality: CGFloat) -> Data? {
        var q = quality
        var d = img.jpegData(compressionQuality: q)
        // 念のため 3.5MB 以下に抑える(base64で5MB制限)
        while let dd = d, dd.count > 3_500_000, q > 0.3 {
            q -= 0.15
            d = img.jpegData(compressionQuality: q)
        }
        return d
    }

    private static func fmt(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = true
        return f
    }
}
