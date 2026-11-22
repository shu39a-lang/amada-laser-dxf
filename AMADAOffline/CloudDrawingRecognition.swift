import Foundation
import UIKit
import FirebaseAILogic

// Firebase AI Logic sends images to Gemini through Google's protected Firebase proxy.
// No Google AI API secret or custom Cloud Run endpoint is stored in this app.
enum CloudDrawingRecognition {
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
        var errorDescription: String? {
            "Google AIの結果を解析できませんでした"
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
        let model = FirebaseAI.firebaseAI(backend: .googleAI())
            .generativeModel(modelName: "gemini-3.8-flash")
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
