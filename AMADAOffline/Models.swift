import Foundation

struct Hole: Identifiable, Codable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var xSuggested: Bool? = nil
    var ySuggested: Bool? = nil
    var diameterSuggested: Bool? = nil
    var diameter: Double
}

struct Drawing: Codable {
    var companyName: String = ""
    var partName: String = ""
    var revision: String = ""
    var quantity: String = ""
    var machineType: String = "未指定"
    var notes: String = ""
    var drawingNumber: String = ""
    var material: String = ""
    var thickness: Double = 0
    var width: Double = 0
    var height: Double = 0
    var chamfer: Double = 0
    var holes: [Hole] = []
    var verified = false

    var issues: [String] {
        var errors: [String] = []
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return ["外形の幅と高さを入力してください"] }
        if !thickness.isFinite || thickness <= 0 { errors.append("板厚が未入力です") }
        if !chamfer.isFinite || chamfer < 0 || chamfer * 2 >= min(width, height) { errors.append("角Cの値が不正です") }
        for (i, hole) in holes.enumerated() {
            guard hole.x.isFinite, hole.y.isFinite, hole.diameter.isFinite, hole.diameter > 0 else {
                errors.append("穴\(i + 1)の数値が不正です"); continue
            }
            let radius = hole.diameter / 2
            if hole.x - radius < 0 || hole.x + radius > width || hole.y - radius < 0 || hole.y + radius > height {
                errors.append("穴\(i + 1)が外形からはみ出しています")
            }
        }
        // Overlapping cuts are not a valid hole pattern for the basic DXF exporter.
        for i in holes.indices {
            for j in holes.indices where j > i {
                let a = holes[i], b = holes[j]
                guard a.x.isFinite, a.y.isFinite, a.diameter.isFinite,
                      b.x.isFinite, b.y.isFinite, b.diameter.isFinite else { continue }
                let distance = hypot(a.x - b.x, a.y - b.y)
                if distance < (a.diameter + b.diameter) / 2 {
                    errors.append("穴\(i + 1)と穴\(j + 1)が重なっています")
                }
            }
        }
        // A round hole must remain entirely inside all four chamfer half-planes.
        // Testing only when the hole centre is inside the corner square misses
        // large holes whose edges intersect a chamfer from farther away.
        if chamfer.isFinite, chamfer > 0, chamfer * 2 < min(width, height) {
            for (index, hole) in holes.enumerated() {
                guard hole.x.isFinite, hole.y.isFinite,
                      hole.diameter.isFinite, hole.diameter > 0 else { continue }
                let r = hole.diameter / 2
                let cornerClearances = [
                    (hole.x + hole.y - chamfer) / sqrt(2),
                    (width - hole.x + hole.y - chamfer) / sqrt(2),
                    (width - hole.x + height - hole.y - chamfer) / sqrt(2),
                    (hole.x + height - hole.y - chamfer) / sqrt(2)
                ]
                if cornerClearances.contains(where: { $0 < r - 0.000001 }) {
                    errors.append("穴\(index + 1)が角Cの加工線と干渉します")
                }
            }
        }
        return errors
    }
}

struct OCRCandidate: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float
    let rectangle: CGRect // Vision coordinates (origin at lower left)
}

struct CircleCandidate: Identifiable {
    let id = UUID()
    // Normalized Vision image coordinates; left-bottom origin (0...1).
    let center: CGPoint
    let radiusX: Double
    let radiusY: Double
    let confidence: Double
}

struct RecognitionResult {
    let candidates: [OCRCandidate]
    let rectangle: CGRect?
    let circles: [CircleCandidate]
    var ordinateDrawing: Drawing? = nil
    let diagnostics: String
}
