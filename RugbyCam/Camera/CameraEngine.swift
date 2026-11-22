import AVFoundation
import CoreMedia
import Foundation

/// A zoom level that sits on one of the phone's real lenses (or on the sharp
/// 2x crop of the main sensor), so the picture is not digitally enlarged.
struct LensStop: Identifiable, Equatable {
    var factor: Double            // the camera's zoom factor
    var label: String             // what is shown on the button: "0.5", "1", "2", "4"

    var id: Double { factor }
}

struct CameraInfo: Equatable {
    var deviceName = ""
    var width = 0
    var height = 0
    var fps = 0
    var minZoom = 1.0             // camera zoom factor
    var maxZoom = 1.0
    var wideZoom = 1.0            // zoom factor of the 1x lens
    var displayMultiplier = 1.0   // zoom shown on screen = zoom factor x this
    var lensStops: [LensStop] = []
}

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No back camera with a usable video format was found."
        case .cannotAddInput: return "The camera could not be attached."
        case .cannotAddOutput: return "The video output could not be attached."
        }
    }
}

protocol CameraEngineDelegate: AnyObject {
    /// All three are called on the engine's capture queue.
    func cameraEngine(_ engine: CameraEngine, didOutputVideo sampleBuffer: CMSampleBuffer)
    func cameraEngine(_ engine: CameraEngine, didOutputAudio sampleBuffer: CMSampleBuffer)
    func cameraEngineDidDropVideoFrame(_ engine: CameraEngine)
}

/// Owns the camera: picks the lens set and the 4K60 format, delivers frames,
/// and moves the zoom.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let captureQueue = DispatchQueue(label: "rugbycam.capture", qos: .userInitiated)
    weak var delegate: CameraEngineDelegate?

    private let sessionQueue = DispatchQueue(label: "rugbycam.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let stateLock = NSLock()
    private var lockedDevice: AVCaptureDevice?
    private var lockedInfo = CameraInfo()
    private var observers: [NSObjectProtocol] = []

    private struct DevicePick {
        var device: AVCaptureDevice
        var format: AVCaptureDevice.Format
        var quality: CaptureQuality
    }

    override init() {
        super.init()
        // If the camera stops with an error (for example after a phone call), start it again.
        let name = Notification.Name("AVCaptureSessionRuntimeErrorNotification")
        let token = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
            self?.start()
        }
        observers.append(token)
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Shared state

    private var device: AVCaptureDevice? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return lockedDevice
        }
        set {
            stateLock.lock()
            lockedDevice = newValue
            stateLock.unlock()
        }
    }

    private(set) var info: CameraInfo {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return lockedInfo
        }
        set {
            stateLock.lock()
            lockedInfo = newValue
            stateLock.unlock()
        }
    }

    /// The zoom factor the camera is at right now (it changes during a glide).
    var currentZoom: Double {
        guard let device = device else { return 1.0 }
        return Double(device.videoZoomFactor)
    }

    // MARK: - Set-up

    func configure(quality: CaptureQuality, stabilise: Bool, completion: @escaping (Result<CameraInfo, Error>) -> Void) {
        sessionQueue.async {
            do {
                let info = try self.configureSession(requested: quality, stabilise: stabilise)
                completion(.success(info))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func start() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession(requested: CaptureQuality, stabilise: Bool) throws -> CameraInfo {
        guard let pick = CameraEngine.pickDevice(for: requested) else {
            throw CameraError.noCamera
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        let input = try AVCaptureDeviceInput(device: pick.device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        try pick.device.lockForConfiguration()
        pick.device.activeFormat = pick.format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(pick.quality.fps))
        pick.device.activeVideoMinFrameDuration = frameDuration
        pick.device.activeVideoMaxFrameDuration = frameDuration
        if pick.device.isFocusModeSupported(.continuousAutoFocus) {
            pick.device.focusMode = .continuousAutoFocus
        }
        if pick.device.isExposureModeSupported(.continuousAutoExposure) {
            pick.device.exposureMode = .continuousAutoExposure
        }
        if pick.device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            pick.device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        pick.device.unlockForConfiguration()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(microphoneInput) {
            session.addInput(microphoneInput)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            // The app is locked to landscape with the charging port on the right,
            // which is the sensor's own orientation, so no rotation is needed.
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilise ? .standard : .off
            }
        }

        let described = CameraEngine.describe(device: pick.device, format: pick.format, quality: pick.quality)
        try pick.device.lockForConfiguration()
        pick.device.videoZoomFactor = CGFloat(described.wideZoom)
        pick.device.unlockForConfiguration()

        device = pick.device
        info = described
        return described
    }

    private static func pickDevice(for requested: CaptureQuality) -> DevicePick? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        var quality: CaptureQuality? = requested
        while let wanted = quality {
            for type in types {
                guard let device = found.first(where: { $0.deviceType == type }) else {
                    continue
                }
                if let format = bestFormat(for: device, quality: wanted) {
                    return DevicePick(device: device, format: format, quality: wanted)
                }
            }
            quality = wanted.fallback
        }
        return nil
    }

    private static func bestFormat(for device: AVCaptureDevice, quality: CaptureQuality) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -1.0
        let wantedFPS = Double(quality.fps)
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(size.width) == quality.width, Int(size.height) == quality.height else {
                continue
            }
            let supportsRate = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= wantedFPS && range.maxFrameRate >= wantedFPS
            }
            guard supportsRate else {
                continue
            }
            // Prefer ordinary 8-bit video, then the widest view.
            var score = Double(format.videoFieldOfView)
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                score += 1000.0
            } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                score += 500.0
            }
            if score > bestScore {
                best = format
                bestScore = score
            }
        }
        return best
    }

    private static func describe(device: AVCaptureDevice, format: AVCaptureDevice.Format, quality: CaptureQuality) -> CameraInfo {
        var info = CameraInfo()
        info.deviceName = device.localizedName
        info.width = quality.width
        info.height = quality.height
        info.fps = quality.fps

        // On a multi-lens camera, zoom factor 1.0 is the first lens. The other
        // lenses start at the "switch-over" factors.
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
        let startsUltraWide = device.constituentDevices.first?.deviceType == .builtInUltraWideCamera
        var wide = 1.0
        if startsUltraWide, let first = switchOvers.first {
            wide = first
        }
        info.wideZoom = wide
        info.displayMultiplier = 1.0 / wide

        let deviceMin = Double(device.minAvailableVideoZoomFactor)
        let deviceMax = min(Double(device.maxAvailableVideoZoomFactor), Double(format.videoMaxZoomFactor))
        info.minZoom = max(deviceMin, 1.0)
        info.maxZoom = max(info.minZoom, min(deviceMax, wide * 15.0))

        var factors: [Double] = [1.0] + switchOvers
        // The main sensor has enough pixels for a sharp 2x crop.
        let crop = wide * 2.0
        let nextLens = factors.filter { $0 > wide + 0.01 }.min()
        if let next = nextLens {
            if crop < next - 0.05 {
                factors.append(crop)
            }
        } else {
            factors.append(crop)
        }
        var stops: [LensStop] = []
        for factor in factors.sorted() where factor >= info.minZoom - 0.001 && factor <= info.maxZoom + 0.001 {
            if let previous = stops.last, abs(previous.factor - factor) < 0.01 {
                continue
            }
            stops.append(LensStop(factor: factor, label: CameraEngine.zoomLabel(factor * info.displayMultiplier)))
        }
        info.lensStops = stops
        return info
    }

    static func zoomLabel(_ displayed: Double) -> String {
        if abs(displayed - displayed.rounded()) < 0.05 {
            return String(Int(displayed.rounded()))
        }
        return String(format: "%.1f", displayed)
    }

    // MARK: - Zoom

    /// Moves the zoom. With a duration it glides there; with zero it jumps.
    func setZoom(_ factor: Double, duration: Double) {
        sessionQueue.async {
            guard let device = self.device else { return }
            let limits = self.info
            let target = CGFloat(min(max(factor, limits.minZoom), limits.maxZoom))
            do {
                try device.lockForConfiguration()
                let current = device.videoZoomFactor
                if duration <= 0.0 || abs(target - current) < 0.001 {
                    if device.isRampingVideoZoom {
                        device.cancelVideoZoomRamp()
                    }
                    device.videoZoomFactor = target
                } else {
                    let doublings = abs(log2(Double(target / current)))
                    let rate = Float(max(0.05, min(16.0, doublings / duration)))
                    device.ramp(toVideoZoomFactor: target, withRate: rate)
                }
                device.unlockForConfiguration()
            } catch {
                // The camera is busy for a moment; the next update tries again.
            }
        }
    }

    // MARK: - Recording settings

    /// Asks the camera which encoder settings suit its current format.
    /// The completion runs on the session queue.
    func recordingSettings(codec: RecordingCodec, completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        sessionQueue.async {
            let codecType: AVVideoCodecType = codec == .hevc ? .hevc : .h264
            var video = self.videoOutput.recommendedVideoSettings(forVideoCodecType: codecType, assetWriterOutputFileType: .mov)
            if video == nil {
                let current = self.info
                video = [
                    AVVideoCodecKey: codecType,
                    AVVideoWidthKey: current.width,
                    AVVideoHeightKey: current.height
                ]
            }
            var audio: [String: Any]?
            if self.audioOutput.connection(with: .audio) != nil {
                audio = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            }
            completion(video, audio)
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            delegate?.cameraEngine(self, didOutputVideo: sampleBuffer)
        } else if output === audioOutput {
            delegate?.cameraEngine(self, didOutputAudio: sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            delegate?.cameraEngineDidDropVideoFrame(self)
        }
    }
}
