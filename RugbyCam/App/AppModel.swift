import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI
import UIKit

/// Ties the camera, the recorder, the tracking, the mount and the stream
/// together, and holds everything the screen shows.
///
/// Threads: the @Published values change on the main thread only. Frames arrive
/// on the camera's capture queue. Tracking results arrive on the tracking queue.
final class AppModel: ObservableObject, CameraEngineDelegate {
    private static let streamKeyAccount = "streamKey"

    // MARK: - Shown on screen (main thread only)

    @Published var settings = AppSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            settingsChanged(from: oldValue)
        }
    }
    @Published var streamKey = Keychain.get(AppModel.streamKeyAccount) {
        didSet {
            Keychain.set(streamKey, for: AppModel.streamKeyAccount)
        }
    }
    @Published var cameraInfo = CameraInfo()
    @Published var cameraProblem: String?
    @Published var zoom = 1.0
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var followEnabled = false
    @Published var autoZoomEnabled = false
    @Published var mountState = MountState.idle
    @Published var streamState = StreamState.off
    @Published var snapshot = TrackingSnapshot()
    @Published var ballModelStatus = "Looking for a ball model"
    @Published var playerModelStatus = ""
    @Published var hasBallModel = false
    @Published var captureFPS = 0
    @Published var droppedFrames = 0
    @Published var notice: String?
    @Published var mountLog: [String] = []
    @Published var isHot = false

    // MARK: - Parts

    let camera = CameraEngine()
    let training = TrainingStore()
    private lazy var recorder = Recorder(queue: camera.captureQueue)
    private let tracking = TrackingEngine()
    private let mount = MountController()
    private let streamer: LiveStreamer = Streamers.make()

    private var started = false
    private var settingsOpen = false
    private var clock: Timer?
    private var noticeWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    // Used on the capture queue only.
    private var streamWantsFrames = false
    private var frameCount = 0
    private var framesSinceRate = 0
    private var lastRateTime = 0.0
    private var cameraDrops = 0
    private var lastPublishedZoom = 0.0

    init() {
        camera.delegate = self
        tracking.trainingStore = training
        recorder.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.recordingBroke(error)
            }
        }
        mount.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.mountState = state
                self?.pushTrackingConfig()
            }
        }
        mount.onLog = { [weak self] line in
            DispatchQueue.main.async {
                self?.addMountLog(line)
            }
        }
        streamer.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.streamChanged(state)
            }
        }
        tracking.onResult = { [weak self] snapshot, command in
            self?.apply(snapshot, command)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enteredBackground()
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeCamera()
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateHeat()
        })
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Start-up

    /// Called once when the main screen appears.
    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        updateHeat()
        reloadModels()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard allowed else {
                DispatchQueue.main.async {
                    self?.cameraProblem = "RugbyCam needs the camera. Allow it in Settings > RugbyCam, then open the app again."
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self?.configureCamera()
                }
            }
        }
        if MountController.rememberedName != nil {
            mount.connect()
        }
    }

    private func configureCamera() {
        cameraProblem = nil
        let wanted = settings.quality
        camera.configure(quality: wanted, stabilise: settings.stabilisation) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let info):
                    self.cameraInfo = info
                    self.zoom = info.wideZoom
                    if info.width != wanted.width || info.fps != wanted.fps {
                        self.show("This camera does not offer \(wanted.label), so it is using \(info.width)x\(info.height) at \(info.fps) fps.")
                    }
                    self.pushTrackingConfig()
                    self.resumeCamera()
                case .failure(let error):
                    self.cameraProblem = error.localizedDescription
                }
            }
        }
    }

    func reloadModels() {
        ballModelStatus = "Loading"
        tracking.loadModels { [weak self] report in
            DispatchQueue.main.async {
                self?.ballModelStatus = report.ball
                self?.playerModelStatus = report.players
                self?.hasBallModel = report.hasBallModel
            }
        }
    }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        if old.quality != settings.quality || old.stabilisation != settings.stabilisation {
            if isRecording {
                show("The new video setting applies when this recording ends.")
            } else {
                configureCamera()
            }
        }
        pushTrackingConfig()
    }

    /// Hands the tracking its instructions. Call after anything it depends on changed.
    private func pushTrackingConfig() {
        let info = cameraInfo
        var config = TrackingConfig()
        config.follow = followEnabled
        config.mountReady = mountState.canMove
        config.autoZoom = autoZoomEnabled
        config.enabled = info.width > 0 && (followEnabled || autoZoomEnabled || settings.showOverlay)
        config.lensStepsOnly = settings.lensStepsOnly

        let multiplier = max(info.displayMultiplier, 0.01)
        let low = min(max(settings.autoZoomMinDisplay / multiplier, info.minZoom), info.maxZoom)
        let high = min(max(settings.autoZoomMaxDisplay / multiplier, low), info.maxZoom)
        config.zoomMin = low
        config.zoomMax = max(high, low)
        config.wideZoom = info.wideZoom
        config.lensStops = info.lensStops
            .map { $0.factor }
            .filter { $0 >= low - 0.001 && $0 <= high + 0.001 }

        config.minInterval = 1.0 / max(settings.detectionRate, 1.0)
        config.ballConfidence = settings.ballConfidence
        config.searchZoom = settings.searchZoom
        config.followSpeed = settings.followSpeed
        config.zoomTightness = settings.zoomTightness
        config.tiltEnabled = settings.tiltEnabled
        config.invertPan = settings.invertPan
        config.invertTilt = settings.invertTilt
        config.collectTraining = settings.saveHardFrames && isRecording
        tracking.config = config
        if !config.enabled {
            snapshot = TrackingSnapshot()
        }
    }

    // MARK: - Tracking switches

    func setFollow(_ on: Bool) {
        followEnabled = on
        if on && !mountState.canMove {
            if mountState.isLinked {
                show("The mount is linked, but its move commands are not known yet, so it will not turn. Auto zoom still works.")
            } else {
                show("No mount is linked, so the camera will not turn. Auto zoom still works.")
            }
        }
        if !on {
            mount.stopMotion()
        }
        if !followEnabled && !autoZoomEnabled {
            tracking.reset()
        }
        pushTrackingConfig()
    }

    func setAutoZoom(_ on: Bool) {
        autoZoomEnabled = on
        if !followEnabled && !autoZoomEnabled {
            tracking.reset()
        }
        pushTrackingConfig()
    }

    // MARK: - Zoom by hand

    /// Zoom chosen by the user. Touching the zoom switches auto zoom off.
    func userZoom(to factor: Double, glide: Bool) {
        if autoZoomEnabled {
            autoZoomEnabled = false
            pushTrackingConfig()
        }
        let clamped = min(max(factor, cameraInfo.minZoom), cameraInfo.maxZoom)
        zoom = clamped
        camera.setZoom(clamped, duration: glide ? 0.3 : 0.0)
    }

    /// The zoom as a slider position 0...1 (each step of the slider is the same zoom ratio).
    var zoomSliderPosition: Double {
        let low = cameraInfo.minZoom
        let high = cameraInfo.maxZoom
        guard high > low, zoom > 0.0 else { return 0.0 }
        return min(max(log(zoom / low) / log(high / low), 0.0), 1.0)
    }

    func setZoomSliderPosition(_ position: Double) {
        let low = cameraInfo.minZoom
        let high = cameraInfo.maxZoom
        guard high > low else { return }
        userZoom(to: low * pow(high / low, min(max(position, 0.0), 1.0)), glide: false)
    }

    var zoomText: String {
        return String(format: "%.1fx", zoom * cameraInfo.displayMultiplier)
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard cameraInfo.width > 0 else { return }
        if let free = RecordingStore.freeGigabytes(), free < 3.0 {
            show(String(format: "Only %.1f GB of storage is free. 4K 60 uses about 0.4 GB per minute.", free))
        }
        let url = RecordingStore.newFileURL()
        let queue = camera.captureQueue
        camera.recordingSettings(codec: settings.codec) { [weak self] video, audio in
            guard let self = self else { return }
            guard let video = video else {
                DispatchQueue.main.async {
                    self.show("The camera did not offer recording settings.")
                }
                return
            }
            queue.async {
                do {
                    try self.recorder.start(url: url, videoSettings: video, audioSettings: audio)
                    DispatchQueue.main.async {
                        self.isRecording = true
                        self.recordingSeconds = 0
                        self.startClock()
                        self.pushTrackingConfig()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.show("Recording could not start: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func stopRecording() {
        camera.captureQueue.async {
            self.recorder.stop { result in
                DispatchQueue.main.async {
                    self.recordingEnded()
                    switch result {
                    case .success(let url):
                        self.keep(url)
                    case .failure(let error):
                        self.show("The recording was not saved: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func recordingBroke(_ error: Error) {
        recordingEnded()
        show("Recording stopped: \(error.localizedDescription). The part recorded so far is in the Files app under RugbyCam > Recordings.")
    }

    private func recordingEnded() {
        isRecording = false
        pauseCameraIfIdle()
        pushTrackingConfig()
        clock?.invalidate()
        clock = nil
        // A video setting changed during the recording: apply it now.
        if cameraInfo.width != settings.quality.width || cameraInfo.fps != settings.quality.fps {
            configureCamera()
        }
    }

    private func keep(_ url: URL) {
        guard settings.saveToPhotos else {
            show("Saved in the Files app under RugbyCam > Recordings.")
            return
        }
        RecordingStore.moveToPhotos(url) { [weak self] success, problem in
            DispatchQueue.main.async {
                if success {
                    self?.show("Saved to Photos.")
                } else {
                    self?.show(problem ?? "Could not save to Photos. The video is in the Files app under RugbyCam > Recordings.")
                }
            }
        }
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingSeconds += 1
        }
    }

    var recordingTimeText: String {
        let hours = recordingSeconds / 3600
        let minutes = (recordingSeconds % 3600) / 60
        let seconds = recordingSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Streaming

    var streamingAvailable: Bool {
        return streamer.isAvailable
    }

    func toggleStream() {
        if streamState != .off {
            streamer.stop()
            return
        }
        guard streamer.isAvailable else {
            show("This build has no streaming library. Build the RugbyCam project instead of RugbyCam-Lite.")
            return
        }
        let address = settings.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = address.lowercased()
        guard lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://") else {
            show("The stream address must start with rtmp:// or rtmps://. Set it in Settings.")
            return
        }
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            show("Enter the stream key in Settings first.")
            return
        }
        guard cameraInfo.width > 0 else { return }

        // Never stream bigger or faster than the camera delivers.
        var width = settings.streamResolution.width
        var height = settings.streamResolution.height
        if width > cameraInfo.width {
            width = cameraInfo.width
            height = cameraInfo.height
        }
        let cameraRate = Double(max(cameraInfo.fps, 1))
        let streamRate = Double(max(settings.streamFPS, 1))
        let keepEvery = max(1, Int((cameraRate / streamRate).rounded()))
        let config = StreamConfig(url: address,
                                  key: key,
                                  width: width,
                                  height: height,
                                  keepEveryNthFrame: keepEvery,
                                  frameRate: cameraRate / Double(keepEvery),
                                  videoBitrate: Int(settings.streamBitrateMbps * 1_000_000.0),
                                  audioBitrate: settings.streamAudioKbps * 1000)
        streamer.start(config)
    }

    private func streamChanged(_ state: StreamState) {
        streamState = state
        let wantsFrames = state.wantsFrames
        camera.captureQueue.async {
            self.streamWantsFrames = wantsFrames
        }
        if case .failed(let reason) = state {
            show("Stream failed: \(reason)")
        }
        if !state.wantsFrames {
            pauseCameraIfIdle()
        }
    }

    // MARK: - Camera while the settings are open

    /// The settings cover the camera picture, so the camera is switched off to
    /// save the battery, unless it is recording or streaming.
    func settingsOpened() {
        settingsOpen = true
        pauseCameraIfIdle()
    }

    func settingsClosed() {
        settingsOpen = false
        resumeCamera()
    }

    private var cameraIdle: Bool {
        return !isRecording && !streamState.wantsFrames
    }

    private func pauseCameraIfIdle() {
        guard settingsOpen, cameraIdle else { return }
        camera.stop()
        mount.stopMotion()
    }

    private func resumeCamera() {
        guard cameraInfo.width > 0 else { return }
        if settingsOpen && cameraIdle {
            return
        }
        camera.start()
    }

    // MARK: - Mount

    func connectMount() {
        mount.connect()
    }

    func disconnectMount() {
        mount.disconnect()
    }

    func forgetMount() {
        mount.forget()
        show("The mount was forgotten. The next search links to the nearest XbotGo mount.")
    }

    private func addMountLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        mountLog.append("\(formatter.string(from: Date()))  \(line)")
        if mountLog.count > 200 {
            mountLog.removeFirst(mountLog.count - 200)
        }
    }

    // MARK: - Frames (capture queue)

    func cameraEngine(_ engine: CameraEngine, didOutputVideo sampleBuffer: CMSampleBuffer) {
        recorder.appendVideo(sampleBuffer)
        if streamWantsFrames {
            streamer.appendVideo(sampleBuffer)
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let zoomNow = engine.currentZoom
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            tracking.offer(pixelBuffer, time: time, zoom: zoomNow, captureQueue: engine.captureQueue)
        }

        frameCount += 1
        framesSinceRate += 1
        if frameCount % 6 == 0 && abs(zoomNow - lastPublishedZoom) > 0.004 * zoomNow {
            lastPublishedZoom = zoomNow
            DispatchQueue.main.async {
                self.zoom = zoomNow
            }
        }
        if lastRateTime <= 0.0 {
            lastRateTime = time
            framesSinceRate = 0
        } else if time - lastRateTime >= 1.0 {
            let rate = Int((Double(framesSinceRate) / (time - lastRateTime)).rounded())
            let dropped = cameraDrops + recorder.droppedFrames
            lastRateTime = time
            framesSinceRate = 0
            DispatchQueue.main.async {
                self.captureFPS = rate
                self.droppedFrames = dropped
            }
        }
    }

    func cameraEngine(_ engine: CameraEngine, didOutputAudio sampleBuffer: CMSampleBuffer) {
        recorder.appendAudio(sampleBuffer)
        if streamWantsFrames {
            streamer.appendAudio(sampleBuffer)
        }
    }

    func cameraEngineDidDropVideoFrame(_ engine: CameraEngine) {
        cameraDrops += 1
    }

    // MARK: - Tracking results (tracking queue)

    private func apply(_ snapshot: TrackingSnapshot, _ command: TrackingCommand) {
        if let target = command.zoomTarget {
            camera.setZoom(target, duration: command.zoomDuration)
        }
        mount.setVelocity(pan: command.panRate, tilt: command.tiltRate)
        DispatchQueue.main.async {
            self.snapshot = snapshot
        }
    }

    // MARK: - Odds and ends

    private func enteredBackground() {
        // iOS stops the camera when the app is not on screen, so close the file properly.
        if isRecording {
            stopRecording()
        }
        mount.stopMotion()
    }

    private func updateHeat() {
        let state = ProcessInfo.processInfo.thermalState
        isHot = state == .serious || state == .critical
    }

    /// Shows a short message at the bottom of the screen for a few seconds.
    func show(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.notice = nil
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: work)
    }

    var freeSpaceText: String {
        guard let free = RecordingStore.freeGigabytes() else { return "" }
        return String(format: "%.0f GB free", free)
    }

    /// One line that says what the tracking is doing.
    var trackingText: String {
        if !(followEnabled || autoZoomEnabled || settings.showOverlay) {
            return "Tracking off"
        }
        if let problem = snapshot.problem {
            return problem
        }
        var parts: [String] = []
        switch snapshot.state {
        case .ball: parts.append("Following the ball")
        case .ballHeld: parts.append("Ball hidden, holding")
        case .players: parts.append(hasBallModel ? "Following the players" : "Following the players (no ball model)")
        case .searching: parts.append("Nothing in view")
        }
        if snapshot.looksPerSecond > 0.0 {
            parts.append(String(format: "%.0f ms, %.0f looks/s", snapshot.lookMilliseconds, snapshot.looksPerSecond))
        }
        return parts.joined(separator: " · ")
    }
}
