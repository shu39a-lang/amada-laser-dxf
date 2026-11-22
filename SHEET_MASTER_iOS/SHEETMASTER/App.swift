import SwiftUI
import WebKit
import UniformTypeIdentifiers
import UIKit

@main
struct SheetMasterApp: App {
    var body: some Scene {
        WindowGroup {
            WebContainer().ignoresSafeArea()
        }
    }
}

struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        content.add(context.coordinator, name: "sheetMasterBridge")
        content.addUserScript(WKUserScript(source: Self.bridgeJavaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = view
        if let url = Bundle.main.url(forResource: "SHEET MASTER", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // Injected separately at document start. The original HTML file remains byte-for-byte unchanged.
    private static let bridgeJavaScript = #"""
    (() => {
      const pending = new Map(); let nextId = 1;
      function request(action, payload) {
        return new Promise((resolve,reject) => {
          const id = String(nextId++);
          pending.set(id, {resolve,reject});
          window.webkit.messageHandlers.sheetMasterBridge.postMessage({id, action, payload});
        });
      }
      window.__sheetMasterNativeReply = (id, result, error) => {
        const p = pending.get(String(id)); if(!p) return;
        pending.delete(String(id));
        if(error) p.reject(Object.assign(new Error(error.message || '失敗しました'), {code:error.code || 'upstream_error'}));
        else p.resolve(result);
      };
      window.claude = {
        use: async kind => {
          if(kind === 'downloads') return {
            save: async ({filename,data}) => request('save', {filename,data})
          };
          if(kind === 'sample') return {
            json: async (prompt, options) => {
              const blob = options?.images?.[0];
              if(!blob) throw Object.assign(new Error('画像がありません'), {code:'image_rejected'});
              const image = await new Promise((resolve,reject) => {
                const r = new FileReader(); r.onload = () => resolve(String(r.result).split(',')[1]);
                r.onerror=reject; r.readAsDataURL(blob);
              });
              return request('analyze', {prompt, imageBase64:image, modelTier:options?.modelTier || 'quick'});
            }
          };
          return null;
        }
      };
    })();
    """#

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate {
        weak var webView: WKWebView?
        private var pendingSaveId: String?
        private var tempSaveURL: URL?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String:Any], let id = body["id"] as? String,
                  let action = body["action"] as? String, let payload = body["payload"] as? [String:Any] else { return }
            switch action {
            case "save":
                guard let data = payload["data"] as? String else { reply(id: id, error: "保存する内容がありません", code: "invalid_data"); return }
                let filename = ((payload["filename"] as? String) ?? "part.txt").replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                do {
                    try data.write(to: url, atomically: true, encoding: .utf8)
                    guard let vc = topViewController() else { reply(id: id, error: "保存画面を開けません", code: "unavailable"); return }
                    pendingSaveId = id; tempSaveURL = url
                    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                    picker.delegate = self
                    vc.present(picker, animated: true)
                } catch { reply(id: id, error: error.localizedDescription, code: "save_error") }
            case "analyze":
                // No API keys are stored in the app. Configure a trusted HTTPS relay endpoint separately.
                guard let endpoint = Bundle.main.object(forInfoDictionaryKey: "DrawingAnalysisEndpoint") as? String,
                      let url = URL(string: endpoint), url.scheme == "https", !endpoint.isEmpty else {
                    reply(id: id, error: "AI読み取り用サーバーが未設定です。HTML本体は変更していません。", code: "not_granted")
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                } catch { reply(id: id, error: "送信データを作成できません", code: "invalid_json"); return }
                URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                    if let error = error { self?.reply(id: id, error: error.localizedDescription, code: "upstream_error"); return }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data), json is [String:Any] else {
                        self?.reply(id: id, error: "読み取りサーバーから正しいJSONが返りませんでした", code: "invalid_json"); return
                    }
                    self?.reply(id: id, result: json)
                }.resume()
            default: reply(id: id, error: "未対応の操作です", code: "unavailable")
            }
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let id = pendingSaveId { reply(id: id, result: true) }
            pendingSaveId = nil; tempSaveURL = nil
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            if let id = pendingSaveId { reply(id: id, error: "保存を中止しました", code: "declined") }
            pendingSaveId = nil; tempSaveURL = nil
        }
        private func reply(id: String, result: Any? = nil, error: String? = nil, code: String = "upstream_error") {
            let payload: [Any] = [id, result ?? NSNull(), error.map { ["message":$0,"code":code] } ?? NSNull()]
            guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
                  let arguments = String(data: encoded, encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                // Pass JSON array contents as function arguments, not as a literal string.
                self?.webView?.evaluateJavaScript("window.__sheetMasterNativeReply.apply(null, \(arguments));", completionHandler: nil)
            }
        }
        private func topViewController() -> UIViewController? {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first,
                  let root = scene.windows.first(where: {$0.isKeyWindow})?.rootViewController else { return nil }
            var vc = root
            while let presented = vc.presentedViewController { vc = presented }
            return vc
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, ["http","https","mailto"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}
