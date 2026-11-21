import Foundation
import Vision
import UIKit

// All processing stays on-device. No API keys, server or network requests.
enum OfflineVision {
    static func analyze(image: UIImage) async throws -> RecognitionResult {
        guard let cgImage = image.cgImage else { throw NSError(domain: "AMADA", code: 1, userInfo: [NSLocalizedDescriptionKey: "JPEGまたはPNG画像を選んでください"]) }
        return try await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.recognitionLanguages = ["ja-JP", "en-US"]
            let rectangles = VNDetectRectanglesRequest()
            rectangles.maximumObservations = 8
            rectangles.minimumConfidence = 0.55
            rectangles.minimumAspectRatio = 0.1
            rectangles.maximumAspectRatio = 1.0
            let contours = VNDetectContoursRequest()
            contours.contrastAdjustment = 1.0
            contours.detectsDarkOnLight = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([text, rectangles, contours])
            let candidates: [OCRCandidate] = (text.results ?? []).compactMap { item in
                guard let top = item.topCandidates(1).first else { return nil }
                return OCRCandidate(text: top.string, confidence: top.confidence, rectangle: item.boundingBox)
            }
            // This is only a bounding-box candidate. Dimension/leader lines may be mistaken for an outline.
            let rect = (rectangles.results ?? []).max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            })?.boundingBox
            let circles = Self.circleCandidates(from: contours.results ?? [], imageWidth: Double(cgImage.width), imageHeight: Double(cgImage.height))
            return RecognitionResult(candidates: candidates, rectangle: rect, circles: circles,
                                     diagnostics: "文字候補\(candidates.count)件・矩形候補\((rectangles.results ?? []).count)件・丸穴候補\(circles.count)件")
        }.value
    }

    // Contour geometry only provides suggestions. Dimensions are never inferred
    // from pixels alone. Reject open, non-circular, tiny and duplicate contours.
    private static func circleCandidates(from observations: [VNContoursObservation], imageWidth: Double, imageHeight: Double) -> [CircleCandidate] {
        var output: [CircleCandidate] = []
        func walk(_ contour: VNContour) {
            let points = (0..<contour.pointCount).map { contour.normalizedPoints[$0] }
            if points.count >= 14 {
                let minX = Double(points.map(\.x).min() ?? 0)
                let maxX = Double(points.map(\.x).max() ?? 0)
                let minY = Double(points.map(\.y).min() ?? 0)
                let maxY = Double(points.map(\.y).max() ?? 0)
                let rx = (maxX - minX) / 2, ry = (maxY - minY) / 2
                // Vision coordinates are normalized independently along x and y.
                // Compare actual pixel radii, or circles in portrait images get rejected.
                let pixelRX = rx * imageWidth, pixelRY = ry * imageHeight
                if rx > 0.005, ry > 0.005, rx < 0.25, ry < 0.25,
                   pixelRX > 3, pixelRY > 3,
                   abs(pixelRX - pixelRY) / max(pixelRX, pixelRY) < 0.22 {
                    let cx = (minX+maxX)/2, cy = (minY+maxY)/2
                    // Radial consistency with expected ellipse in normalized coordinates.
                    let errors = points.map { point -> Double in
                        let dx = (Double(point.x)-cx)/rx
                        let dy = (Double(point.y)-cy)/ry
                        return abs(sqrt(dx*dx+dy*dy)-1)
                    }
                    let residual = errors.reduce(0,+)/Double(errors.count)
                    let first=points[0], last=points[points.count-1]
                    let closing = hypot(Double(first.x-last.x)/rx,Double(first.y-last.y)/ry)
                    if residual < 0.17 && closing < 0.52 {
                        let candidate = CircleCandidate(center: CGPoint(x: cx,y:cy),radiusX:rx,radiusY:ry,confidence:max(0,1-residual))
                        let isDuplicate = output.contains { old in
                            hypot(old.center.x-candidate.center.x,old.center.y-candidate.center.y) < max(rx,ry)*0.30 &&
                            abs(old.radiusX-rx) < rx*0.3
                        }
                        if !isDuplicate { output.append(candidate) }
                    }
                }
            }
            for child in contour.childContours { walk(child) }
        }
        for observation in observations {
            for contour in observation.topLevelContours { walk(contour) }
        }
        return Array(output.sorted { $0.center.x < $1.center.x }.prefix(100))
    }
}
