import SwiftUI
import AVFoundation
import Photos
import UIKit

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

    private let impactMed = UIImpactFeedbackGenerator(style: .medium)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
                        impactMed.impactOccurred()
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
                            impactLight.impactOccurred()
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
            impactMed.prepare()
            impactLight.prepare()
            camera.checkPermissions()
        }
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
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentPosition: AVCaptureDevice.Position = .back
    private var activeVideoInput: AVCaptureDeviceInput?
    private var activeAudioInput: AVCaptureDeviceInput?
    private var recordCompletion: ((URL) -> Void)?
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    func checkPermissions() {
        sessionQueue.async {
            self.requestPermissionsAndSetup()
        }
    }

    private func requestPermissionsAndSetup() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if videoStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.requestAudioAndSetup() }
            }
        } else if videoStatus == .authorized {
            requestAudioAndSetup()
        }
    }

    private func requestAudioAndSetup() {
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.setupSession() }
            }
        } else {
            sessionQueue.async { self.setupSession() }
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        setupVideoInput(position: currentPosition)
        setupAudioInput()

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

        session.addInput(input)
        activeVideoInput = input
        currentPosition = position
    }

    private func setupAudioInput() {
        guard activeAudioInput == nil,
              let audioDevice = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: audioDevice),
              session.canAddInput(input) else { return }

        session.addInput(input)
        activeAudioInput = input
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
            connection.preferredVideoStabilizationMode = .cinematicExtended
        }
    }

    func startSession() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func startRecording() {
        configureStabilization()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        DispatchQueue.main.async { self.isRecording = true }
    }

    func stopRecording(completion: @escaping (URL) -> Void) {
        recordCompletion = completion
        movieOutput.stopRecording()
        DispatchQueue.main.async { self.isRecording = false }
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

    private let impactMed = UIImpactFeedbackGenerator(style: .medium)
    private let notifyFeedback = UINotificationFeedbackGenerator()

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
                        impactMed.impactOccurred()
                        onDismiss()
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
                        notifyFeedback.notificationOccurred(.success)
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
                    Text("Saving to Photos...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            impactMed.prepare()
            notifyFeedback.prepare()

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

struct DraggableSpeedSlider: View {
    let speeds: [Double]
    @Binding var selectedIndex: Int
    var onSpeedChanged: (Double) -> Void

    private let selectionFeedback = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let padding: CGFloat = 26
            let usableWidth = totalWidth - (padding * 2)
            let step = usableWidth / CGFloat(max(1, speeds.count - 1))
            let thumbX = padding + (CGFloat(selectedIndex) * step)

            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.6))

                // Markers
                HStack(spacing: 0) {
                    ForEach(0..<speeds.count, id: \.self) { i in
                        Circle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 6, height: 6)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, padding)

                // Drag Thumb Indicator
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
                            selectionFeedback.selectionChanged()
                            onSpeedChanged(speeds[newIndex])
                        }
                    }
            )
        }
        .frame(height: 54)
        .padding(.horizontal, 20)
        .onAppear {
            selectionFeedback.prepare()
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
