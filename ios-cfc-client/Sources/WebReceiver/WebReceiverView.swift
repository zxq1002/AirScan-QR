//
//  WebReceiverView.swift
//  ios-cfc-client
//
//  SwiftUI 包装：把 WebReceiverViewController（WKWebView 接收端）嵌入界面，
//  并在收到文件后复用现有 FilePreviewView 展示 / 保存 / 分享。
//

import SwiftUI
import UIKit

struct WebReceiverView: View {
    @State private var progress: Int = 0
    @State private var status: String = "初始化…"
    @State private var receivedFile: (name: String, data: Data)?
    @State private var showPreview = false

    var body: some View {
        ZStack {
            WebReceiverRepresentable(
                onFile: { name, data in
                    receivedFile = (name, data)
                    showPreview = true
                },
                onProgress: { p in progress = p },
                onStatus: { s in status = s }
            )
            .ignoresSafeArea()

            // 顶部 HUD
            VStack {
                hud
                Spacer()
            }
            .padding(.top, 12)

            // 完成文件弹窗（复用现有组件）
            if showPreview, let f = receivedFile {
                Color.black.opacity(0.4).ignoresSafeArea()
                FilePreviewView(fileName: f.name, fileData: f.data) {
                    showPreview = false
                    receivedFile = nil
                    progress = 0
                    status = "已就绪，继续扫描…"
                }
                .transition(.scale)
            }
        }
    }

    private var hud: some View {
        VStack(spacing: 8) {
            HStack {
                Text("CFC 接收中")
                    .font(.caption).fontWeight(.black).foregroundColor(.blue)
                Spacer()
                Text("\(progress)%")
                    .font(.caption).fontDesign(.monospaced).fontWeight(.bold).foregroundColor(.green)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.25))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.blue, .green], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(progress, 100)) / 100.0)
                }
            }
            .frame(height: 7)
            Text(status)
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }
}

// MARK: - UIViewControllerRepresentable
struct WebReceiverRepresentable: UIViewControllerRepresentable {
    var onFile: (String, Data) -> Void
    var onProgress: (Int) -> Void
    var onStatus: (String) -> Void

    func makeUIViewController(context: Context) -> WebReceiverViewController {
        let vc = WebReceiverViewController()
        vc.onFile = { name, data in DispatchQueue.main.async { onFile(name, data) } }
        vc.onProgress = { p in DispatchQueue.main.async { onProgress(p) } }
        vc.onStatus = { s in DispatchQueue.main.async { onStatus(s) } }
        return vc
    }

    func updateUIViewController(_ uiViewController: WebReceiverViewController, context: Context) {}
}
