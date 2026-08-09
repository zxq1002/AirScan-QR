//
//  FilePreviewView.swift
//  ios-cfc-client
//
//  File Preview & Native iOS Share Sheet Controller
//

import SwiftUI
import UIKit

struct FilePreviewView: View {
    let fileName: String
    let fileData: Data
    let onDismiss: () -> Void

    @State private var isSharing = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("🎉 文件接收成功")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(fileName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("\(fileData.count / 1024) KB")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundColor(.gray)
            }

            VStack(spacing: 12) {
                Button(action: {
                    isSharing = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("保存到文件 / 分享")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(14)
                }

                Button(action: onDismiss) {
                    Text("完成并返回")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.gray)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(32)
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(24)
        .shadow(radius: 20)
        .sheet(isPresented: $isSharing) {
            ShareSheet(activityItems: [createTemporaryFileURL()])
        }
    }

    private func createTemporaryFileURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? fileData.write(to: fileURL)
        return fileURL
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
