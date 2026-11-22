import Foundation
import UIKit
import FirebaseCore
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
            guard !word.text.isEmpty, word.confidence >= 0.25, word.confidence <= 1,
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
}
