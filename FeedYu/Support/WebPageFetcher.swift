import WebKit

/// Fetches fully rendered page HTML through a hidden WKWebView — for hosts
/// whose bot defense blocks bare URLSession requests. ubereats.com serves a
/// JS challenge shell (botdefense-ext-ui) to anything that isn't a real
/// browser; a real WebKit runs the challenge, and its clearance cookies
/// persist in the default website data store for subsequent loads.
///
/// One shared webview, one fetch at a time — callers are expected to be
/// sequential (the suggestion engine checks one candidate at a time).
@MainActor
final class WebPageFetcher: NSObject {
    static let shared = WebPageFetcher()

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // persist bot-clearance cookies
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                configuration: configuration)
        webView.customUserAgent = MichelinNameLocalizer.mobileUserAgent
        return webView
    }()

    private var isBusy = false

    /// Runs async JS (may await/fetch; must return a String) on the given
    /// host's origin, loading `hostPage` first if the webview is elsewhere.
    /// This is the door past location/challenge gates: same-origin fetch()
    /// from a bot-cleared page carries the site's cookies and passes CSP.
    func callJS(_ script: String, arguments: [String: Any], onHost hostPage: URL) async -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }

        if webView.url?.host != hostPage.host {
            webView.load(URLRequest(url: hostPage, timeoutInterval: 15))
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let state = await evaluate("document.readyState")
                if state == "interactive" || state == "complete" { break }
            }
        }
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? String)
                case .failure(let error):
                    #if DEBUG
                    print("[WebFetch] JS failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func evaluate(_ expression: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(expression) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }
}
