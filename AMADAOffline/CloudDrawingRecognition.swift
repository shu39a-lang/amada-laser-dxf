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
    "holes":[{"x":null,"y":null,"diameter":null}],"warnings":[]}
    Lengths are in millimeters. X and Y must use a documented lower-left origin.
    Only return numbers explicitly established by dimension lines or ordinate
    coordinates AND the associated identifiable hole. Do not estimate pixels.
    Detect and match diameter callouts to their holes; if a callout is shared by
    multiple holes, count only those with verifiable centers.
    Do not confuse diameter symbols, quantity, or thread with hole coordinates.
    Unknown or ambiguous measurements MUST be null, never guessed.
    All holes must have x,y,diameter keys; max 150.
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
        return try JSONDecoder().decode(AIResult.self, from: data)
    }
    static func drawing(from ai: AIResult) -> Drawing {
        var d = Drawing()
        d.width = checked(ai.width)
        d.height = checked(ai.height)
        d.thickness = checked(ai.thickness)
        d.chamfer = checked(ai.chamfer)
        d.material = ai.material ?? ""
        d.drawingNumber = ai.drawing_number ?? ""
        d.notes = (ai.warnings ?? []).prefix(20).joined(separator: "\n")
        d.holes = (ai.holes ?? []).prefix(150).map { h in
            Hole(x: checked(h.x), y: checked(h.y),
                 xSuggested: h.x == nil, ySuggested: h.y == nil,
                 diameterSuggested: h.diameter == nil,
                 diameter: checked(h.diameter))
        }
        d.verified = false
        return d
    }
    private static func checked(_ n: Double?) -> Double {
        guard let n, n.isFinite, n > 0, n <= 100000 else { return 0 }
        return n
    }
}
