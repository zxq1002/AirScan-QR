//
//  MainView.swift
//  ios-cfc-client
//
//  Main iOS SwiftUI Navigation View
//

import SwiftUI

struct MainView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WebReceiverView()
                .tabItem {
                    Label("扫码接收", systemImage: "qrcode.viewfinder")
                }
                .tag(0)

            VStack(spacing: 20) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)

                Text("Cimbar / CFC 传输说明")
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 12) {
                    Label("复用与网页端逐字节同源的 WebAssembly 解码引擎", systemImage: "cpu")
                    Label("引擎内嵌 libcimbar + OpenCV，喷泉码免反向链路", systemImage: "square.stack.3d.up")
                    Label("WKWebView + 本地 HTTP 同源服务承载解码", systemImage: "safari")
                    Label("3 个 Web Worker 并行解码，Zstd 解压还原", systemImage: "cpu.fill")
                    Label("自动识别 B / Bm / Bu / 4C 四种模式", systemImage: "paintpalette")
                    Label("识别到码才起表，目标丢失自动暂停计时", systemImage: "timer")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Text("传输耗时取决于模式、帧率、光照、距离与机型。iOS 端实测：B 模式 15 FPS 下 1MB 约 32 秒；网页端参考值约 40 秒（见 CIMBAR-TRANSFER-README）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 40)
            .tabItem {
                Label("关于算法", systemImage: "info.circle")
            }
            .tag(1)
        }
        .accentColor(.blue)
    }
}
