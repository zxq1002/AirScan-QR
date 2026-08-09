//
//  WebReceiverViewController.swift
//  ios-cfc-client
//
//  WKWebView 接收端宿主（路线 B / v1.2.0）
//
//  职责：
//   1. 启动本地 HTTP 服务，托管 Bundle 内 WebResources（harness.html + cimbar-deps）；
//   2. 用 WKWebView 加载该页面，让摄像头与 cimbar WASM 解码全部跑在网页侧；
//   3. 通过 WKUIDelegate 授予 getUserMedia 相机权限；
//   4. 通过 WKScriptMessageHandler 接收进度与最终文件，交回 SwiftUI。
//
//  与网页端解码逐字节同源（同一份 recv.js + cimbar_js.wasm）。
//

import UIKit
import WebKit
import AVFoundation

final class WebReceiverViewController: UIViewController {

    // 回调给 SwiftUI
    var onFile: ((String, Data) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?

    private let server = WebReceiverServer()
    private var webView: WKWebView!
    private var startedServer = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)
        requestCameraAccess()
        setupWebView()
        startServerAndLoad()
    }

    // MARK: - 相机权限（App 层，WKWebView 还会再走一次 WKUIDelegate 授权）
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
        for name in ["fileComplete", "fileMeta", "progress", "cameraStarted", "jslog"] {
            ucc.add(relay, name: name)
        }

        // 把 WKWebView 内的 JS console 转发到原生，便于观测 wasm / 解码管线
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
            NSLog("[WebReceiver] ❌ 缺少 WebResources")
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
                NSLog("[WebReceiver] ❌ 本地服务启动失败: \(error)")
                onStatus?("本地服务启动失败")
            }
        }
    }

    // MARK: - JS 消息处理
    fileprivate func handle(_ message: WKScriptMessage) {
        switch message.name {
        case "fileComplete":
            guard let body = message.body as? [String: Any],
                  let name = body["name"] as? String,
                  let b64 = body["data"] as? String,
                  let data = Data(base64Encoded: b64) else {
                NSLog("[WebReceiver] ⚠️ fileComplete 解析失败")
                return
            }
            NSLog("[WebReceiver] ✅ 收到文件 \(name) (\(data.count) bytes)")
            onFile?(name, data)

        case "fileMeta":
            if let body = message.body as? [String: Any], let name = body["name"] as? String {
                onStatus?("正在接收：\(name)")
            }

        case "progress":
            if let body = message.body as? [String: Any], let p = body["percent"] as? Int {
                onProgress?(p)
            }

        case "cameraStarted":
            onStatus?("相机已启动，正在扫描…")

        case "jslog":
            if let body = message.body as? [String: Any], let msg = body["msg"] as? String {
                NSLog("[JS] %@", msg)
            }

        default:
            break
        }
    }

    deinit {
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

    // 兜底：JS alert() 直接打印，不弹窗打断扫描
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

// MARK: - 弱引用消息中继（避免 userContentController ↔ VC 循环引用）
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: WebReceiverViewController?
    init(_ vc: WebReceiverViewController) { self.viewController = vc }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        viewController?.handle(message)
    }
}
