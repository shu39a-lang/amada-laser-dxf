import Foundation
import UIKit

enum ClaudeError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case truncated
    case noToolResult(String)
    case network(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "APIキーが設定されていません(設定タブで入力してください)"
        case .http(let code, let msg):
            switch code {
            case 401: return "APIキーが正しくありません(401)"
            case 403: return "このAPIキーでは使えません(403): \(msg)"
            case 413: return "画像が大きすぎます(413)。写真の枚数を減らしてください"
            case 429: return "利用制限に達しました(429)。少し待ってから再実行してください"
            case 529: return "AIが混み合っています(529)。少し待ってから再実行してください"
            default: return "APIエラー(\(code)): \(msg)"
            }
        case .truncated: return "回答が長すぎて途中で切れました"
        case .noToolResult(let s): return "読み取り結果の形式が不正でした: \(s.prefix(200))"
        case .network(let s): return "通信が途中で切れました: \(s)\n電波の良い所で、画面を開いたまま「指示して読み直す」を押してください"
        case .refused: return "AIが回答を控えました(安全チェックの誤判定と思われます)。「この部品だけ読み直す」をもう一度押すか、設定でAIモデルを切り替えてください"
        }
    }
}

/// 「考える機能(thinking)」がこのAPIキー・モデルで使えないと分かったら、以後は使わない
final class ThinkingSwitch: @unchecked Sendable {
    static let shared = ThinkingSwitch()
    private let lock = NSLock()
    private var off = false
    var disabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return off }
        set { lock.lock(); off = newValue; lock.unlock() }
    }
}

/// Claude Messages API を呼び出し、ツール入力(JSON)で受け取る。
/// v2.6: ストリーミング(少しずつ受信)に変更。
///   v2.5 までは回答が全部できるまで通信が無言になり、長い図面では途中で接続が切れて「読み取れない」になっていた。
struct ClaudeClient {
    let apiKey: String
    let model: String

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // ストリーミング中はデータが流れ続けるので、無通信の待ち時間は短めでよい
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 1500
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// - thinkingBudget: 0 なら考える機能を使わない。使えない場合は自動で外して再送する
    /// - onProgress: 受信した文字数(増えた分)を知らせる
    func callTool(system: String,
                  content: [[String: Any]],
                  toolName: String,
                  toolDescription: String,
                  inputSchemaJSON: String,
                  maxTokens: Int,
                  thinkingBudget: Int = 0,
                  onProgress: ((Int) -> Void)? = nil) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw ClaudeError.noAPIKey }
        guard let schemaData = inputSchemaJSON.data(using: .utf8),
              let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            throw ClaudeError.noToolResult("schema")
        }
        let systemWithRule = system + "\n\n【回答方法】必ず \(toolName) ツールを1回だけ呼び出して回答すること。文章だけで答えてはいけない。"

        func makeRequest(thinking: Bool) throws -> URLRequest {
            var body: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "stream": true,
                "system": systemWithRule,
                "tools": [["name": toolName, "description": toolDescription, "input_schema": schema]],
                "tool_choice": ["type": "auto"],
                "messages": [["role": "user", "content": content]]
            ]
            if thinking {
                body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return req
        }

        var useThinking = thinkingBudget > 0 && thinkingBudget < maxTokens && !ThinkingSwitch.shared.disabled
        var thinkingRetried = false
        var lastError: Error = ClaudeError.network("unknown")
        var formatRetried = false
        var refusalRetries = 0
        let waits: [UInt64] = [0, 3, 8, 20]
        var attempt = 0
        while attempt < waits.count {
            if waits[attempt] > 0 { try await Task.sleep(nanoseconds: waits[attempt] * 1_000_000_000) }
            do {
                let req = try makeRequest(thinking: useThinking)
                return try await streamOnce(req, toolName: toolName, onProgress: onProgress)
            } catch ClaudeError.http(let code, let msg) {
                // 考える機能に対応していないモデル・設定なら外して、すぐ再送
                if code == 400, useThinking, !thinkingRetried, msg.lowercased().contains("thinking") || msg.lowercased().contains("budget") {
                    ThinkingSwitch.shared.disabled = true
                    useThinking = false
                    thinkingRetried = true
                    continue
                }
                lastError = ClaudeError.http(code, msg)
                if [429, 500, 502, 503, 504, 529].contains(code), attempt < waits.count - 1 { attempt += 1; continue }
                throw lastError
            } catch ClaudeError.refused {
                lastError = ClaudeError.refused
                if refusalRetries < 2 && attempt < waits.count - 1 { refusalRetries += 1; attempt += 1; continue }
                throw lastError
            } catch ClaudeError.noToolResult(let raw) {
                lastError = ClaudeError.noToolResult(raw)
                if !formatRetried && attempt < waits.count - 1 { formatRetried = true; attempt += 1; continue }
                throw lastError
            } catch let e as ClaudeError {
                throw e
            } catch {
                if (error as? URLError)?.code == .cancelled || error is CancellationError { throw error }
                lastError = ClaudeError.network(error.localizedDescription)
                if attempt < waits.count - 1 { attempt += 1; continue }
                throw lastError
            }
        }
        throw lastError
    }

    private struct StreamBlock {
        var type: String
        var name: String
        var text: String = ""
        var json: String = ""
    }

    /// 1回分の送信と、ストリーム(server-sent events)の受信
    private func streamOnce(_ req: URLRequest, toolName: String, onProgress: ((Int) -> Void)?) async throws -> [String: Any] {
        let (bytes, resp) = try await Self.session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var buf = Data()
            for try await b in bytes { buf.append(b); if buf.count > 20000 { break } }
            throw ClaudeError.http(code, Self.errorMessage(buf))
        }

        var blocks: [Int: StreamBlock] = [:]
        var stop: String? = nil
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = ev["type"] as? String ?? ""
            switch type {
            case "content_block_start":
                let idx = (ev["index"] as? NSNumber)?.intValue ?? 0
                let cb = ev["content_block"] as? [String: Any] ?? [:]
                var blk = StreamBlock(type: cb["type"] as? String ?? "", name: cb["name"] as? String ?? "")
                if let t = cb["text"] as? String { blk.text = t }
                blocks[idx] = blk
            case "content_block_delta":
                let idx = (ev["index"] as? NSNumber)?.intValue ?? 0
                let delta = ev["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String ?? "" {
                case "text_delta":
                    let s = delta["text"] as? String ?? ""
                    blocks[idx]?.text += s
                    onProgress?(s.count)
                case "input_json_delta":
                    let s = delta["partial_json"] as? String ?? ""
                    blocks[idx]?.json += s
                    onProgress?(s.count)
                case "thinking_delta":
                    let s = delta["thinking"] as? String ?? ""
                    onProgress?(s.count)
                default:
                    break
                }
            case "message_delta":
                if let dd = ev["delta"] as? [String: Any], let s = dd["stop_reason"] as? String { stop = s }
            case "error":
                let e = ev["error"] as? [String: Any] ?? [:]
                let et = e["type"] as? String ?? ""
                let msg = e["message"] as? String ?? "stream error"
                let mapped: Int
                switch et {
                case "overloaded_error": mapped = 529
                case "rate_limit_error": mapped = 429
                case "api_error": mapped = 500
                default: mapped = 400
                }
                throw ClaudeError.http(mapped, msg)
            default:
                break
            }
        }

        if stop == "refusal" { throw ClaudeError.refused }
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        if let tool = ordered.first(where: { $0.type == "tool_use" && ($0.name == toolName || $0.name.isEmpty) })
            ?? ordered.first(where: { $0.type == "tool_use" }) {
            if stop == "max_tokens" { throw ClaudeError.truncated }
            let js = tool.json.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = (js.isEmpty ? "{}" : js).data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return o
            }
            throw ClaudeError.noToolResult(String(js.prefix(300)))
        }
        if stop == "max_tokens" { throw ClaudeError.truncated }
        // 予備: 本文にJSONが書かれていればそれを使う
        let text = ordered.filter { $0.type == "text" }.map(\.text).joined(separator: "\n")
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
           let d = String(text[s...e]).data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        if stop == nil && ordered.isEmpty {
            throw ClaudeError.network("回答を受け取る前に接続が終わりました")
        }
        throw ClaudeError.noToolResult(text.isEmpty ? "(回答が空でした)" : text)
    }

    private static func errorMessage(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
    }

    // MARK: - 画像ブロック

    static func imageBlocks(_ images: [PreparedImage], cacheLast: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (i, img) in images.enumerated() {
            out.append(["type": "text", "text": "【画像\(i + 1)】\(img.label)"])
            var block: [String: Any] = [
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": img.jpeg.base64EncodedString()]
            ]
            if cacheLast && i == images.count - 1 {
                // 部品ごとの2回目以降の呼び出しで画像を再利用(料金と時間の節約)
                block["cache_control"] = ["type": "ephemeral"]
            }
            out.append(block)
        }
        return out
    }
}

/// 読み取り中は画面を消さず、アプリを一瞬切り替えても通信を続ける
@MainActor
final class KeepAwake {
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SheetMasterReading") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        UIApplication.shared.isIdleTimerDisabled = false
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}

/// 受信文字数の合計(並列の読み取りをまとめて表示)
final class ReceiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var lastShown = 0

    /// 加算して、表示を更新すべきなら合計を返す
    func add(_ n: Int, step: Int = 400) -> Int? {
        lock.lock(); defer { lock.unlock() }
        total += n
        if total - lastShown >= step { lastShown = total; return total }
        return nil
    }
}
