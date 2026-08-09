//
//  WebReceiverView.swift
//  ios-cfc-client
//
//  SwiftUI 包装：把 WebReceiverViewController（WKWebView 接收端）嵌入界面，
//  提供对齐网页端的实时 HUD（进度、计时、文件名、模式），并在收到文件后
//  复用现有 FilePreviewView 展示 / 保存 / 分享。
//

import SwiftUI
import UIKit
import Combine

struct WebReceiverView: View {
    // 进度 / 状态
    @State private var progress: Int = 0
    @State private var status: String = "正在初始化…"
    @State private var fileName: String = ""
    @State private var modeText: String = ""
    @State private var elapsedSeconds: Int = 0
    @State private var isScanning = false

    // 完成文件
    @State private var receivedFile: (name: String, data: Data)?
    @State private var showPreview = false

    // 每秒计时器
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            WebReceiverRepresentable(
                onFile: { name, data in
                    receivedFile = (name, data)
                    showPreview = true
                    isScanning = false
                },
                onProgress: { p in progress = p },
                onStatus: { s in status = s },
                onFileName: { n in fileName = n },
                onScanningStarted: { isScanning = true },
                onModeDetected: { m in modeText = m }
            )

            // 顶部 HUD
            VStack(spacing: 0) {
                fullHUD
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                Spacer()
            }

            // 完成文件弹窗
            if showPreview, let f = receivedFile {
                Color.black.opacity(0.4).ignoresSafeArea()
                FilePreviewView(fileName: f.name, fileData: f.data) {
                    showPreview = false
                    receivedFile = nil
                    progress = 0
                    elapsedSeconds = 0
                    fileName = ""
                    status = "已就绪，继续扫描…"
                    isScanning = true
                }
                .transition(.scale)
            }
        }
        .onReceive(ticker) { _ in
            if isScanning { elapsedSeconds += 1 }
        }
    }

    // MARK: - 完整 HUD（对齐网页端 decodeTimer / decodeStats / decodeInfo / recvFileName / mode-val）
    private var fullHUD: some View {
        VStack(spacing: 10) {
            // 第一行：标题 + 计时 + 模式
            HStack {
                Text("CFC 扫码接收")
                    .font(.caption).fontWeight(.black).foregroundColor(.blue)

                Spacer()

                HStack(spacing: 10) {
                    // 解码计时
                    Label(timerFormatted, systemImage: "timer")
                        .font(.caption).fontDesign(.monospaced).fontWeight(.bold)
                        .foregroundColor(.blue)

                    // 模式
                    if !modeText.isEmpty {
                        Text("模式:\(modeText)")
                            .font(.caption2).fontDesign(.monospaced).fontWeight(.bold)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .cornerRadius(6)
                    }
                }
            }

            // 第二行：状态 + 百分比
            HStack {
                Text(status)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(progress)%")
                    .font(.caption).fontDesign(.monospaced).fontWeight(.bold)
                    .foregroundColor(progress >= 100 ? .green : .orange)
            }

            // 第三行：文件名（有则显示）
            if !fileName.isEmpty {
                Text(fileName)
                    .font(.caption2).foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.blue, .green], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(progress, 100)) / 100.0)
                        .animation(.linear(duration: 0.25), value: progress)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 8)
    }

    private var timerFormatted: String {
        String(format: "⏱ %02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
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

// MARK: - UIViewControllerRepresentable
struct WebReceiverRepresentable: UIViewControllerRepresentable {
    var onFile: (String, Data) -> Void
    var onProgress: (Int) -> Void
    var onStatus: (String) -> Void
    var onFileName: ((String) -> Void)?
    var onScanningStarted: (() -> Void)?
    var onModeDetected: ((String) -> Void)?

    func makeUIViewController(context: Context) -> WebReceiverViewController {
        let vc = WebReceiverViewController()
        vc.onFile = { name, data in DispatchQueue.main.async { onFile(name, data) } }
        vc.onProgress = { p in DispatchQueue.main.async { onProgress(p) } }
        vc.onStatus = { s in DispatchQueue.main.async { onStatus(s) } }
        vc.onFileName = { n in DispatchQueue.main.async { onFileName?(n) } }
        vc.onScanningStarted = { DispatchQueue.main.async { onScanningStarted?() } }
        vc.onModeDetected = { m in DispatchQueue.main.async { onModeDetected?(m) } }
        return vc
    }

    func updateUIViewController(_ uiViewController: WebReceiverViewController, context: Context) {}
}
