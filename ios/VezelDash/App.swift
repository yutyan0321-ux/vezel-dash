import UIKit
import WebKit
import CoreLocation
import CoreTelephony
import Network

// ヴェゼル ダッシュ：index.html をアプリの中で全画面表示する
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = DashViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .landscape
    }
}

/// WKScriptMessageHandler を弱参照で持つための小さな仲介役（循環参照を防ぐ）
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

final class DashViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
                                WKScriptMessageHandler, CLLocationManagerDelegate {
    private var webView: WKWebView!
    private let location = CLLocationManager()
    private let pageHost = "vezel-dash.app"
    private let telephony = CTTelephonyNetworkInfo()
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }

    override func loadView() {
        let contents = WKUserContentController()
        contents.add(WeakMessageHandler(self), name: "native")
        contents.addUserScript(WKUserScript(source: "window.__NATIVE_APP__ = true;",
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = contents
        config.websiteDataStore = .default()

        let web = WKWebView(frame: .zero, configuration: config)
        let bg = UIColor(red: 7 / 255, green: 11 / 255, blue: 20 / 255, alpha: 1)
        web.isOpaque = false
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            // 固定のURLで読み込むことで、設定（よく行く場所・背景など）が保存され続ける
            webView.loadHTMLString(html, baseURL: URL(string: "https://\(pageHost)/"))
        }

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.requestWhenInUseAuthorization()

        // バッテリーと通信の種類を見張る
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(pushStatus),
                       name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(pushStatus),
                       name: UIDevice.batteryStateDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(pushStatus),
                       name: .CTServiceRadioAccessTechnologyDidChange, object: nil)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.currentPath = path
                self?.pushStatus()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net-monitor"))

        nc.addObserver(self, selector: #selector(becameActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(resignedActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
    }

    // 表示中は画面を消さない・GPSを動かす。裏に回ったら止める
    @objc private func becameActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        startLocationIfAllowed()
        pushStatus()
    }

    // MARK: - 通信の種類とバッテリー

    /// 携帯回線の世代（5G / 4G / 3G）。分からなければ nil
    private func cellularGeneration() -> String? {
        let techs = telephony.serviceCurrentRadioAccessTechnology?.values.map { $0 } ?? []
        if techs.contains(where: { $0 == CTRadioAccessTechnologyNR || $0 == CTRadioAccessTechnologyNRNSA }) { return "5G" }
        if techs.contains(CTRadioAccessTechnologyLTE) { return "4G" }
        let threeG: Set<String> = [CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA,
                                   CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyCDMAEVDORev0,
                                   CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB,
                                   CTRadioAccessTechnologyeHRPD]
        if techs.contains(where: { threeG.contains($0) }) { return "3G" }
        if !techs.isEmpty { return "2G" }
        return nil
    }

    private func networkLabel() -> String {
        if let path = currentPath {
            if path.status != .satisfied { return cellularGeneration() == nil ? "圏外" : "オフライン" }
            if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        }
        return cellularGeneration() ?? "圏外"
    }

    @objc private func pushStatus() {
        let device = UIDevice.current
        let level = device.batteryLevel   // 取得できないときは -1
        let charging = device.batteryState == .charging || device.batteryState == .full
        let net = networkLabel().replacingOccurrences(of: "\"", with: "")
        let js = "window.__nativeStatus && window.__nativeStatus(\"\(net)\", \(level), \(charging))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc private func resignedActive() {
        UIApplication.shared.isIdleTimerDisabled = false
        location.stopUpdatingLocation()
    }

    private func startLocationIfAllowed() {
        switch location.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            location.startUpdatingLocation()
        case .denied, .restricted:
            webView.evaluateJavaScript("window.__nativeNoGps && window.__nativeNoGps()", completionHandler: nil)
        default:
            break
        }
    }

    // MARK: - 位置情報

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startLocationIfAllowed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let js = "window.__nativePos && window.__nativePos(\(last.coordinate.latitude), \(last.coordinate.longitude), \(last.speed))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - ページからの「アプリを開いて」の依頼

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              (body["type"] as? String) == "open" else { return }
        let app = (body["app"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let web = (body["web"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        openOutside(app: app, web: web)
    }

    /// まずアプリを直接開き、開けなければWeb版（ユニバーサルリンク）を開く
    private func openOutside(app: URL?, web: URL?) {
        if let app = app {
            UIApplication.shared.open(app, options: [:]) { opened in
                if !opened, let web = web { UIApplication.shared.open(web) }
            }
        } else if let web = web {
            UIApplication.shared.open(web)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushStatus()
        startLocationIfAllowed()
    }

    // MARK: - リンクの扱い：ダッシュボード以外へのリンクは外のアプリで開く

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if url.host == pageHost || scheme == "about" || scheme == "data" || scheme == "blob" {
            return decisionHandler(.allow)
        }
        if action.targetFrame?.isMainFrame == false && (scheme == "http" || scheme == "https") {
            return decisionHandler(.allow)
        }
        openOutside(app: nil, web: url)
        decisionHandler(.cancel)
    }

    // target="_blank" のリンク
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openOutside(app: nil, web: url) }
        return nil
    }
}
