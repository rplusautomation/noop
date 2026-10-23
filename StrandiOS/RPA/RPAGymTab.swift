// R+ fork: the gym app (rpagym, a web PWA backed by Supabase) as a tab inside NOOP, so strap and gym
// logging live in one app. It is a plain WKWebView on the live site: gym UI changes ship through
// Netlify without rebuilding this app. The persistent website data store keeps the app's local state
// (offline queue, settings) across launches, the same as the home-screen PWA did.
import SwiftUI
import WebKit

struct RPAGymTab: View {
    static let url = URL(string: "https://rpagym.netlify.app")!
    /// Back to NOOP's Today tab. The gym app has its own bottom navigation, so NOOP's tab bar is hidden
    /// here (no bar inside a bar) and this slim header is the way out.
    var onClose: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Label("手环", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                }
                .tint(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.black)
            RPAWebView(url: Self.url)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Color.black)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { RPABridge.shared.model = model }
    }
}

/// The food log screen of the same web app as its own tab, with NOOP's tab bar kept underneath it
/// (`?tab=1` hides the gym app's own bar there; see views/Food.jsx in openGym).
struct RPAFoodTab: View {
    static let url = URL(string: "https://rpagym.netlify.app/#/food?tab=1")!

    var body: some View {
        RPAWebView(url: Self.url)
            .background(Color.black)
    }
}

private struct RPAWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // window.webkit.messageHandlers.rpaStrap: the web app hands rest timers to the strap
        // (frontend/src/lib/supabase-backend.js in openGym).
        config.userContentController.add(context.coordinator, name: "rpaStrap")
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = .black
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        let url: URL
        init(url: URL) { self.url = url }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            Task { @MainActor in
                switch type {
                case "rest": if let sec = (body["seconds"] as? NSNumber)?.intValue, sec > 0 { RPABridge.shared.rest(seconds: sec) }
                case "cancel": RPABridge.shared.cancelRest()
                case "scan": RPABarcodeScanner.shared.present(for: message.webView)
                default: break
                }
            }
        }

        @objc func reload(_ sender: UIRefreshControl) {
            (sender.superview?.superview as? WKWebView)?.reload()
            sender.endRefreshing()
        }

        // A failed first load (offline at launch) would otherwise leave a blank tab until relaunch.
        func webView(_ web: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if web.url == nil { web.load(URLRequest(url: self.url)) } }
        }

        // The food log's live barcode scan uses getUserMedia; our own site gets the camera without a
        // second web-level prompt (iOS still asks once for the app's camera permission).
        func webView(_ web: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == RPAGymTab.url.host && type == .camera ? .grant : .prompt)
        }

        // The web app uses confirm()/alert() for destructive actions; WKWebView shows nothing without these.
        func webView(_ web: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(message, cancel: false) { _ in completionHandler() }
        }

        func webView(_ web: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(message, cancel: true, completionHandler)
        }

        private func present(_ message: String, cancel: Bool, _ done: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if cancel { alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(false) }) }
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in done(true) })
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return done(false) }
            var top = root
            while let next = top.presentedViewController { top = next }
            top.present(alert, animated: true)
        }

        // Links leaving the gym app (e.g. a video link) open in Safari instead of replacing the tab.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url, action.navigationType == .linkActivated, u.host != RPAGymTab.url.host {
                UIApplication.shared.open(u)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
