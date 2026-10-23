import UIKit
import WebKit
import CoreLocation
import CoreTelephony
import Network

// ヴェゼル ダッシュ
// ・iPhone本体：ダッシュボードを全画面表示（タップで操作）
// ・ナビ（HDMI）：iPhone画面のコピーではなく、ナビの解像度に合わせたダッシュボードを直接表示

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ExternalSceneDelegate.self
        } else {
            config.delegateClass = MainSceneDelegate.self
        }
        return config
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .landscape
    }
}

// MARK: - 画面ごとの入口

final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = DashViewController(external: false)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) { Hub.shared.setActive(true) }
    func sceneWillResignActive(_ scene: UIScene) { Hub.shared.setActive(false) }
}

final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = DashViewController(external: true)
        window.isHidden = false
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
    }
}

// MARK: - 位置・通信・バッテリーをまとめて見張り、全画面のダッシュに配る

final class Hub: NSObject, CLLocationManagerDelegate {
    static let shared = Hub()

    private let location = CLLocationManager()
    private let telephony = CTTelephonyNetworkInfo()
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var lastPosJS: String?
    private let views = NSHashTable<WKWebView>.weakObjects()
    private var externalViews = NSHashTable<WKWebView>.weakObjects()
    private var active = false

    private override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation

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
    }

    func register(_ web: WKWebView, external: Bool) {
        views.add(web)
        if external { externalViews.add(web) }
    }

    func requestPermission() { location.requestWhenInUseAuthorization() }

    /// iPhone側のアプリが前面にある間：画面を消さない・GPSを動かす
    func setActive(_ on: Bool) {
        active = on
        UIApplication.shared.isIdleTimerDisabled = on
        if on { startLocationIfAllowed(); pushStatus() } else { location.stopUpdatingLocation() }
    }

    /// ページの読み込みが終わったとき、最新の値をすぐ渡す
    func pageLoaded(_ web: WKWebView) {
        web.evaluateJavaScript(statusJS(), completionHandler: nil)
        if let js = lastPosJS { web.evaluateJavaScript(js, completionHandler: nil) }
        if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
            web.evaluateJavaScript("window.__nativeNoGps && window.__nativeNoGps()", completionHandler: nil)
        }
    }

    /// iPhone側で設定を保存したら、ナビ側の表示を読み直す
    func reloadExternal() {
        for web in externalViews.allObjects { web.reload() }
    }

    private func broadcast(_ js: String) {
        for web in views.allObjects { web.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func startLocationIfAllowed() {
        switch location.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if active { location.startUpdatingLocation() }
        case .denied, .restricted:
            broadcast("window.__nativeNoGps && window.__nativeNoGps()")
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startLocationIfAllowed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let js = "window.__nativePos && window.__nativePos(\(last.coordinate.latitude), \(last.coordinate.longitude), \(last.speed))"
        lastPosJS = js
        broadcast(js)
    }

    // 通信の種類（5G / 4G / Wi-Fi / 圏外）
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

    private func statusJS() -> String {
        let device = UIDevice.current
        let level = device.batteryLevel   // 取得できないときは -1
        let charging = device.batteryState == .charging || device.batteryState == .full
        let net = networkLabel().replacingOccurrences(of: "\"", with: "")
        return "window.__nativeStatus && window.__nativeStatus(\"\(net)\", \(level), \(charging))"
    }

    @objc func pushStatus() { broadcast(statusJS()) }
}

/// WKScriptMessageHandler を弱参照で持つための仲介役（循環参照を防ぐ）
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

// MARK: - ダッシュボードを表示する画面

final class DashViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let external: Bool
    private var webView: WKWebView!
    private let pageHost = "vezel-dash.app"
    /// ナビ側では、iPhone横画面と同じくらいの文字の大きさになるよう、この高さを基準に拡大する
    private let referenceHeight: CGFloat = 390

    init(external: Bool) {
        self.external = external
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }

    override func loadView() {
        let contents = WKUserContentController()
        contents.add(WeakMessageHandler(self), name: "native")
        var boot = "window.__NATIVE_APP__ = true;"
        if external { boot += " window.__EXTERNAL_DISPLAY__ = true;" }
        contents.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        web.scrollView.isScrollEnabled = !external
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Hub.shared.register(webView, external: external)
        if !external { Hub.shared.requestPermission() }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            // 固定のURLで読み込むことで、設定（よく行く場所・背景など）が両方の画面で共有される
            webView.loadHTMLString(html, baseURL: URL(string: "https://\(pageHost)/"))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if external {
            let h = view.bounds.height
            if h > 0 { webView.pageZoom = max(1, h / referenceHeight) }
        }
    }

    // MARK: ページからの依頼

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "open":
            guard !external else { return }
            let app = (body["app"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let web = (body["web"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            openOutside(app: app, web: web)
        case "saved":
            if !external { Hub.shared.reloadExternal() }
        default:
            break
        }
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
        Hub.shared.pageLoaded(webView)
    }

    // ダッシュボード以外へのリンクは外のアプリで開く（ナビ側では何もしない）
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
        if !external { openOutside(app: nil, web: url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !external, let url = action.request.url { openOutside(app: nil, web: url) }
        return nil
    }
}
