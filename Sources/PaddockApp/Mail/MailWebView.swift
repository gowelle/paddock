import AppKit
import SwiftUI
import WebKit

/// Shows a caught message's HTML. Scripts never run, nothing is kept between messages, and a link opens in the
/// browser instead of here. What may load from the network is decided by the policy `MailHTML` put in the
/// document.
struct MailWebView: NSViewRepresentable {
    /// The whole document, from `MailModel.htmlDocument`.
    let document: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = true
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(into: view, coordinator: context.coordinator)
    }

    private func load(into view: WKWebView, coordinator: Coordinator) {
        guard coordinator.shown != document else { return }
        coordinator.shown = document
        view.loadHTMLString(document, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The document on show, so an unrelated redraw doesn't reload it.
        var shown: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // The document itself (and nothing it frames: the policy forbids frames).
            if navigationAction.navigationType == .other, navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            // A link the reader clicked goes to the browser or the mail program; nothing else goes anywhere.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
