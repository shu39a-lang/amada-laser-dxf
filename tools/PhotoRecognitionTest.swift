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
        let rows = result.ordinateDrawing?.holes ?? []
        let expected = [(15.0,28.0,6.5),(135,28,6.5),(23.5,10,2.5),(44.5,10,2.5),(68,23,2.5),(75,23,2.5),(113,23,2.5)]
        guard rows.count == expected.count && zip(rows,expected).allSatisfy({ row,target in
            row.x == target.0 && row.y == target.1 && row.diameter == target.2
        }) else {
            let labels = result.candidates.map { $0.text }.joined(separator:" ")
            let actual = rows.map { String(describing: $0) }.joined(separator:" ")
            FileHandle.standardError.write(Data("::error::Rows: \(actual). OCR: \(labels)\n".utf8))
            throw NSError(domain:"RecognitionTest",code:1)
        }
        print("Reference layout: all seven rows matched from image pixels.")
    }
}
