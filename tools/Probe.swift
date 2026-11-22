import Foundation
import ImageIO
@main struct Probe {
 static func main() async throws {
  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
  let image = CGImageSourceCreateImageAtIndex(source,0,nil)!
  let result = try await OfflineVision.analyze(cgImage:image)
  print("OUT", result.ordinateDrawing?.width ?? 0,result.ordinateDrawing?.height ?? 0,result.ordinateDrawing?.thickness ?? 0)
  for h in result.ordinateDrawing?.holes ?? [] { print("HOLE",h.x,h.y,h.diameter) }
  for c in result.candidates where c.rectangle.midY > 0.28 && c.rectangle.midY < 0.72 && c.text.count < 14 && c.text.range(of:#"^[0-9OoxXCcMmφΦØø⌀. ×*—−‐()°-]+$"#,options:.regularExpression) != nil {
    print(String(format:"LABEL %@ %.3f %.3f %.3f %.3f %.2f",c.text,c.rectangle.midX,c.rectangle.midY,c.rectangle.width,c.rectangle.height,c.confidence))
  }
 }
}
