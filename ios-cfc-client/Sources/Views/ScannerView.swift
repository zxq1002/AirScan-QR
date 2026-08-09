//
//  ScannerView.swift
//  ios-cfc-client
//
//  SwiftUI Camera Live Preview Layer and Scanner HUD
//
//  v1.1.0 对齐网页端接收端控制面：
//   - 解码计时器（对齐 decodeTimer）
//   - 重置按钮（对齐“🔄 重置”）
//   - 模式选择（对齐编码模式 B/Bm/Bu/4C + Auto）
//   - 补光灯开关（弱光增强）
//   - 完成后自动回到扫码状态，继续接收下一个文件
//

import SwiftUI
import AVFoundation
import Combine

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

struct ScannerView: View {
    @ObservedObject var cameraManager = CameraManager.shared

    // 解码进度
    @State private var rank: Int = 0
    @State private var total: Int = 0
    @State private var fps: Double = 0.0
    @State private var bytesPerSec: Double = 0.0

    // v1.1.0：HUD 对齐字段
    @State private var elapsedSeconds: Int = 0
    @State private var modeString: String = "Auto"
    @State private var backendReady: Bool = false
    @State private var statusText: String = ""
    @State private var recvFileName: String = ""
    @State private var selectedMode: Int = 0       // 0=Auto

    // 完成文件
    @State private var completedFileName: String?
    @State private var completedData: Data?

    // 每秒计时器（对齐 decodeTimer）
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let modeOptions: [(label: String, value: Int)] = [
        ("Auto", 0), ("B", 68), ("Bm", 67), ("Bu", 66), ("4C", 4)
    ]

    var body: some View {
        ZStack {
            if cameraManager.permissionGranted {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()

                // 取景框
                VStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.blue.opacity(0.8), lineWidth: 3)
                            .frame(width: 280, height: 280)
                        Image(systemName: "viewfinder")
                            .font(.system(size: 80))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Spacer()
                }

                // HUD + 底部控制栏
                VStack {
                    ProgressOverlayView(
                        rank: rank,
                        total: total,
                        fps: cameraManager.currentFps,
                        bytesPerSec: bytesPerSec,
                        elapsedSeconds: elapsedSeconds,
                        modeString: modeString,
                        backendReady: backendReady,
                        statusText: statusText,
                        fileName: recvFileName
                    )
                    .padding(.top, 16)

                    Spacer()

                    controlBar
                        .padding(.bottom, 24)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("需要相机权限以接收 Cimbar 传输")
                        .font(.headline)
                    Button("前往设置开启") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }

            // 完成文件弹窗
            if let name = completedFileName, let data = completedData {
                Color.black.opacity(0.4).ignoresSafeArea()

                FilePreviewView(fileName: name, fileData: data) {
                    resetForNextFile()
                }
                .transition(.scale)
            }
        }
        .onAppear { setupDelegateAndStart() }
        .onDisappear { cameraManager.stopSession() }
        .onReceive(ticker) { _ in
            if cameraManager.isRunning {
                elapsedSeconds += 1
            }
        }
    }

    // MARK: - 底部控制栏（补光灯 / 模式 / 重置）
    private var controlBar: some View {
        HStack(spacing: 14) {
            // 补光灯
            Button(action: { cameraManager.toggleTorch() }) {
                Image(systemName: cameraManager.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }

            Spacer()

            // 模式选择
            Menu {
                ForEach(modeOptions, id: \.value) { opt in
                    Button(action: {
                        selectedMode = opt.value
                        modeString = opt.label
                        CFCDecoderBridge.sharedInstance().configureMode(opt.value)
                    }) {
                        HStack {
                            Text(opt.label)
                            if selectedMode == opt.value { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text("模式:\(modeString)")
                }
                .font(.footnote)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.black.opacity(0.5))
                .cornerRadius(20)
            }

            Spacer()

            // 重置
            Button(action: { hardReset() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 逻辑
    private func setupDelegateAndStart() {
        let handler = DecoderDelegateHandler.shared
        CFCDecoderBridge.sharedInstance().delegate = handler

        handler.onProgress = { r, t, f, b in
            self.rank = r
            self.total = t
            self.fps = f
            self.bytesPerSec = b
        }
        handler.onModeStatus = { mode, ready, status in
            self.backendReady = ready
            self.statusText = status
            // 仅当解码器锁定了模式才覆盖显示，Auto 状态保持用户选择
            if mode > 0 { self.modeString = Self.modeName(mode) }
        }
        handler.onFileName = { name in
            self.recvFileName = name
        }
        handler.onComplete = { name, data in
            self.completedFileName = name
            self.completedData = data
        }

        cameraManager.startSession()
    }

    private func resetForNextFile() {
        completedFileName = nil
        completedData = nil
        rank = 0
        total = 0
        recvFileName = ""
        elapsedSeconds = 0
        CFCDecoderBridge.sharedInstance().resetDecoder()
        cameraManager.startSession()
    }

    private func hardReset() {
        rank = 0
        total = 0
        recvFileName = ""
        elapsedSeconds = 0
        CFCDecoderBridge.sharedInstance().resetDecoder()
        cameraManager.restartSession()
    }

    static func modeName(_ value: Int) -> String {
        switch value {
        case 4: return "4C"
        case 66: return "Bu"
        case 67: return "Bm"
        case 68: return "B"
        default: return "Auto"
        }
    }
}

// MARK: - 解码回调桥接
class DecoderDelegateHandler: NSObject, CFCDecoderDelegate {
    static let shared = DecoderDelegateHandler()

    var onProgress: ((Int, Int, Double, Double) -> Void)?
    var onComplete: ((String, Data) -> Void)?
    var onModeStatus: ((Int, Bool, String) -> Void)?
    var onFileName: ((String) -> Void)?

    func didUpdateProgress(withRank rank: Int, total: Int, fps: Double, bytesPerSec: Double) {
        onProgress?(rank, total, fps, bytesPerSec)
    }

    func didUpdateActiveMode(_ mode: Int, backendReady: Bool, statusText: String) {
        onModeStatus?(mode, backendReady, statusText)
    }

    func didCompleteTransfer(withFileName fileName: String, fileData: Data) {
        onComplete?(fileName, fileData)
    }

    func didFailWithError(_ errorMessage: String) {
        NSLog("[ScannerView] 解码失败: %@", errorMessage)
    }
}
