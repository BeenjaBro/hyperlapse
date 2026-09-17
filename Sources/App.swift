import SwiftUI
import AVFoundation
import AudioToolbox
import Photos
import UIKit

// MARK: - Bulletproof System Haptic Helper
enum AppHaptics {
    static func tick() {
        AudioServicesPlaySystemSound(1519)
    }
    static func tap() {
        AudioServicesPlaySystemSound(1520)
    }
}

@main
struct HyperlapseApp: App {
    init() {
        // Prevent screen dimming and auto-lock across the entire app
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

struct MainView: View {
    @StateObject private var camera = CameraController()
    @State private var recordedURL: URL?
    @State private var isShowingPreview = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url = recordedURL, isShowingPreview {
                PreviewView(videoURL: url) {
                    recordedURL = nil
                    isShowingPreview = false
                    camera.startSession()
                }
            } else {
                CameraView(camera: camera) { url in
                    recordedURL = url
                    isShowingPreview = true
                }
            }
        }
    }
}

struct CameraView: View {
    @ObservedObject var camera: CameraController
    var onFinishRecording: (URL) -> Void

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack {
                // Live Hardware Stabilization Status Badge
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(camera.stabilizationStatusText.contains("OFF") ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                        Text(camera.stabilizationStatusText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    
                    Spacer()
                }
                .padding(.top, 50)
                .padding(.leading, 20)

                Spacer()

                // Live recording time elapsed
                if camera.isRecording {
                    Text(formatTime(camera.recordingDuration))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                }

                HStack {
                    Spacer()
                    Button(action: {
                        AppHaptics.tap()
                        if camera.isRecording {
                            camera.stopRecording(completion: onFinishRecording)
                        } else {
                            camera.startRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.8), lineWidth: 5)
                                .frame(width: 80, height: 80)
                            if camera.isRecording {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red)
                                    .frame(width: 32, height: 32)
                            } else {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 66, height: 66)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.bottom, 40)
                .overlay(alignment: .trailing) {
                    if !camera.isRecording {
                        Button(action: {
                            AppHaptics.tap()
                            camera.switchCamera()
                        }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(14)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 30)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .onAppear {
            camera.checkPermissions()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

class CameraPreviewView: UIView {
    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}

class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isRecording = false
    @Published var stabilizationStatusText = "STABILIZATION: CHECKING..."
    @Published var recordingDuration: Double = 0

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentPosition: AVCaptureDevice.Position = .back
    private var activeDevice: AVCaptureDevice?
    private var activeVideoInput: AVCaptureDeviceInput?
    private var recordCompletion: ((URL) -> Void)?
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var timer: Timer?

    func checkPermissions() {
        sessionQueue.async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted { self.setupSession() }
                }
            } else if status == .authorized {
                self.setupSession()
            }
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        
        // Use input priority so we can configure activeFormat directly for full gyro overscan
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        setupVideoInput(position: currentPosition)

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()
        
        configureStabilization()
        startSession()
    }

    private func setupVideoInput(position: AVCaptureDevice.Position) {
        if let current = activeVideoInput {
            session.removeInput(current)
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        // Find 1080p 30fps format that supports cinematicExtended or cinematic
        var targetFormat: AVCaptureDevice.Format? = nil
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if dims.width == 1920 && dims.height == 1080 {
                let supports30 = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                if supports30 && format.isVideoStabilizationModeSupported(.cinematicExtended) {
                    targetFormat = format
                    break
                }
            }
        }

        if targetFormat == nil {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dims.width == 1920 && dims.height == 1080 {
                    let supports30 = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                    if supports30 && format.isVideoStabilizationModeSupported(.cinematic) {
                        targetFormat = format
                        break
                    }
                }
            }
        }

        do {
            try device.lockForConfiguration()
            if let target = targetFormat {
                device.activeFormat = target
            }
            // Lock constant 30 FPS to eliminate speed variations
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            print("Device configuration error: \(error)")
        }

        session.addInput(input)
        activeVideoInput = input
        activeDevice = device
        currentPosition = position
    }

    func switchCamera() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.setupVideoInput(position: self.currentPosition == .back ? .front : .back)
            self.session.commitConfiguration()
            self.configureStabilization()
        }
    }

    func configureStabilization() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        if connection.isVideoStabilizationSupported {
            if let device = activeDevice, device.activeFormat.isVideoStabilizationModeSupported(.cinematicExtended) {
                connection.preferredVideoStabilizationMode = .cinematicExtended
            } else if let device = activeDevice, device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                connection.preferredVideoStabilizationMode = .cinematic
            } else {
                connection.preferredVideoStabilizationMode = .standard
            }
        }
        
        updateStabilizationStatus()
    }

    private func updateStabilizationStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let connection = self.movieOutput.connection(with: .video) else {
                self.stabilizationStatusText = "STABILIZATION: NONE"
                return
            }
            switch connection.activeVideoStabilizationMode {
            case .off:
                self.stabilizationStatusText = "STABILIZATION: OFF"
            case .standard:
                self.stabilizationStatusText = "STABILIZATION: STANDARD"
            case .cinematic:
                self.stabilizationStatusText = "STABILIZATION: CINEMATIC"
            case .cinematicExtended:
                self.stabilizationStatusText = "STABILIZATION: EXTENDED"
            case .previewOptimized:
                self.stabilizationStatusText = "STABILIZATION: PREVIEW"
            @unknown default:
                self.stabilizationStatusText = "STABILIZATION: ACTIVE"
            }
        }
    }

    func startSession() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.updateStabilizationStatus()
        }
    }

    func startRecording() {
        configureStabilization()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.recordingDuration += 1
            }
        }
    }

    func stopRecording(completion: @escaping (URL) -> Void) {
        recordCompletion = completion
        movieOutput.stopRecording()

        DispatchQueue.main.async {
            self.isRecording = false
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.recordCompletion?(outputFileURL)
            self.recordCompletion = nil
        }
    }
}

struct PreviewView: View {
    let videoURL: URL
    var onDismiss: () -> Void

    let speeds: [Double] = [1, 2, 4, 6, 8, 10, 12, 24, 40]
    @State private var selectedIndex: Int = 4 // Default 8x
    @State private var player: AVPlayer?
    @State private var originalDuration: Double = 0
    @State private var isExporting = false

    var currentSpeed: Double { speeds[selectedIndex] }
    var adjustedDuration: Double {
        guard currentSpeed > 0 else { return originalDuration }
        return originalDuration / currentSpeed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                LoopedVideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button(action: {
                        AppHaptics.tap()
                        cleanupAndDismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.red)
                            .frame(width: 46, height: 46)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    Spacer()
                    Button(action: {
                        AppHaptics.tap()
                        exportAndSave()
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.green)
                            .frame(width: 46, height: 46)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)

                Spacer()

                HStack(spacing: 10) {
                    Text(formatTime(originalDuration))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    Text(formatTime(adjustedDuration))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.bottom, 14)

                DraggableSpeedSlider(
                    speeds: speeds,
                    selectedIndex: $selectedIndex,
                    onSpeedChanged: { speed in
                        player?.rate = Float(speed)
                    }
                )
                .padding(.bottom, 40)
            }

            if isExporting {
                Color.black.opacity(0.7).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().tint(.white).scaleEffect(1.4)
                    Text("Saving Stabilized Video...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            let p = AVPlayer(url: videoURL)
            p.isMuted = true
            self.player = p

            let asset = AVAsset(url: videoURL)
            Task {
                if let duration = try? await asset.load(.duration) {
                    DispatchQueue.main.async {
                        self.originalDuration = CMTimeGetSeconds(duration)
                    }
                }
            }

            p.play()
            p.rate = Float(currentSpeed)

            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem,
                queue: .main
            ) { _ in
                p.seek(to: .zero)
                p.play()
                p.rate = Float(self.currentSpeed)
            }
        }
    }

    private func cleanupAndDismiss() {
        player?.pause()
        player = nil
        onDismiss()
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func exportAndSave() {
        isExporting = true
        let asset = AVAsset(url: videoURL)
        let speed = currentSpeed

        Task {
            do {
                let composition = AVMutableComposition()
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
                      let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    DispatchQueue.main.async { isExporting = false }
                    return
                }

                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                let targetDuration = CMTime(value: Int64(Double(duration.value) / speed), timescale: duration.timescale)

                try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                let transform = try await videoTrack.load(.preferredTransform)
                compVideoTrack.preferredTransform = transform
                compVideoTrack.scaleTimeRange(timeRange, toDuration: targetDuration)

                // Force steady 30 FPS sampling on export
                let naturalSize = try await videoTrack.load(.naturalSize)
                let isRotated = (transform.a == 0 && abs(transform.b) == 1.0) || (transform.d == 0 && abs(transform.c) == 1.0)
                let renderWidth = isRotated ? naturalSize.height : naturalSize.width
                let renderHeight = isRotated ? naturalSize.width : naturalSize.height

                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = CGSize(width: renderWidth, height: renderHeight)
                videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: targetDuration)

                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
                layerInstruction.setTransform(transform, at: .zero)
                instruction.layerInstructions = [layerInstruction]
                videoComposition.instructions = [instruction]

                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    DispatchQueue.main.async { isExporting = false }
                    return
                }
                session.outputURL = outputURL
                session.outputFileType = .mp4
                session.videoComposition = videoComposition

                await withCheckedContinuation { continuation in
                    session.exportAsynchronously {
                        continuation.resume()
                    }
                }

                if session.status == .completed {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                    }
                    DispatchQueue.main.async {
                        isExporting = false
                        cleanupAndDismiss()
                    }
                } else {
                    DispatchQueue.main.async { isExporting = false }
                }
            } catch {
                DispatchQueue.main.async { isExporting = false }
            }
        }
    }
}

struct DraggableSpeedSlider: View {
    let speeds: [Double]
    @Binding var selectedIndex: Int
    var onSpeedChanged: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let padding: CGFloat = 30
            let usableWidth = totalWidth - (padding * 2)
            let step = usableWidth / CGFloat(max(1, speeds.count - 1))
            let thumbX = padding + (CGFloat(selectedIndex) * step)

            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.6))

                ForEach(0..<speeds.count, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .position(x: padding + (CGFloat(i) * step), y: geometry.size.height / 2)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                    .overlay(
                        Text("\(Int(speeds[selectedIndex]))x")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                    )
                    .position(x: thumbX, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let touchX = value.location.x - padding
                        let fraction = max(0, min(1, touchX / usableWidth))
                        let newIndex = Int(round(fraction * CGFloat(speeds.count - 1)))
                        if newIndex != selectedIndex && newIndex >= 0 && newIndex < speeds.count {
                            selectedIndex = newIndex
                            AppHaptics.tick()
                            onSpeedChanged(speeds[newIndex])
                        }
                    }
            )
        }
        .frame(height: 54)
        .padding(.horizontal, 20)
    }
}

struct LoopedVideoPlayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
