import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#endif
import CoreImage

// All processing stays on-device. No API keys, server or network requests.
enum OfflineVision {
    #if canImport(UIKit)
    static func analyze(image: UIImage) async throws -> RecognitionResult {
        guard let cgImage = image.cgImage else { throw NSError(domain: "AMADA", code: 1, userInfo: [NSLocalizedDescriptionKey: "JPEGまたはPNG画像を選んでください"]) }
        return try await analyze(cgImage:cgImage)
    }
    #endif

    static func analyze(cgImage: CGImage) async throws -> RecognitionResult {
        return try await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.recognitionLanguages = ["ja-JP", "en-US"]
            let rectangles = VNDetectRectanglesRequest()
            rectangles.maximumObservations = 32
            rectangles.minimumSize = 0.025
            rectangles.minimumConfidence = 0.55
            rectangles.minimumAspectRatio = 0.035
            rectangles.maximumAspectRatio = 1.0
            let contours = VNDetectContoursRequest()
            contours.maximumImageDimension = 2048
            contours.contrastAdjustment = 1.0
            contours.detectsDarkOnLight = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            // Some runtimes cannot service contours. Keep independent text results in that case.
            #if os(macOS)
            for request: VNRequest in [text, rectangles, contours] { request.usesCPUOnly = true }
            #endif
            try handler.perform([text])
            try? handler.perform([rectangles])
            try? handler.perform([contours])
            var candidates: [OCRCandidate] = (text.results ?? []).compactMap { item in
                guard let top = item.topCandidates(1).first else { return nil }
                return OCRCandidate(text: top.string, confidence: top.confidence, rectangle: item.boundingBox)
            }
            // A second contrast-enhanced pass can recover faint dimension labels.
            // Both passes share the same pixel coordinate space and are merged by
            // geometry, preferring the more confident text at the same location.
            if let enhanced = Self.enhanceForText(cgImage) {
                let retry = VNRecognizeTextRequest()
                #if os(macOS)
                retry.usesCPUOnly = true
                #endif
                retry.recognitionLevel = .accurate
                retry.usesLanguageCorrection = false
                retry.recognitionLanguages = ["ja-JP", "en-US"]
                retry.minimumTextHeight = 0.003
                let retryHandler = VNImageRequestHandler(cgImage: enhanced, options: [:])
                try? retryHandler.perform([retry])
                for observation in retry.results ?? [] {
                    guard let top = observation.topCandidates(1).first else { continue }
                    let item = OCRCandidate(text: top.string, confidence: top.confidence, rectangle: observation.boundingBox)
                    if let index = candidates.firstIndex(where: {
                        let intersection = $0.rectangle.intersection(item.rectangle)
                        let area = max(0, intersection.width) * max(0, intersection.height)
                        let minimum = min($0.rectangle.width * $0.rectangle.height,
                                          item.rectangle.width * item.rectangle.height)
                        return minimum > 0 && area / minimum > 0.60
                    }) {
                        if item.confidence > candidates[index].confidence { candidates[index] = item }
                    } else {
                        candidates.append(item)
                    }
                }
            }
            // Rotated, overlapping crops retain tiny ordinate labels on phone photos.
            let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
            let tileContext = CIContext(options: [.cacheIntermediates:false])
            for x in [0.0,0.44] {
                for y in [0.0,0.44] {
                    let crop = CGRect(x:x*width,y:y*height,width:0.56*width,height:0.56*height).integral
                        .intersection(CGRect(x:0,y:0,width:width,height:height))
                    guard let tile = cgImage.cropping(to:crop) else { continue }
                    let magnification = min(3.0, 1500.0/Double(max(tile.width,tile.height)))
                    var ocrTile = tile
                    if magnification > 1.1 {
                        let enlarged = CIImage(cgImage:tile).applyingFilter("CILanczosScaleTransform",
                            parameters:[kCIInputScaleKey:magnification,kCIInputAspectRatioKey:1.0])
                        ocrTile = tileContext.createCGImage(enlarged,from:enlarged.extent) ?? tile
                    }
                    for rotated in [false,true] {
                        let request = VNRecognizeTextRequest()
                        #if os(macOS)
                        request.usesCPUOnly = true
                        #endif
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = false
                        request.recognitionLanguages = ["en-US","ja-JP"]
                        request.minimumTextHeight = 0.003
                        try? VNImageRequestHandler(cgImage:ocrTile,orientation:rotated ? .right : .up,options:[:]).perform([request])
                        for observation in request.results ?? [] {
                            guard let token = observation.topCandidates(1).first else { continue }
                            let b = observation.boundingBox
                            let local = rotated ? CGRect(x:1-b.maxY,y:b.minX,width:b.height,height:b.width) : b
                            let box = CGRect(x:(crop.minX+crop.width*local.minX)/width,
                                             y:1-crop.maxY/height+local.minY*crop.height/height,
                                             width:local.width*crop.width/width,height:local.height*crop.height/height)
                            if !candidates.contains(where: { $0.text == token.string && $0.rectangle.intersects(box) }) {
                                candidates.append(OCRCandidate(text:token.string,confidence:token.confidence,rectangle:box))
                            }
                        }
                    }
                }
            }
            // This is only a bounding-box candidate. Dimension/leader lines may be mistaken for an outline.
            let rect = (rectangles.results ?? []).max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            })?.boundingBox
            let circles = Self.circleCandidates(from: contours.results ?? [], imageWidth: Double(cgImage.width), imageHeight: Double(cgImage.height))
            return RecognitionResult(candidates: candidates, rectangle: rect, circles: circles,
                                     ordinateDrawing: OrdinateReader.read(candidates, circles: circles, views: (rectangles.results ?? []).map(\.boundingBox), raster: RingImage(cgImage)),
                                     diagnostics: "文字候補\(candidates.count)件・矩形候補\((rectangles.results ?? []).count)件・丸穴候補\(circles.count)件")
        }.value
    }

    private static func enhanceForText(_ original: CGImage) -> CGImage? {
        let input = CIImage(cgImage: original)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        filter.setValue(1.65, forKey: kCIInputContrastKey)
        filter.setValue(0.035, forKey: kCIInputBrightnessKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(output, from: input.extent)
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
                if rx > 0.0008, ry > 0.0008, rx < 0.25, ry < 0.25,
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

// Ordinate drawings print absolute coordinates in a row and a column.
// Accept an axis only when the printed values describe a consistent scale.
private enum OrdinateReader {
    struct Mark {
        let value: Double
        let box: CGRect
        func along(_ horizontal: Bool) -> Double { horizontal ? box.midX : box.midY }
        func across(_ horizontal: Bool) -> Double { horizontal ? box.midY : box.midX }
    }
    struct Axis {
        let marks: [Mark]
        let zero: Double
        let scale: Double
        let extent: Double
        func nearest(_ p: Double) -> Mark? {
            let sorted = marks.filter { $0.value > 0 && $0.value < extent }.sorted {
                abs($0.value - (p-zero)/scale) < abs($1.value - (p-zero)/scale)
            }
            guard let first = sorted.first else { return nil }
            let error = abs(p-zero-first.value*scale)
            guard error < abs(scale)*extent*0.075,
                  sorted.dropFirst().first.map({ error < abs(p-zero-$0.value*scale)*0.70 }) ?? true else { return nil }
            return first
        }
    }

    static func axis(_ marks: [Mark], horizontal: Bool) -> Axis? {
        var choices: [Axis] = []
        for origin in marks where origin.value == 0 {
            let band = horizontal ? origin.box.height : origin.box.width
            let nearby = marks.filter { abs($0.across(horizontal)-origin.across(horizontal)) < min(0.045,max(0.014,band*1.7)) }
            for end in nearby where end.value > 0 {
                let span = end.along(horizontal)-origin.along(horizontal)
                guard span > 0.055 else { continue }
                let scale = span/end.value
                let matching = nearby.filter { m in
                    m.value >= 0 && m.value <= end.value &&
                    abs(m.along(horizontal)-origin.along(horizontal)-m.value*scale) < max(0.005,span*0.055)
                }
                let unique = Dictionary(grouping: matching, by: { $0.value }).compactMap { _, group in
                    group.min { abs($0.along(horizontal)-origin.along(horizontal)-$0.value*scale) <
                                abs($1.along(horizontal)-origin.along(horizontal)-$1.value*scale) }
                }
                if unique.count >= 4 {
                    choices.append(Axis(marks: unique, zero: origin.along(horizontal), scale: scale, extent: end.value))
                }
            }
        }
        if choices.isEmpty {
            for start in marks where start.value > 0 {
                let band = horizontal ? start.box.height : start.box.width
                let nearby = marks.filter { abs($0.across(horizontal)-start.across(horizontal)) < min(0.04,max(0.012,band*1.5)) }
                for end in nearby where end.value > start.value {
                    let scale = (end.along(horizontal)-start.along(horizontal))/(end.value-start.value)
                    let zero = start.along(horizontal)-start.value*scale
                    guard scale > 0, zero >= 0, end.value*scale > 0.055 else { continue }
                    let fits = nearby.filter {
                        $0.value > 0 && $0.value <= end.value &&
                        abs($0.along(horizontal)-zero-$0.value*scale) < max(0.004,end.value*scale*0.025)
                    }
                    let unique = Dictionary(grouping:fits,by:{ $0.value }).compactMap { $0.value.first }
                    guard unique.count >= 3, marks.contains(where:{ other in
                        other.value == end.value && abs(other.across(horizontal)-end.across(horizontal)) > 0.05 &&
                        abs(other.along(horizontal)-zero-end.value*scale/2) < end.value*scale*0.24
                    }) else { continue }
                    choices.append(Axis(marks:unique,zero:zero,scale:scale,extent:end.value))
                }
            }
        }
        let ranked = choices.sorted { $0.marks.count > $1.marks.count }
        guard let best = ranked.first, ranked.filter({ $0.marks.count == best.marks.count }).allSatisfy({
            $0.extent == best.extent && abs($0.zero-best.zero) < 0.01
        }) else { return nil }
        // A jogged leader can move a printed ordinate away from the centreline.
        guard let origin = best.marks.first(where: { $0.value == 0 }) else { return best }
        let span = best.extent*best.scale
        let band = horizontal ? origin.box.height : origin.box.width
        var recovered = best.marks
        for mark in marks where mark.value > 0 && mark.value < best.extent {
            guard !recovered.contains(where: { $0.value == mark.value }),
                  abs(mark.across(horizontal)-origin.across(horizontal)) < min(0.045,max(0.014,band*1.7)),
                  abs(mark.along(horizontal)-best.zero-mark.value*best.scale) < span*0.16,
                  best.marks.allSatisfy({ ($0.value-mark.value)*($0.along(horizontal)-mark.along(horizontal)) > 0 }) else { continue }
            recovered.append(mark)
        }
        return Axis(marks:recovered,zero:best.zero,scale:best.scale,extent:best.extent)
    }

    struct Callout {
        let count: Int
        let diameter: Double
        let thread: Bool
    }
    static func read(_ labels: [OCRCandidate], circles: [CircleCandidate], views: [CGRect], raster: RingImage?) -> Drawing? {
        // Short and rotated dimension labels often receive a low text score.
        // Numeric candidates additionally need a spatial fit on the scale and
        // a detected ring before they can appear in a hole row.
        let labels = labels.filter { candidate in
            if candidate.confidence >= 0.5 { return true }
            let token = candidate.text.precomposedStringWithCompatibilityMapping
            return candidate.confidence >= 0.25 &&
                (["O","o","〇"].contains(token) ||
                 token.range(of: #"^\d{1,4}(?:\.\d{1,3})?$"#,options:.regularExpression) != nil)
        }
        func clean(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: " ", with: "") }
        let marks: [Mark] = labels.compactMap {
            let text = clean($0.text)
            let s = ["O","o","〇"].contains(text) ? "0" : text
            guard s.range(of: #"^\d{1,4}(?:\.\d{1,3})?$"#, options: .regularExpression) != nil,
                  let v = Double(s) else { return nil }
            return Mark(value: v, box: $0.rectangle)
        }
        guard let x = axis(marks, horizontal: true), let y = axis(marks, horizontal: false) else { return nil }
        // An independent overall dimension must repeat the last ordinate.
        func corroborated(_ a: Axis, horizontal: Bool) -> Bool {
            guard let first = a.marks.first else { return false }
            return marks.contains { m in
                m.value == a.extent && abs(m.across(horizontal)-first.across(horizontal)) > 0.045 &&
                abs(m.along(horizontal)-(a.zero+a.scale*a.extent*0.5)) < a.scale*a.extent*0.32
            }
        }
        let outlineRepeated = corroborated(x,horizontal:true) && corroborated(y,horizontal:false)
        var draft = Drawing()
        draft.width = x.extent
        draft.height = y.extent
        let right = x.zero+x.scale*x.extent
        let top = y.zero+y.scale*y.extent
        // Match a thickness dimension below a separate, aligned narrow side view.
        var thicknesses = Set<Double>()
        for view in views where view.minX > right && abs(view.minY-y.zero) < y.scale*y.extent*0.15 &&
            abs(view.maxY-top) < y.scale*y.extent*0.15 {
            let geometric = view.width/x.scale
            for m in marks where m.value > 0 && abs(m.value-geometric) < geometric*0.17 &&
                m.box.midY < view.minY && view.minY-m.box.midY < view.height*0.65 &&
                abs(view.midX-m.box.midX) < view.width*3 {
                thicknesses.insert(m.value)
            }
        }
        if thicknesses.count == 1 { draft.thickness = thicknesses.first ?? 0 }
        let pattern = #"^(?:(\d{1,2})[-‐‑–—−×])?([φΦØø⌀Mm])(\d+(?:\.\d+)?)(?:[xX×](\d+(?:\.\d+)?))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return draft }
        var groups: [Callout] = []
        var groupBoxes: [CGRect] = []
        for label in labels {
            let original = clean(label.text)
            // OCR may read the crossed diameter glyph as zero after a quantity.
            // Keep this substitution confined to counted callouts backed by a measured ring.
            let s = original.replacingOccurrences(of: #"^(\d{1,2}[-‐−])0(?=[1-9]\d*(?:\.\d+)?$)"#,
                                                  with:"$1Ø",options:.regularExpression)
            guard let match = re.firstMatch(in:s,range:NSRange(s.startIndex...,in:s)) else { continue }
            func field(_ n: Int) -> String? { Range(match.range(at:n),in:s).map { String(s[$0]) } }
            guard let nominal = Double(field(3) ?? ""), nominal > 0 else { continue }
            let thread = field(2)?.uppercased() == "M"
            // Only this explicitly supported coarse thread has a cutting-tap pilot suggestion.
            if thread && !(nominal == 3 && Double(field(4) ?? "") == 0.5) { continue }
            let count = Int(field(1) ?? "1") ?? 1
            let diameter = thread ? 2.5 : nominal
            let repeated = groups.indices.contains { groups[$0].count == count && groups[$0].diameter == diameter && groupBoxes[$0].intersects(label.rectangle) }
            if count > 0 && !repeated {
                groups.append(Callout(count:count, diameter:diameter, thread:thread))
                groupBoxes.append(label.rectangle)
            }
        }
        var registration = CGPoint.zero
        for group in groups.sorted(by: { $0.diameter > $1.diameter }) {
            var matched: [String:Hole] = [:]
            var offsets: [CGPoint] = []
            for circle in circles {
                guard circle.center.x > x.zero, circle.center.x < right, circle.center.y > y.zero, circle.center.y < top,
                      let mx = x.nearest(circle.center.x-registration.x), let my = y.nearest(circle.center.y-registration.y) else { continue }
                let size = (circle.radiusX/x.scale + circle.radiusY/y.scale)
                let possible = groups.filter { abs(size-$0.diameter) < $0.diameter*0.30 }
                guard possible.count == 1, possible[0].diameter == group.diameter else { continue }
                matched["\(mx.value),\(my.value)"] = Hole(x:mx.value,y:my.value,diameter:group.diameter)
            }
            // Crosshairs can split the circumference into four separate contours.
            // Check the actual image for a dark annulus at a printed coordinate pair.
            if let raster, x.marks.count*y.marks.count < 500 {
                for mx in x.marks where mx.value > 0 && mx.value < x.extent {
                    for my in y.marks where my.value > 0 && my.value < y.extent {
                        let key = "\(mx.value),\(my.value)"

                        let predicted = CGPoint(x:x.zero+mx.value*x.scale,y:y.zero+my.value*y.scale)
                        let otherX = x.marks.filter { $0.value != mx.value }.map { abs($0.value-mx.value) }.min() ?? x.extent
                        let otherY = y.marks.filter { $0.value != my.value }.map { abs($0.value-my.value) }.min() ?? y.extent
                        let registered = CGPoint(x:predicted.x+registration.x,y:predicted.y+registration.y)
                        if let center = raster.ringCenter(at:registered, radius:group.diameter*x.scale*Double(raster.width)/2,
                                          dx:min(otherX*0.47,x.extent*0.035)*x.scale*Double(raster.width),
                                          dy:min(otherY*0.47,y.extent*0.06)*y.scale*Double(raster.height)) {
                            offsets.append(CGPoint(x:center.x-predicted.x,y:center.y-predicted.y))
                            matched[key] = Hole(x:mx.value,y:my.value,diameter:group.diameter)
                        }
                    }
                }
            }
            for hole in draft.holes { matched.removeValue(forKey: "\(hole.x),\(hole.y)") }
            if !matched.isEmpty && matched.count <= group.count {
                if offsets.count == group.count && group.count >= 2 {
                    let xx = offsets.map(\.x).sorted(), yy = offsets.map(\.y).sorted()
                    if let xmin = xx.first, let xmax = xx.last, let ymin = yy.first, let ymax = yy.last,
                       xmax-xmin < x.scale*x.extent*0.04 && ymax-ymin < y.scale*y.extent*0.07 {
                        registration = CGPoint(x:(xx[(xx.count-1)/2]+xx[xx.count/2])/2,y:(yy[(yy.count-1)/2]+yy[yy.count/2])/2)
                    }
                }
                let partial = matched.count < group.count || !outlineRepeated
                draft.holes += matched.values.sorted { ($0.x,$0.y) < ($1.x,$1.y) }.map { hole in
                    var row = hole
                    row.xSuggested = partial
                    row.ySuggested = partial
                    row.diameterSuggested = group.thread
                    return row
                }
                if group.thread { draft.notes = "M3×0.5の下穴は切削タップ用の候補φ2.5。加工方法と指定径を確認してください。" }
            }
        }
        // Keep a located hole even when the photograph lost the diameter callout.
        // Leave its diameter blank instead of assigning a size from pixels.
        for circle in circles where circle.confidence >= 0.89 {
            guard let mx = x.nearest(circle.center.x-registration.x),
                  let my = y.nearest(circle.center.y-registration.y),
                  abs(circle.center.x-registration.x-x.zero-mx.value*x.scale) < x.scale*x.extent*0.022,
                  abs(circle.center.y-registration.y-y.zero-my.value*y.scale) < y.scale*y.extent*0.035,
                  !draft.holes.contains(where:{ $0.x == mx.value && $0.y == my.value }) else { continue }
            draft.holes.append(Hole(x:mx.value,y:my.value,xSuggested:true,ySuggested:true,diameterSuggested:true,diameter:0))
        }
        return draft
    }
}

private struct RingImage {
    let width: Int
    let height: Int
    let gray: [UInt8]
    private static let directions = (0..<16).map { i -> CGPoint in
        let angle = (Double(i)+0.5)*Double.pi/8
        return CGPoint(x:cos(angle),y:sin(angle))
    }

    init?(_ image: CGImage) {
        let scale = min(1,1600/Double(max(image.width,image.height)))
        let w = Int(Double(image.width)*scale), h = Int(Double(image.height)*scale)
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating:255,count:w*h)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,
                                      bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0) else { return false }
            ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            return true
        }
        guard rendered else { return nil }
        width = w
        height = h
        gray = pixels
    }

    func ringCenter(at point: CGPoint, radius: Double, dx: Double, dy: Double) -> CGPoint? {
        var bestScore = 0
        var best: CGPoint?
        guard radius >= 2, radius <= 80 else { return nil }
        let cx = Int(point.x*Double(width)), cy = Int((1-point.y)*Double(height))
        let sx = min(32,Int(dx)), sy = min(24,Int(dy))
        for y in stride(from:cy-sy,through:cy+sy,by:max(1,Int(radius*0.16))) {
            for x in stride(from:cx-sx,through:cx+sx,by:max(1,Int(radius*0.16))) {
                for factor in [0.86,1.0,1.14] {
                    let r = radius*factor
                    let margin = Int(ceil(r*1.65))+1
                    guard x >= margin, y >= margin, x+margin < width, y+margin < height else { continue }
                    var votes = 0, strength = 0
                    for d in Self.directions {
                        func sample(_ distance: Double) -> Int {
                            let px = x+Int((d.x*distance).rounded()), py = y+Int((d.y*distance).rounded())
                            return Int(gray[py*width+px])
                        }
                        let edge = min(sample(r*0.92),sample(r*1.08))
                        let contrast = min(sample(r*0.48),sample(r*1.60))-edge
                        if contrast >= 18 { votes += 1; strength += min(contrast,100) }
                    }
                    let score = votes*100+strength
                    if votes >= 12 && score > bestScore {
                        bestScore = score
                        best = CGPoint(x:Double(x)/Double(width),y:1-Double(y)/Double(height))
                    }
                }
            }
        }
        return best
    }
}
