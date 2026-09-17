import SwiftUI
import AVFoundation
import Photos

@main
struct HyperlapseApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
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
            CameraPreview(camera: camera)
                .ignoresSafeArea()

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
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
                        Button(action: { camera.switchCamera() }) {
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
            camera.startSession()
        }
    }
}

class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isRecording = false
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentPosition: AVCaptureDevice.Position = .back
    private var activeDeviceInput: AVCaptureDeviceInput?
    private var recordCompletion: ((URL) -> Void)?

    func checkPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.setupSession() }
            }
        } else {
            setupSession()
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        setupInput(position: currentPosition)

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()
        configureStabilization()
    }

    private func setupInput(position: AVCaptureDevice.Position) {
        if let current = activeDeviceInput {
            session.removeInput(current)
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        session.addInput(input)
        activeDeviceInput = input
        currentPosition = position
    }

    func switchCamera() {
        session.beginConfiguration()
        setupInput(position: currentPosition == .back ? .front : .back)
        session.commitConfiguration()
        configureStabilization()
    }

    func configureStabilization() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .cinematicExtended
        }
    }

    func startSession() {
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func startRecording() {
        configureStabilization()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording(completion: @escaping (URL) -> Void) {
        recordCompletion = completion
        movieOutput.stopRecording()
        isRecording = false
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.recordCompletion?(outputFileURL)
            self.recordCompletion = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraController

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = uiView.bounds
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
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.red)
                            .frame(width: 46, height: 46)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    Spacer()
                    Button(action: exportAndSave) {
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

                HStack {
                    ForEach(0..<speeds.count, id: \.self) { index in
                        Button(action: {
                            selectedIndex = index
                            player?.rate = Float(currentSpeed)
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.35))
                                    .frame(width: 6, height: 6)
                                if selectedIndex == index {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 42, height: 42)
                                        .overlay(
                                            Text("\(Int(speeds[index]))x")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundColor(.black)
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }

            if isExporting {
                Color.black.opacity(0.7).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().tint(.white).scaleEffect(1.4)
                    Text("Saving to Photos...")
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
                      let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    DispatchQueue.main.async { isExporting = false }
                    return
                }

                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try compTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                
                let transform = try await videoTrack.load(.preferredTransform)
                compTrack.preferredTransform = transform

                let targetDuration = CMTime(value: Int64(Double(duration.value) / speed), timescale: duration.timescale)
                compTrack.scaleTimeRange(timeRange, toDuration: targetDuration)

                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    DispatchQueue.main.async { isExporting = false }
                    return
                }
                session.outputURL = outputURL
                session.outputFileType = .mp4

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
                        onDismiss()
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
