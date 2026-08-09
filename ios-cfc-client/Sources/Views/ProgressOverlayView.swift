//
//  ProgressOverlayView.swift
//  ios-cfc-client
//
//  Realtime HUD Overlay displaying Progress, FPS, Bandwidth
//
//  v1.1.0 对齐网页端接收 HUD：
//   - decodeTimer  → 解码计时 (⏱ MM:SS)
//   - mode-val     → 当前解码模式 (Auto/B/Bm/Bu/4C)
//   - recvFileName → 文件名
//   - decodeInfo   → 状态说明（含“解码引擎未链接”诚实提示）
//

import SwiftUI

struct ProgressOverlayView: View {
    let rank: Int
    let total: Int
    let fps: Double
    let bytesPerSec: Double

    // v1.1.0 新增（对齐网页端 HUD）
    var elapsedSeconds: Int = 0
    var modeString: String = "Auto"
    var backendReady: Bool = false
    var statusText: String = ""
    var fileName: String = ""

    var progressPercentage: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(rank) / Double(total))
    }

    private var timerText: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "⏱ %02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 10) {
            // 顶部：标题 + 计时 + 模式
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CFC 高速接收中")
                        .font(.caption)
                        .fontWeight(.black)
                        .foregroundColor(.blue)

                    if total > 0 {
                        Text("进度: \(rank) / \(total)")
                            .font(.headline)
                            .fontDesign(.monospaced)
                            .fontWeight(.bold)
                    } else {
                        Text("📷 请将摄像头正对屏幕条码")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }

                    if !fileName.isEmpty {
                        Text(fileName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(timerText)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)

                    Text(String(format: "%.1f FPS", fps))
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .fontWeight(.bold)
                        .foregroundColor(.green)

                    Text("模式: \(modeString)")
                        .font(.caption2)
                        .fontDesign(.monospaced)
                        .foregroundColor(.purple)

                    Text(String(format: "%.1f KB/s", bytesPerSec / 1024.0))
                        .font(.caption2)
                        .fontDesign(.monospaced)
                        .foregroundColor(.secondary)
                }
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.blue, .green], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progressPercentage)
                        .animation(.linear(duration: 0.2), value: progressPercentage)
                }
            }
            .frame(height: 8)

            // 解码引擎状态（诚实提示，不伪造进度）
            if !backendReady {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(statusText.isEmpty ? "解码引擎(libcimbar)未链接" : statusText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 20)
    }
}
