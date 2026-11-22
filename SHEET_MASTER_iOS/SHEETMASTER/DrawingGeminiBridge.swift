import Foundation
import UIKit
import FirebaseCore
import FirebaseAppCheck
import FirebaseAILogic

// Native-only Gemini adapter. The original HTML is deliberately untouched.
enum DrawingGeminiBridge {
    enum BridgeError: LocalizedError {
        case imageMissing, invalidResponse, missingAppConfiguration
        var errorDescription: String? {
            switch self {
            case .imageMissing: return "図面の画像を読み込めませんでした"
            case .invalidResponse: return "AIから正しい図面データが返りませんでした"
            case .missingAppConfiguration: return "Firebaseの設定がありません"
            }
        }
    }

    @MainActor
    static func analyze(payload: [String: Any]) async throws -> [String: Any] {
        guard FirebaseApp.app() != nil else { throw BridgeError.missingAppConfiguration }
        guard let encoded = payload["imageBase64"] as? String,
              let data = Data(base64Encoded: encoded),
              let image = UIImage(data: data) else { throw BridgeError.imageMissing }
        // Real-device App Check registration is mandatory. Failure is reported rather than hidden.
        do {
            _ = try await AppCheck.appCheck().token(forcingRefresh: false)
        } catch {
            throw NSError(domain: "SHEETMASTER.AppCheck", code: (error as NSError).code,
                          userInfo: [NSLocalizedDescriptionKey: "Firebase App Check認証エラー。Firebase側でアプリIDとApp Attestの登録を確認してください。詳細: " + error.localizedDescription])
        }
        let prompt = (payload["prompt"] as? String) ?? ""
        let model = FirebaseAI.firebaseAI(
            backend: .googleAI(), useLimitedUseAppCheckTokens: true
        ).generativeModel(
            modelName: "gemini-3.8-flash",
            generationConfig: GenerationConfig(responseMIMEType: "application/json")
        )
        let response: GenerateContentResponse
        do {
            response = try await model.generateContent(image, prompt)
        } catch {
            throw NSError(domain: "SHEETMASTER.Gemini", code: (error as NSError).code,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini通信エラー。Firebase AI Logicの有効化、モデル利用設定、API制限を確認してください。詳細: " + error.localizedDescription])
        }
        guard let text = response.text,
              let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"), first <= last,
              let jsonData = String(text[first...last]).data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              value["holes"] is [Any],
              value["width"] != nil, value["height"] != nil else {
            throw BridgeError.invalidResponse
        }
        return value
    }
}
