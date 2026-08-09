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
                    Label("基于硬件级 AVFoundation 直出像素流", systemImage: "cpu")
                    Label("避开 Safari WebKit 渲染失真", systemImage: "eye.slash")
                    Label("支持 4C 高密度彩色图标色码", systemImage: "paintpalette")
                    Label("1MB 文件约 40s 完成传输", systemImage: "speedometer")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding()

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
