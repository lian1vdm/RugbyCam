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
    var backupActive = false      // a second, wide camera records the backup
    var backupWidth = 0
    var backupHeight = 0
    var backupFPS = 0
    var backupNote: String?       // why the backup is not possible, if it was asked for
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
    /// Frames of the wide backup camera (only while the backup is on).
    func cameraEngine(_ engine: CameraEngine, didOutputBackupVideo sampleBuffer: CMSampleBuffer)
}

/// Owns the camera: picks the lens set and the 4K60 format, delivers frames,
/// and moves the zoom.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// The session in use: the normal one, or the two-camera one for the backup.
    private(set) var session: AVCaptureSession
    private let normalSession = AVCaptureSession()
    private var multiSession: AVCaptureMultiCamSession?
    private let backupOutput = AVCaptureVideoDataOutput()
    private var backupConnection: AVCaptureConnection?
    private var mainVideoPort: AVCaptureInput.Port?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
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
        session = normalSession
        super.init()
        // If the camera stops with an error (for example after a phone call), start it again.
        let name = Notification.Name("AVCaptureSessionRuntimeErrorNotification")
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
            guard note.object is AVCaptureSession else { return }
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

    func configure(quality: CaptureQuality, stabilise: Bool, backup: Bool = false,
                   completion: @escaping (Result<CameraInfo, Error>) -> Void) {
        sessionQueue.async {
            let wasRunning = self.session.isRunning
            if wasRunning {
                self.session.stopRunning()
            }
            do {
                var info: CameraInfo
                if backup, let multi = self.configureMulti(requested: quality, stabilise: stabilise) {
                    info = multi
                } else {
                    info = try self.configureSession(requested: quality, stabilise: stabilise)
                    if backup {
                        info.backupNote = AVCaptureMultiCamSession.isMultiCamSupported
                            ? "This phone cannot film with two cameras at this quality, so there is no backup."
                            : "This phone cannot film with two cameras at once, so there is no backup."
                    }
                }
                self.info = info
                self.connectPreview()
                if wasRunning {
                    self.session.startRunning()
                }
                completion(.success(info))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// The screen's preview. Call once from the view.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = normalSession
        sessionQueue.async {
            self.connectPreview()
        }
    }

    /// Shows the current session on the preview. Session queue.
    private func connectPreview() {
        guard let layer = previewLayer else { return }
        if let multi = multiSession, session === multi {
            DispatchQueue.main.sync {
                layer.setSessionWithNoConnection(multi)
            }
            guard let port = mainVideoPort else { return }
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            multi.beginConfiguration()
            if multi.canAddConnection(connection) {
                multi.addConnection(connection)
            }
            multi.commitConfiguration()
        } else {
            let normal = normalSession
            DispatchQueue.main.sync {
                if layer.session !== normal {
                    layer.session = normal
                }
            }
        }
    }

    /// Pauses or resumes the backup camera's pictures (for example when the phone is hot).
    func setBackupEnabled(_ on: Bool) {
        sessionQueue.async {
            self.backupConnection?.isEnabled = on
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
        clearMulti()
        self.session = normalSession
        let session = normalSession

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

    private static func bestFormat(for device: AVCaptureDevice, quality: CaptureQuality,
                                   multiCam: Bool = false) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -1.0
        let wantedFPS = Double(quality.fps)
        for format in device.formats where !multiCam || format.isMultiCamSupported {
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

    // MARK: - Two cameras (main + wide backup)

    /// Removes everything from the two-camera session. Session queue.
    private func clearMulti() {
        backupConnection = nil
        mainVideoPort = nil
        guard let multi = multiSession else { return }
        if multi.isRunning {
            multi.stopRunning()
        }
        multi.beginConfiguration()
        for connection in multi.connections {
            multi.removeConnection(connection)
        }
        for input in multi.inputs {
            multi.removeInput(input)
        }
        for output in multi.outputs {
            multi.removeOutput(output)
        }
        multi.commitConfiguration()
    }

    /// Removes everything from the normal session, so its cameras are free. Session queue.
    private func clearNormal() {
        let normal = normalSession
        if normal.isRunning {
            normal.stopRunning()
        }
        normal.beginConfiguration()
        for input in normal.inputs {
            normal.removeInput(input)
        }
        for output in normal.outputs {
            normal.removeOutput(output)
        }
        normal.commitConfiguration()
    }

    /// Main camera (wide and tele lenses) plus the ultra-wide lens for the backup.
    /// Returns nil when the phone cannot do it; then the normal session is used.
    private func configureMulti(requested: CaptureQuality, stabilise: Bool) -> CameraInfo? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInDualCamera, .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        let sets = discovery.supportedMultiCamDeviceSets
        guard let ultra = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) else {
            return nil
        }
        var main: AVCaptureDevice?
        for type in [AVCaptureDevice.DeviceType.builtInDualCamera, .builtInWideAngleCamera] {
            if let candidate = discovery.devices.first(where: { $0.deviceType == type }),
               sets.contains(where: { $0.contains(candidate) && $0.contains(ultra) }) {
                main = candidate
                break
            }
        }
        guard let mainDevice = main else { return nil }
        clearNormal()
        var quality: CaptureQuality? = requested
        while let wanted = quality {
            if let info = tryMulti(main: mainDevice, ultra: ultra, quality: wanted, stabilise: stabilise) {
                return info
            }
            quality = wanted.fallback
        }
        clearMulti()
        return nil
    }

    private static func backupFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -1.0e9
        for format in device.formats where format.isMultiCamSupported {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = Int(size.width)
            let height = Int(size.height)
            guard width >= 1280, width <= 1920, width * 9 == height * 16 else { continue }
            let thirty = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            guard thirty else { continue }
            var score = Double(width)
            if CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                score += 10000.0
            }
            if score > bestScore {
                best = format
                bestScore = score
            }
        }
        return best
    }

    private func tryMulti(main: AVCaptureDevice, ultra: AVCaptureDevice, quality: CaptureQuality,
                          stabilise: Bool) -> CameraInfo? {
        guard let mainFormat = CameraEngine.bestFormat(for: main, quality: quality, multiCam: true),
              let ultraFormat = CameraEngine.backupFormat(for: ultra) else {
            return nil
        }
        clearMulti()
        let multi = multiSession ?? AVCaptureMultiCamSession()
        multiSession = multi

        multi.beginConfiguration()
        var ok = true
        var mainPort: AVCaptureInput.Port?
        var backup: AVCaptureConnection?
        do {
            let mainInput = try AVCaptureDeviceInput(device: main)
            let ultraInput = try AVCaptureDeviceInput(device: ultra)
            if multi.canAddInput(mainInput) && multi.canAddInput(ultraInput) {
                multi.addInputWithNoConnections(mainInput)
                multi.addInputWithNoConnections(ultraInput)
            } else {
                ok = false
            }

            if ok {
                try main.lockForConfiguration()
                main.activeFormat = mainFormat
                let frame = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
                main.activeVideoMinFrameDuration = frame
                main.activeVideoMaxFrameDuration = frame
                if main.isFocusModeSupported(.continuousAutoFocus) {
                    main.focusMode = .continuousAutoFocus
                }
                if main.isExposureModeSupported(.continuousAutoExposure) {
                    main.exposureMode = .continuousAutoExposure
                }
                main.unlockForConfiguration()

                try ultra.lockForConfiguration()
                ultra.activeFormat = ultraFormat
                let thirty = CMTime(value: 1, timescale: 30)
                ultra.activeVideoMinFrameDuration = thirty
                ultra.activeVideoMaxFrameDuration = thirty
                if ultra.isFocusModeSupported(.continuousAutoFocus) {
                    ultra.focusMode = .continuousAutoFocus
                }
                if ultra.isExposureModeSupported(.continuousAutoExposure) {
                    ultra.exposureMode = .continuousAutoExposure
                }
                ultra.unlockForConfiguration()

                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = false
                videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
                backupOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                ]
                backupOutput.alwaysDiscardsLateVideoFrames = true
                backupOutput.setSampleBufferDelegate(self, queue: captureQueue)
                if multi.canAddOutput(videoOutput) && multi.canAddOutput(backupOutput) {
                    multi.addOutputWithNoConnections(videoOutput)
                    multi.addOutputWithNoConnections(backupOutput)
                } else {
                    ok = false
                }

                mainPort = mainInput.ports(for: .video, sourceDeviceType: main.deviceType,
                                           sourceDevicePosition: main.position).first
                let ultraPort = ultraInput.ports(for: .video, sourceDeviceType: ultra.deviceType,
                                                 sourceDevicePosition: ultra.position).first
                if ok, let port = mainPort, let wide = ultraPort {
                    let mainConnection = AVCaptureConnection(inputPorts: [port], output: videoOutput)
                    let backupConnectionNew = AVCaptureConnection(inputPorts: [wide], output: backupOutput)
                    if multi.canAddConnection(mainConnection) && multi.canAddConnection(backupConnectionNew) {
                        multi.addConnection(mainConnection)
                        multi.addConnection(backupConnectionNew)
                        for connection in [mainConnection, backupConnectionNew] {
                            if connection.isVideoRotationAngleSupported(0) {
                                connection.videoRotationAngle = 0
                            }
                        }
                        if mainConnection.isVideoStabilizationSupported {
                            mainConnection.preferredVideoStabilizationMode = stabilise ? .standard : .off
                        }
                        backup = backupConnectionNew
                    } else {
                        ok = false
                    }
                } else {
                    ok = false
                }

                // Sound for both files.
                if ok, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                   let microphone = AVCaptureDevice.default(for: .audio),
                   let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
                   multi.canAddInput(microphoneInput) {
                    multi.addInputWithNoConnections(microphoneInput)
                    audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
                    if multi.canAddOutput(audioOutput) {
                        multi.addOutputWithNoConnections(audioOutput)
                        if let audioPort = microphoneInput.ports(for: .audio, sourceDeviceType: microphone.deviceType,
                                                                 sourceDevicePosition: microphone.position).first {
                            let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                            if multi.canAddConnection(audioConnection) {
                                multi.addConnection(audioConnection)
                            }
                        }
                    }
                }
            }
        } catch {
            ok = false
        }
        multi.commitConfiguration()

        // More than the camera hardware can do at once: try a lower quality.
        if !ok || multi.hardwareCost > 1.0 {
            clearMulti()
            return nil
        }

        var described = CameraEngine.describe(device: main, format: mainFormat, quality: quality)
        let backupSize = CMVideoFormatDescriptionGetDimensions(ultraFormat.formatDescription)
        described.backupActive = true
        described.backupWidth = Int(backupSize.width)
        described.backupHeight = Int(backupSize.height)
        described.backupFPS = 30
        do {
            try main.lockForConfiguration()
            main.videoZoomFactor = CGFloat(described.wideZoom)
            main.unlockForConfiguration()
        } catch {
            // The zoom starts wherever it is.
        }
        device = main
        backupConnection = backup
        mainVideoPort = mainPort
        session = multi
        return described
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
            let wanted: AVVideoCodecType = codec == .hevc ? .hevc : .h264
            // Asking for a codec the output does not list makes iOS throw an
            // exception that closes the app, so only ask for listed ones.
            let available = self.videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
            var video: [String: Any]?
            if available.contains(wanted) {
                video = self.videoOutput.recommendedVideoSettings(forVideoCodecType: wanted, assetWriterOutputFileType: .mov)
            }
            if video == nil {
                // Build the settings by hand.
                let current = self.info
                let fps = max(current.fps, 1)
                let pixelsPerSecond = Double(current.width * current.height * fps)
                // About 0.09 bits per pixel for HEVC, 0.14 for H.264 (4K 60: roughly 45 / 70 Mbit/s).
                let bitsPerPixel = wanted == .hevc ? 0.09 : 0.14
                video = [
                    AVVideoCodecKey: wanted,
                    AVVideoWidthKey: current.width,
                    AVVideoHeightKey: current.height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(pixelsPerSecond * bitsPerPixel),
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoMaxKeyFrameIntervalKey: fps
                    ] as [String: Any]
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
        } else if output === backupOutput {
            delegate?.cameraEngine(self, didOutputBackupVideo: sampleBuffer)
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
