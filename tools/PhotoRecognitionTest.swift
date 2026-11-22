import Foundation
import ImageIO
@main struct PhotoRecognitionTest {
    static func main() async {
        do { try await compare() }
        catch {
            FileHandle.standardError.write(Data("::error::Recognition test failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func compare() async throws {
        let url = URL(fileURLWithPath:CommandLine.arguments[1])
        let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
        let raster = CGImageSourceCreateImageAtIndex(source,0,nil)!
        let result = try await OfflineVision.analyze(cgImage:raster)
        let drawing = result.ordinateDrawing
        let rows = drawing?.holes ?? []
        // Hole-count matching alone can conceal an incorrect overall scale.
        // The seven-hole reference drawing explicitly measures 150 x 35 mm.
        if !CommandLine.arguments.contains("--alternate") {
            guard drawing?.width == 150, drawing?.height == 35 else {
                throw NSError(domain: "RecognitionTest", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Reference overall dimensions must be 150 x 35 mm; got \(String(describing: drawing?.width)) x \(String(describing: drawing?.height))"])
            }
        }
        let expected = CommandLine.arguments.contains("--alternate") ? [(12.0,30.0,8.0),(117,30,8),(36,9,2.5),(78,17,2.5)] : [(15.0,28.0,6.5),(135,28,6.5),(23.5,10,2.5),(44.5,10,2.5),(68,23,2.5),(75,23,2.5),(113,23,2.5)]
        guard rows.count == expected.count && zip(rows,expected).allSatisfy({ row,target in
            row.x == target.0 && row.y == target.1 && row.diameter == target.2
        }) else {
            let labels = result.candidates.map { String(format:"%@(%0.3f,%0.3f,%0.2f)",$0.text,$0.rectangle.midX,$0.rectangle.midY,$0.confidence) }.joined(separator:" ")
            let actual = rows.map { String(describing: $0) }.joined(separator:" ")
            FileHandle.standardError.write(Data("::error::Drawing: \(String(describing:result.ordinateDrawing)). Rows: \(actual). OCR: \(labels)\n".utf8))
            throw NSError(domain:"RecognitionTest",code:1)
        }
        print("All \(rows.count) rows matched from image pixels.")
    }
}
