import AppKit
import Observation
import WebKit
import DeepSeekCodeCore

@MainActor
@Observable
final class BrowserController: NSObject, WKNavigationDelegate, @unchecked Sendable {
    var urlString = "http://localhost:5173"
    var pageTitle = ""
    var isLoading = false
    var snapshot: BrowserSnapshot?
    var consoleErrors: [String] = []
    var networkFailures: [String] = []
    var actionRecords: [BrowserActionRecord] = []
    var lastError = ""

    var evidenceBundle: BrowserEvidenceBundle? {
        guard let snapshot else { return nil }
        return BrowserEvidenceBundle(
            url: snapshot.url,
            title: snapshot.title,
            domSummary: snapshot.domText,
            accessibilityTree: snapshot.accessibilityTree,
            consoleErrors: snapshot.consoleErrors,
            networkFailures: snapshot.networkFailures,
            actions: actionRecords + [BrowserActionRecord(tool: "browser.snapshot", snapshotVersion: snapshot.snapshotVersion, succeeded: true)],
            passedAssertions: [],
            failedAssertions: []
        )
    }

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var lastLoadedURL = ""
    @ObservationIgnored private let networkRuntime: NetworkRuntime
    @ObservationIgnored private var activeNetworkSessionID: String?
    @ObservationIgnored private var nextSnapshotVersion = 0

    init(networkRuntime: NetworkRuntime = .shared) {
        self.networkRuntime = networkRuntime
        super.init()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await BrowserAutomationBridge.shared.install { [weak self] tool, argumentsJSON, sessionID in
                guard let self else { throw BrowserControllerError.notReady }
                return try await self.executeAgentTool(tool, argumentsJSON: argumentsJSON, sessionID: sessionID)
            }
        }
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = BrowserConsoleHandler { [weak self] message in
            Task { @MainActor in
                self?.consoleErrors.append(message)
            }
        }
        configuration.userContentController.add(handler, name: "deepseekConsole")
        let script = WKUserScript(
            source: """
            (() => {
              const original = console.error;
              console.error = (...args) => {
                try { window.webkit.messageHandlers.deepseekConsole.postMessage(args.map(String).join(" ")); } catch (_) {}
                original.apply(console, args);
              };
              const originalFetch = window.fetch;
              window.fetch = (...args) => originalFetch(...args).then(response => {
                if (!response.ok) {
                  try { window.webkit.messageHandlers.deepseekConsole.postMessage('NETWORK ' + response.status + ' ' + response.url); } catch (_) {}
                }
                return response;
              }).catch(error => {
                try { window.webkit.messageHandlers.deepseekConsole.postMessage('NETWORK ' + String(error)); } catch (_) {}
                throw error;
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        webView = view
        return view
    }

    func attach(_ view: WKWebView) {
        webView = view
        view.navigationDelegate = self
    }

    func loadIfNeeded() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.absoluteString != lastLoadedURL else { return }
        lastLoadedURL = url.absoluteString
        isLoading = true
        lastError = ""
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        isLoading = true
        lastError = ""
        webView?.reload()
    }

    func captureSnapshot() async {
        guard let webView else { return }
        do {
            let values = try await evaluateSnapshot("""
            (() => {
              const elements = Array.from(document.querySelectorAll('button,a,input,select,textarea,[role]')).slice(0, 120);
              const accessibility = elements.map((el) => {
                const role = el.getAttribute('role') || el.tagName.toLowerCase();
                const name = el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || '';
                return role + ': ' + name.trim().replace(/\\s+/g, ' ');
              }).filter(Boolean).join('\\n');
              return {
                title: document.title || '',
                domText: (document.body?.innerText || '').slice(0, 20000),
                accessibilityTree: accessibility
              };
            })()
            """)
            let title = values["title"] ?? ""
            let domText = values["domText"] ?? ""
            let accessibility = values["accessibilityTree"] ?? ""
            pageTitle = title
            nextSnapshotVersion += 1
            snapshot = BrowserSnapshot(
                url: webView.url?.absoluteString ?? urlString,
                title: title,
                domText: domText,
                accessibilityTree: accessibility,
                consoleErrors: consoleErrors,
                networkFailures: networkFailures,
                snapshotVersion: nextSnapshotVersion
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func click(selector: String) async -> Bool {
        await act("""
        (() => {
          const element = document.querySelector(%@);
          if (!element) return false;
          element.click();
          return true;
        })()
        """, argument: selector)
    }

    func type(text: String, into selector: String) async -> Bool {
        await act("""
        (() => {
          const element = document.querySelector(%@);
          if (!element) return false;
          element.focus();
          element.value = %@;
          element.dispatchEvent(new Event('input', { bubbles: true }));
          element.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
        """, argument: selector, secondaryArgument: text)
    }

    func takeScreenshot() async -> NSImage? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func executeAgentTool(_ tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UnifiedRuntimeError.invalidArguments
        }
        switch tool.name {
        case "browser.open":
            guard let value = arguments["url"] as? String, let url = URL(string: value), url.scheme == "http" || url.scheme == "https" else {
                throw ProviderRequestError.invalidEndpoint
            }
            let decision = await networkRuntime.authorize(url: url, capability: .browser, operation: .read, sessionID: sessionID, projectID: nil, approved: false)
            guard decision == .allow else {
                throw decision == .block
                    ? NetworkRuntimeError.blocked(NetworkPolicy.default.explain(decision, url: url, scope: .browser))
                    : NetworkRuntimeError.approvalRequired(NetworkPolicy.default.explain(decision, url: url, scope: .browser))
            }
            activeNetworkSessionID = sessionID
            await networkRuntime.recordExternalRequest(capability: .browser, operation: .read, url: url, sessionID: sessionID, projectID: nil, state: .started)
            urlString = value
            loadIfNeeded()
            return json(["ok": true, "url": value, "sessionID": sessionID])
        case "browser.snapshot":
            await captureSnapshot()
            guard let snapshot else { throw BrowserControllerError.notReady }
            return json([
                "ok": true,
                "url": snapshot.url,
                "title": snapshot.title,
                "domText": snapshot.domText,
                "accessibilityTree": snapshot.accessibilityTree,
                "consoleErrors": snapshot.consoleErrors,
                "networkFailures": snapshot.networkFailures,
                "snapshotVersion": snapshot.snapshotVersion
            ])
        case "browser.screenshot":
            guard let image = await takeScreenshot(),
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw BrowserControllerError.notReady
            }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-browser-\(UUID().uuidString).png")
            try png.write(to: path, options: .atomic)
            return json(["ok": true, "path": path.path, "url": webView?.url?.absoluteString ?? urlString])
        case "browser.query":
            let selector = arguments["selector"] as? String ?? ""
            guard !selector.isEmpty else { throw UnifiedRuntimeError.invalidArguments }
            _ = try requireCurrentSnapshot(arguments: arguments, tool: tool.name)
            return try await evaluateJSON("""
            (() => {
              const element = document.querySelector(\(jsString(selector)));
              if (!element) return { ok: false, found: false };
              return {
                ok: true,
                found: true,
                tag: element.tagName.toLowerCase(),
                text: (element.innerText || element.value || '').slice(0, 2000),
                role: element.getAttribute('role') || '',
                ariaLabel: element.getAttribute('aria-label') || ''
              };
            })()
            """)
        case "browser.click":
            let selector = arguments["selector"] as? String ?? ""
            guard !selector.isEmpty else { throw UnifiedRuntimeError.invalidArguments }
            let snapshotVersion = try requireCurrentSnapshot(arguments: arguments, tool: tool.name)
            guard await click(selector: selector) else { throw UnifiedRuntimeError.remote("浏览器元素不存在或点击失败") }
            actionRecords.append(BrowserActionRecord(tool: tool.name, selector: selector, snapshotVersion: snapshotVersion, succeeded: true))
            await captureSnapshot()
            return json(["ok": true, "action": "click", "selector": selector])
        case "browser.type":
            let selector = arguments["selector"] as? String ?? ""
            let text = arguments["text"] as? String ?? ""
            guard !selector.isEmpty else { throw UnifiedRuntimeError.invalidArguments }
            let snapshotVersion = try requireCurrentSnapshot(arguments: arguments, tool: tool.name)
            let lower = selector.lowercased()
            guard !lower.contains("password") && !lower.contains("token") && !lower.contains("secret") && !lower.contains("credit") else {
                throw UnifiedRuntimeError.remote("禁止向疑似敏感输入框输入内容")
            }
            guard await type(text: text, into: selector) else { throw UnifiedRuntimeError.remote("浏览器输入失败") }
            actionRecords.append(BrowserActionRecord(tool: tool.name, selector: selector, snapshotVersion: snapshotVersion, succeeded: true, detail: "characterCount=\(text.count)"))
            return json(["ok": true, "action": "type", "selector": selector, "characterCount": text.count])
        case "browser.assert":
            let description = arguments["description"] as? String ?? "浏览器验证"
            let selector = arguments["selector"] as? String ?? ""
            let expectedText = arguments["expectedText"] as? String
            guard !selector.isEmpty else { throw UnifiedRuntimeError.invalidArguments }
            let snapshotVersion = try requireCurrentSnapshot(arguments: arguments, tool: tool.name)
            let raw = try await evaluateJSON("""
            (() => {
              const element = document.querySelector(\(jsString(selector)));
              if (!element) return { exists: false, text: '' };
              return { exists: true, text: (element.innerText || element.value || '').slice(0, 4000) };
            })()
            """)
            let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            let exists = result?["exists"] as? Bool ?? false
            let text = result?["text"] as? String ?? ""
            let passed = exists && (expectedText.map { text.localizedCaseInsensitiveContains($0) } ?? true)
            actionRecords.append(BrowserActionRecord(tool: tool.name, selector: selector, snapshotVersion: snapshotVersion, succeeded: passed, detail: description))
            guard passed else {
                throw UnifiedRuntimeError.remote("浏览器断言失败：\(description)")
            }
            return json(["ok": true, "description": description, "selector": selector, "text": text])
        case "browser.console":
            return json(["ok": true, "errors": consoleErrors])
        case "browser.network":
            return json(["ok": true, "failures": networkFailures])
        default:
            throw UnifiedRuntimeError.toolHostUnavailable(tool.name)
        }
    }

    private func requireCurrentSnapshot(arguments: [String: Any], tool: String) throws -> Int {
        guard let snapshot else { throw BrowserControllerError.notReady }
        guard let raw = arguments["snapshotVersion"] as? Int else {
            throw UnifiedRuntimeError.remote("\(tool) 必须携带最新 snapshotVersion")
        }
        guard snapshot.canPerform(actionSnapshotVersion: raw) else {
            throw UnifiedRuntimeError.remote("浏览器快照已过期，请先重新 Snapshot")
        }
        return raw
    }

    private func evaluateJSON(_ script: String) async throws -> String {
        guard let webView else { throw BrowserControllerError.notReady }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let value, JSONSerialization.isValidJSONObject(value) else {
                    continuation.resume(returning: "{\"ok\":false,\"value\":null}")
                    return
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: value)
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func json(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return "{\"ok\":false,\"error\":\"serialization failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let url = webView.url {
            Task {
                await networkRuntime.recordExternalRequest(capability: .browser, operation: .read, url: url, sessionID: activeNetworkSessionID, projectID: nil, state: .completed, statusCode: 200)
            }
        }
        Task { await captureSnapshot() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        networkFailures.append(error.localizedDescription)
        if let url = webView.url {
            Task {
                await networkRuntime.recordExternalRequest(capability: .browser, operation: .read, url: url, sessionID: activeNetworkSessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        networkFailures.append(error.localizedDescription)
        if let url = webView.url {
            Task {
                await networkRuntime.recordExternalRequest(capability: .browser, operation: .read, url: url, sessionID: activeNetworkSessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    private func act(_ script: String, argument: String, secondaryArgument: String? = nil) async -> Bool {
        let first = jsString(argument)
        let second = secondaryArgument.map(jsString) ?? ""
        let firstRange = script.range(of: "%@")
        let withFirst = script.replacingOccurrences(of: "%@", with: first, options: [], range: firstRange)
        let formatted = withFirst.replacingOccurrences(of: "%@", with: second, options: [], range: withFirst.range(of: "%@"))
        do {
            return try await evaluateBool(formatted)
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func evaluateSnapshot(_ script: String) async throws -> [String: String] {
        guard let webView else { throw BrowserControllerError.notReady }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let dictionary = value as? [String: Any]
                continuation.resume(returning: [
                    "title": dictionary?["title"] as? String ?? "",
                    "domText": dictionary?["domText"] as? String ?? "",
                    "accessibilityTree": dictionary?["accessibilityTree"] as? String ?? ""
                ])
            }
        }
    }

    private func evaluateBool(_ script: String) async throws -> Bool {
        guard let webView else { throw BrowserControllerError.notReady }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (value as? Bool) ?? false)
                }
            }
        }
    }

    private func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}

private final class BrowserConsoleHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: (String) -> Void

    init(onMessage: @escaping (String) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.body as? String ?? String(describing: message.body))
    }
}

enum BrowserControllerError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: "浏览器尚未初始化"
        }
    }
}
