// R+ fork: native product-barcode scanner for the gym tab's food log. The web app posts
// { type: "scan" } to rpaStrap; this presents VisionKit's live scanner (the system camera UI with
// tap-free recognition) and hands the first EAN/UPC back through window.rpaScanResult(code), or
// window.rpaScanResult(null) when cancelled or unavailable, so the page can fall back to its own.
import UIKit
import VisionKit
import WebKit

@MainActor
final class RPABarcodeScanner: NSObject, DataScannerViewControllerDelegate {
    static let shared = RPABarcodeScanner()
    private weak var web: WKWebView?
    private var done = false

    func present(for web: WKWebView?) {
        self.web = web
        done = false
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else { return finish(nil) }
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = self
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.close(nil)
        })
        vc.navigationItem.title = "扫条码"
        nav.presentationController?.delegate = self
        guard let top = Self.topController() else { return finish(nil) }
        top.present(nav, animated: true) { try? vc.startScanning() }
    }

    nonisolated func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
        for case let .barcode(code) in items {
            if let value = code.payloadStringValue, !value.isEmpty {
                Task { @MainActor in self.close(value) }
                return
            }
        }
    }

    private func close(_ code: String?) {
        guard !done else { return }
        done = true
        let top = Self.topController()
        if let nav = top as? UINavigationController, nav.viewControllers.first is DataScannerViewController {
            (nav.viewControllers.first as? DataScannerViewController)?.stopScanning()
            nav.dismiss(animated: true)
        }
        finish(code)
    }

    private func finish(_ code: String?) {
        done = true
        let arg = code.map { "'" + $0.filter { $0.isNumber } + "'" } ?? "null"
        web?.evaluateJavaScript("window.rpaScanResult && window.rpaScanResult(\(arg))")
    }

    private static func topController() -> UIViewController? {
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return nil }
        while let next = top.presentedViewController { top = next }
        return top
    }
}

extension RPABarcodeScanner: UIAdaptivePresentationControllerDelegate {
    // Swiped down instead of Cancel.
    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in if !self.done { self.finish(nil) } }
    }
}
