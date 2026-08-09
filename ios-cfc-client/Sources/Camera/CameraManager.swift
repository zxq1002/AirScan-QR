//
//  CameraManager.swift
//  ios-cfc-client
//
//  AVFoundation Camera Controller for High-speed Hardware Sample Buffer Capture
//
//  v1.1.0 对齐网页端 (recv.js init_video / watch_for_camera_pause)：
//   1. 帧率上限控制：对齐网页端 `frameRate: { ideal: 15 }`，降低运动模糊与功耗；
//   2. 相机停摆看门狗：对齐网页端 `watch_for_camera_pause` / `restart_paused_camera`，
//      iOS 上相机采集偶发“卡死”不再出帧，看门狗自动重启采集会话；
//   3. 线程安全的 FPS 统计；
//   4. 补光灯 (torch) 开关（弱光扫描增强）。
//

import Foundation
import AVFoundation
import CoreImage
import UIKit
import Combine

public class CameraManager: NSObject, ObservableObject {
    public static let shared = CameraManager()

    @Published public var isRunning: Bool = false
    @Published public var permissionGranted: Bool = false
    @Published public var currentFps: Double = 0.0
    /// 补光灯状态
    @Published public var isTorchOn: Bool = false

    public let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.airscan.cfc.cameraSessionQueue")
    private let sampleQueue = DispatchQueue(label: "com.airscan.cfc.sampleQueue", qos: .userInitiated)

    // FPS 统计（sampleQueue 上访问，主线程只读取快照）
    private var lastFrameTimestamp = Date()
    private var frameCounter = 0
    // 看门狗：最近一次成功出帧的时间（主线程读写）
    private var lastDeliveredFrameDate = Date()
    private var watchdogTimer: Timer?

    /// 帧率上限（对齐网页端 ideal≈15，这里取 20 作为余量；降低运动模糊/功耗）
    private let targetMaxFps: Int32 = 20
    /// 看门狗判定“停摆”的阈值（秒）
    private let stallThreshold: TimeInterval = 3.0

    override init() {
        super.init()
        checkCameraPermission()
    }

    public func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.permissionGranted = true
            self.setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    if granted { self.setupSession() }
                }
            }
        default:
            self.permissionGranted = false
        }
    }

    private func setupSession() {
        sessionQueue.async {
            guard !self.captureSession.isRunning else { return }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .hd1920x1080

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                print("❌ Failed to access back camera")
                self.captureSession.commitConfiguration()
                return
            }

            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }

            // 连续自动对焦 / 曝光 + 帧率上限（对齐网页端 continuous focus/exposure & ideal fps）
            do {
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                // 帧率上限：minFrameDuration = 1/targetMaxFps，即最高 targetMaxFps 帧
                let minDuration = CMTime(value: 1, timescale: self.targetMaxFps)
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.activeVideoMinFrameDuration = minDuration
                }
                camera.unlockForConfiguration()
            } catch {
                print("⚠️ Camera lock configuration failed: \(error)")
            }

            // Configure Video Data Output
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sampleQueue)

            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
                if let connection = self.videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }

            self.captureSession.commitConfiguration()
        }
    }

    public func startSession() {
        sessionQueue.async {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = true
                self.lastDeliveredFrameDate = Date()
                CFCDecoderBridge.sharedInstance().startDecodingSession()
                self.startWatchdog()
            }
        }
    }

    public func stopSession() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.stopWatchdog()
                CFCDecoderBridge.sharedInstance().stopDecodingSession()
            }
        }
    }

    // MARK: - 补光灯 (torch)
    public func toggleTorch() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              camera.hasTorch else { return }
        do {
            try camera.lockForConfiguration()
            if camera.isTorchModeSupported(.on) {
                let turnOn = camera.torchMode != .on
                camera.torchMode = turnOn ? .on : .off
                self.isTorchOn = turnOn
            }
            camera.unlockForConfiguration()
        } catch {
            print("⚠️ Torch toggle failed: \(error)")
        }
    }

    // MARK: - 相机停摆看门狗（对齐网页端 restart_paused_camera）
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        guard isRunning else { return }
        let idle = Date().timeIntervalSince(lastDeliveredFrameDate)
        if idle > stallThreshold {
            print("🚨 [Watchdog] 相机采集疑似停摆 (\(String(format: "%.1f", idle))s 无帧)，自动重启采集会话")
            restartSession()
        }
    }

    /// 对齐网页端 `Recv.init_video(_video)`：重新初始化采集链路
    public func restartSession() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            // 轻微延时后再启动，规避部分机型 stop/start 过快导致的会话假死
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.sessionQueue.async {
                    if !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }
                    DispatchQueue.main.async {
                        self.lastDeliveredFrameDate = Date()
                    }
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 线程安全地在 sampleQueue 上累计 FPS
        frameCounter += 1
        let now = Date()
        let interval = now.timeIntervalSince(lastFrameTimestamp)
        if interval >= 1.0 {
            let fps = Double(frameCounter) / interval
            frameCounter = 0
            lastFrameTimestamp = now
            DispatchQueue.main.async { self.currentFps = fps }
        }

        // 记录出帧时间（供看门狗使用）
        DispatchQueue.main.async { self.lastDeliveredFrameDate = now }

        // 交给解码桥（桥内部做背压：忙碌时自动丢弃本帧）
        _ = CFCDecoderBridge.sharedInstance().processSampleBuffer(sampleBuffer)
    }
}
