import Foundation
import UIKit
import FirebaseCore
import FirebaseAILogic
import FirebaseAppCheck

enum CloudDrawingRecognition {
    private struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            let confidence: Float
            let box: [CGFloat]
        }
        let words: [Word]
    }

    private static let endpoint = URL(string: "https://sheet-master-ocr-195319181441.asia-northeast1.run.app/v1/ocr")!

    @MainActor
    static func read(_ image: UIImage) async throws -> [OCRCandidate] {
        guard let data = image.jpegData(compressionQuality: 0.92),
              data.count <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        let token = try await AppCheck.appCheck().token(forcingRefresh: false)
        var request = URLRequest(url: endpoint, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue(token.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "CloudVisionOCR", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "図面読み取りサービスが HTTP \(status) を返しました"])
        }
        return try JSONDecoder().decode(Response.self, from: body).words.compactMap { word in
            let b = word.box
            guard !word.text.isEmpty, word.confidence >= 0.65, word.confidence <= 1,
                  b.count == 4, b.allSatisfy({ (0...1).contains($0) }),
                  b[2] > b[0], b[3] > b[1] else { return nil }
            let box = CGRect(x: b[0], y: 1 - b[3], width: b[2] - b[0], height: b[3] - b[1])
            return OCRCandidate(text: word.text, confidence: word.confidence, rectangle: box)
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // Gemini is a backup when the dedicated OCR endpoint is unavailable.
    struct AIHole: Decodable {
        let x: Double?
        let y: Double?
        let diameter: Double?
    }
    struct AIResult: Decodable {
        let width: Double?
        let height: Double?
        let thickness: Double?
        let chamfer: Double?
        let material: String?
        let drawing_number: String?
        let holes: [AIHole]?
        let warnings: [String]?
        let read_numbers: [String]?
    }
    enum RecognitionError: LocalizedError {
        case invalidResponse
        case appCheckFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Google AIの結果を解析できませんでした"
            case .appCheckFailed(let detail):
                return "Firebase App Check認証に失敗しました。\(detail)"
            }
        }
    }

    private static let drawingPrompt = """
    You are an expert at transcribing photographed Japanese sheet-metal engineering drawings.
    Your task is to populate the dimensions table, NOT to describe the picture.
    Work from the ORIGINAL drawing image and use OCR hints only to resolve tiny print.

    Read in this order:
    1. Identify the main front-view part outline. Read its overall horizontal and vertical
       dimensions from extension/dimension lines, NOT from the image's pixel dimensions.
    2. Read plate thickness (板厚, t, THK), material and chamfer (C).
       Japanese title blocks often contain the thickness separately from the front view.
    3. Locate each hole symbol in the front view and read callouts such as
       4-φ10, 7-Φ6, Ø8, M3x0.5. The leading integer is a count, never an X coordinate.
    4. Trace each hole's horizontal and vertical ordinate or chain dimensions to
       the correct center. A dimension printed on a line far from the hole may
       still refer to that hole via an extension line.
    5. Convert chained dimensions to absolute X,Y ONLY when the origin and all
       segments are explicit and unambiguous. Never infer values from pixel spacing.
       X increases rightward, Y upward, both measured from the documented
       lower-left part corner. If the drawing uses another datum, translate it only
       if the change of datum is fully dimensioned.
    6. Match each explicitly dimensioned diameter to its verifiable hole centers.
       Include individually located holes even when their diameter is unknown:
       set diameter:null. Do not create multiple rows just from the quantity note.
       For an explicitly marked hole with known diameter but only one coordinate,
       include x or y as null; do not fill missing values with guessed zeros.

    Respond ONLY as JSON with exactly these keys:
    {"width":null,"height":null,"thickness":null,"chamfer":null,
     "material":null,"drawing_number":null,
     "holes":[{"x":null,"y":null,"diameter":null}],
     "warnings":[],"read_numbers":[]}

    Values are millimeters and JSON numbers, not strings. Hole arrays may be empty
    only when there are no identifiable holes. If any dimension or hole coordinate
    is unreadable or ambiguous, leave THAT value null and explain it in Japanese
    warnings; keep the other confidently readable measurements.
    Return each visible measurement transcription in read_numbers.
    Cross-check hole count against quantity callouts and call out discrepancies.
    Never invent dimensions, infer scale from pixels, or create machine programs.
    Limit hole entries to 150; only include visually identifiable hole candidates.
    """

    static func analyze(_ photo: UIImage, ocrHints: [String] = []) async throws -> AIResult {
        // Firebase AI Logic requires App Check verification; validate it first
        // to distinguish device attestation failures from model/API failures.
        // Never log or expose the token itself.
        do {
            _ = try await AppCheck.appCheck().token(forcingRefresh: false)
        } catch {
            let e = error as NSError
            throw RecognitionError.appCheckFailed("\(e.domain) [\(e.code)]: \(e.localizedDescription)")
        }
        let model = FirebaseAI.firebaseAI(backend: .googleAI(), useLimitedUseAppCheckTokens: true)
            .generativeModel(
                modelName: "gemini-3.8-flash",
                generationConfig: GenerationConfig(
                    responseMIMEType: "application/json"
                )
            )
        // Supply the dedicated OCR's transcriptions as reading aids, not as
        // geometric ground truth. Limit both item count and text length.
        let hints = ocrHints.prefix(160).map { String($0.prefix(80)) }
        let instructions = hints.isEmpty ? drawingPrompt :
            drawingPrompt + "\n\nOCR text hints (not ordered, may contain errors):\n" +
            hints.joined(separator: "\n")
        let response = try await model.generateContent(photo, instructions)
        guard let raw = response.text, !raw.isEmpty else {
            throw RecognitionError.invalidResponse
        }
        // Some model versions wrap JSON in Markdown fences.
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"), start <= end {
            json = String(cleaned[start...end])
        } else {
            throw RecognitionError.invalidResponse
        }
        guard let data = json.data(using: .utf8) else {
            throw RecognitionError.invalidResponse
        }
        let result = try JSONDecoder().decode(AIResult.self, from: data)
        guard let holes = result.holes, holes.count <= 150 else {
            throw RecognitionError.invalidResponse
        }
        return result
    }
    static func drawing(from ai: AIResult) -> Drawing {
        var d = Drawing()
        d.width = checked(ai.width, zeroAllowed: false)
        d.height = checked(ai.height, zeroAllowed: false)
        d.thickness = checked(ai.thickness, zeroAllowed: false)
        d.chamfer = checked(ai.chamfer, zeroAllowed: true)
        d.material = ai.material ?? ""
        d.drawingNumber = ai.drawing_number ?? ""
        d.notes = (ai.warnings ?? []).prefix(20).joined(separator: "\n")
        d.holes = (ai.holes ?? []).prefix(150).map { h in
            Hole(x: checked(h.x, zeroAllowed: true), y: checked(h.y, zeroAllowed: true),
                 xSuggested: !isValid(h.x, zeroAllowed: true),
                 ySuggested: !isValid(h.y, zeroAllowed: true),
                 diameterSuggested: !isValid(h.diameter, zeroAllowed: false),
                 diameter: checked(h.diameter, zeroAllowed: false))
        }
        d.verified = false
        return d
    }
    private static func isValid(_ n: Double?, zeroAllowed: Bool) -> Bool {
        guard let n, n.isFinite, n <= 100000 else { return false }
        return zeroAllowed ? n >= 0 : n > 0
    }
    private static func checked(_ n: Double?, zeroAllowed: Bool) -> Double {
        guard isValid(n, zeroAllowed: zeroAllowed), let n else { return 0 }
        return n
    }
}
