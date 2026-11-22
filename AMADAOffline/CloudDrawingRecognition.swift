import Foundation
import UIKit
import FirebaseAppCheck

// This client sends a drawing only to the configured SHEET MASTER backend.
// The backend validates Firebase App Check before calling Vertex AI.
// No Google API secrets are embedded in this application.
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
        let material: String
        let drawing_number: String
        let holes: [AIHole]
        let warnings: [String]
        let verified: Bool
    }
    enum RecognitionError: LocalizedError {
        case missingEndpoint
        case invalidResponse
        case httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .missingEndpoint: return "Google AI接続先はまだ設定されていません"
            case .invalidResponse: return "Google AIから正しい読み取り結果を受信できませんでした"
            case .httpStatus(let code): return "Google AIの接続エラー（\(code)）"
            }
        }
    }
    static var isConfigured: Bool {
        endpoint != nil
    }
    private static var endpoint: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "SHEET_MASTER_API_URL") as? String,
              !string.isEmpty, let url = URL(string: string),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    static func analyze(_ photo: UIImage) async throws -> AIResult {
        guard let base = endpoint else { throw RecognitionError.missingEndpoint }
        guard let data = photo.jpegData(compressionQuality: 0.85), data.count <= 8_000_000 else {
            throw RecognitionError.invalidResponse
        }
        let token = try await AppCheck.appCheck().token(forcingRefresh: false)
        let payload: [String: String] = [
            "image_base64": data.base64EncodedString(),
            "mime_type": "image/jpeg"
        ]
        var request = URLRequest(url: base.appendingPathComponent("recognize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 45
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RecognitionError.invalidResponse }
        guard http.statusCode == 200 else { throw RecognitionError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(AIResult.self, from: responseData)
    }
    static func drawing(from ai: AIResult) -> Drawing {
        var result = Drawing()
        // Nulls remain empty: never turn an uncertain AI answer into a manufacturing dimension.
        result.width = valid(ai.width)
        result.height = valid(ai.height)
        result.thickness = valid(ai.thickness)
        result.chamfer = valid(ai.chamfer)
        result.material = ai.material
        result.drawingNumber = ai.drawing_number
        result.notes = ai.warnings.joined(separator: "\n")
        result.holes = ai.holes.prefix(150).map { hole in
            Hole(x: valid(hole.x), y: valid(hole.y),
                 xSuggested: hole.x == nil, ySuggested: hole.y == nil,
                 diameterSuggested: hole.diameter == nil,
                 diameter: valid(hole.diameter))
        }
        result.verified = false
        return result
    }
    private static func valid(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0, value <= 100000 else { return 0 }
        return value
    }
}
