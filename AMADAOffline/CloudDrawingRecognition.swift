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
    You are reading a photographed Japanese manufacturing drawing.
    Return a single valid JSON object, with no Markdown, in this exact format:
    {"width":null,"height":null,"thickness":null,"chamfer":null,
    "material":null,"drawing_number":null,
    "holes":[],"warnings":[],"read_numbers":[]}
    Lengths are in millimeters. X and Y must use a documented lower-left origin.
    Only return numbers explicitly established by dimension lines or ordinate
    coordinates AND the associated identifiable hole. Do not estimate pixels.
    Detect and match diameter callouts to their holes; if a callout is shared by
    multiple holes, count only those with verifiable centers.
    Do not confuse diameter symbols, quantity, or thread with hole coordinates.
    Unknown or ambiguous measurements MUST be null, never guessed.
    When no center or diameter is identifiable, do not invent a hole.
    All identifiable hole candidates must have x,y,diameter keys; max 150.
    A valid ordinate zero (X=0 or Y=0) is allowed if explicitly marked.
    The center coordinates and hole diameters must use the same millimeter units.
    Also return read_numbers: an array of the exact dimension and hole callout texts
    legible in the photographed drawing, in approximate page reading order.
    Include Japanese warnings describing any uncertainty, missing axes or omitted holes.
    Never generate cutting code, NC code, or machine operation instructions.
    """

    static func analyze(_ photo: UIImage) async throws -> AIResult {
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
        let response = try await model.generateContent(photo, drawingPrompt)
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
