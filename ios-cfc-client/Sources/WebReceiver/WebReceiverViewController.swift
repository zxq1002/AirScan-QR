//
//  WebReceiverViewController.swift
//  ios-cfc-client
//
//  WKWebView 接收端宿主（路线 B / v1.2.0）
//
//  关键机制：
//   1. 本地 HTTP 服务 → WKWebView → harness.html（内嵌实时 HUD）
//   2. postMessage 进度回传（受主线程饱和影响，可能延迟）
//   3. 轮询兜底：每 500ms 调 __cfcGetState() 读取进度（不依赖 postMessage）
//

import UIKit
import WebKit
import AVFoundation

final class WebReceiverViewController: UIViewController {

    var onFile: ((String, Data) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFileName: ((String) -> Void)?
    var onModeDetected: ((String) -> Void)?   // "4C"/"Bu"/"Bm"/"B"
    var onScanningStarted: (() -> Void)?

    private let server = WebReceiverServer()
    private var webView: WKWebView!
    private var startedServer = false
    private var pollTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)
        requestCameraAccess()
        setupWebView()
        startServerAndLoad()
    }

    private func requestCameraAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?(granted ? "相机权限已授予" : "需要相机权限才能接收")
                }
            }
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let relay = WeakScriptMessageHandler(self)
        let ucc = config.userContentController
        for name in ["fileComplete", "fileMeta", "progress", "cameraStarted", "status", "jslog"] {
            ucc.add(relay, name: name)
        }

        // 把 WKWebView 内的 JS console 转发到原生
        let jslogSrc = """
        (function(){
          function send(level, args){
            try{
              var msg = Array.prototype.map.call(args, function(a){
                try{ return (typeof a==='object') ? JSON.stringify(a) : String(a); }catch(e){ return String(a); }
              }).join(' ');
              if (window.webkit && window.webkit.messageHandlers.jslog)
                window.webkit.messageHandlers.jslog.postMessage({level:level, msg:msg});
            }catch(e){}
          }
          ['log','warn','error','info'].forEach(function(k){
            var orig = console[k];
            console[k] = function(){ send(k, arguments); if(orig) orig.apply(console, arguments); };
          });
        })();
        """
        ucc.addUserScript(WKUserScript(source: jslogSrc, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.scrollView.isScrollEnabled = false
        view.addSubview(wv)
        webView = wv
    }

    private func startServerAndLoad() {
        guard !startedServer else { return }
        startedServer = true

        guard let root = Bundle.main.url(forResource: "WebResources", withExtension: nil) else {
            onStatus?("未找到 WebResources 资源目录")
            NSLog("[WebReceiver] 缺少 WebResources")
            return
        }

        Task { @MainActor in
            do {
                let port = try await server.start(root: root)
                let url = URL(string: "http://127.0.0.1:\(port)/harness.html")!
                NSLog("[WebReceiver] 加载 \(url)")
                webView.load(URLRequest(url: url))
                onStatus?("解码引擎加载中…")
            } catch {
                NSLog("[WebReceiver] 本地服务启动失败: \(error)")
                onStatus?("本地服务启动失败")
            }
        }
    }

    // MARK: - JS 消息处理 (postMessage 路径)

    fileprivate func handle(_ message: WKScriptMessage) {
        switch message.name {
        case "fileComplete":
            guard let body = message.body as? [String: Any],
                  let name = body["name"] as? String,
                  let b64 = body["data"] as? String,
                  let data = Data(base64Encoded: b64) else {
                NSLog("[WebReceiver] fileComplete 解析失败")
                return
            }
            let size = (body["size"] as? NSNumber)?.intValue ?? data.count
            NSLog("[WebReceiver] 收到文件 \(name) (\(size) bytes)")
            stopPolling()
            onFile?(name, data)
            onStatus?("\(name) · \(Self.formatSize(size))")

        case "fileMeta":
            if let body = message.body as? [String: Any], let name = body["name"] as? String {
                let size = (body["size"] as? NSNumber)?.intValue ?? 0
                onStatus?("正在接收：\(name)" + (size > 0 ? " · \(Self.formatSize(size))" : ""))
                onFileName?(name)
            }

        case "progress":
            if let body = message.body as? [String: Any],
               let p = body["percent"] as? NSNumber {
                onProgress?(p.intValue)
                if let streams = body["streams"] as? NSNumber {
                    onStatus?("解码中… \(p.intValue)% · \(streams.intValue) 流")
                }
            }

        case "status":
            if let body = message.body as? [String: Any] {
                if let m = body["mode"] as? String, !m.isEmpty { onModeDetected?(m) }
                if let n = body["fileName"] as? String, !n.isEmpty { onFileName?(n) }
            }

        case "cameraStarted":
            onStatus?("📷 相机已启动，正在扫描…")
            onScanningStarted?()
            startPolling()

        case "jslog":
            if let body = message.body as? [String: Any], let msg = body["msg"] as? String {
                NSLog("[JS] %@", msg)
            }

        default:
            break
        }
    }

    // MARK: - 轮询兜底（每 500ms 调 __cfcGetState，防止主线程饱和时 postMessage 延迟）

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.webView?.evaluateJavaScript("__cfcGetState()") { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                DispatchQueue.main.async {
                    if let p = obj["percent"] as? NSNumber { self?.onProgress?(p.intValue) }
                    if let m = obj["mode"] as? String, !m.isEmpty { self?.onModeDetected?(m) }
                    if let n = obj["fileName"] as? String, !n.isEmpty { self?.onFileName?(n) }
                    if let s = obj["status"] as? String, !s.isEmpty { self?.onStatus?(s) }
                }
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        stopPolling()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        server.stop()
    }
}

// MARK: - WKUIDelegate：授予网页 getUserMedia 相机权限
extension WebReceiverViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        NSLog("[WebReceiver] 授予媒体捕获权限 type=\(type.rawValue)")
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        NSLog("[WebReceiver][JS] \(message)")
        completionHandler()
    }
}

// MARK: - WKNavigationDelegate
extension WebReceiverViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[WebReceiver] 导航失败: \(error)")
        onStatus?("页面加载失败")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[WebReceiver] 预加载失败: \(error)")
        onStatus?("页面加载失败")
    }
}

// MARK: - 工具
extension WebReceiverViewController {
    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - 弱引用消息中继
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: WebReceiverViewController?
    init(_ vc: WebReceiverViewController) { self.viewController = vc }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        viewController?.handle(message)
    }
}
