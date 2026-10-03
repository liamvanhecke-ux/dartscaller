import AVFoundation
import SwiftUI
import UIKit

/// Beheert de AVCaptureSession. Alle zware sessie-calls lopen op een eigen queue.
final class CameraController {

    enum SetupError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput
        var errorDescription: String? {
            switch self {
            case .noCamera: return "Geen camera aan de achterkant gevonden."
            case .cannotAddInput: return "Camera kon niet gestart worden."
            case .cannotAddOutput: return "Camerabeeld kon niet uitgelezen worden."
            }
        }
    }

    let session = AVCaptureSession()
    private(set) var device: AVCaptureDevice?
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "darts.camera.session")
    private(set) var isConfigured = false
    private(set) var frameRate: Double = 30

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func configure(delegate: AVCaptureVideoDataOutputSampleBufferDelegate, queue: DispatchQueue) throws {
        guard !isConfigured else { return }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw SetupError.noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else { throw SetupError.cannotAddOutput }
        session.addOutput(output)

        // Beelden rechtop (portret) aanleveren: zelfde oriëntatie als op het scherm.
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
        configure60fps(dev)
        device = dev
        isConfigured = true
    }

    /// 1080p @ 60 fps als het toestel dat kan, anders blijft de standaard (30 fps) actief.
    private func configure60fps(_ dev: AVCaptureDevice) {
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080 &&
                f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
        guard let format = candidates.first, (try? dev.lockForConfiguration()) != nil else { return }
        dev.activeFormat = format
        dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        dev.unlockForConfiguration()
        frameRate = 60
    }

    func start() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    var zoomFactor: CGFloat { device?.videoZoomFactor ?? 1 }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        let maxZoom = min(dev.maxAvailableVideoZoomFactor, 8)
        let z = min(max(factor, dev.minAvailableVideoZoomFactor), maxZoom)
        if animated { dev.ramp(toVideoZoomFactor: z, withRate: 3) } else { dev.videoZoomFactor = z }
        dev.unlockForConfiguration()
    }

    /// Vergrendelen is cruciaal: anders ziet de verschil-analyse autofocus/belichting als "pijl".
    func setLocked(_ locked: Bool) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        if locked {
            if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
            if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
            if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        } else {
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
        dev.unlockForConfiguration()
    }
}

// MARK: - Live preview voor SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var fill = false

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90
            }
        }
    }
}
