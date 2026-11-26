import CoreImage
import CoreVideo
import Foundation

/// What the tracking should do right now. Built on the main thread from the
/// settings and handed over as a whole.
struct TrackingConfig {
    var enabled = false           // look at frames at all
    var follow = false            // turn the mount
    var mountReady = false        // the mount is linked and its commands are known
    var autoZoom = false
    var lensStepsOnly = false
    var zoomMin = 1.0             // camera zoom factors
    var zoomMax = 1.0
    var wideZoom = 1.0
    var lensStops: [Double] = []
    var minInterval = 1.0 / 12.0  // seconds between two looks
    var ballConfidence = 0.12
    var searchZoom = 2.0
    var followSpeed = 1.0
    var zoomTightness = 0.55
    var tiltEnabled = true
    var invertPan = false
    var invertTilt = false
    var collectTraining = false   // save pictures where the ball is lost (while recording)
    var situationsEnabled = true  // frame scrums, lineouts, kicks and breaks in their own way
    var learnedFraming: [String: LearnedFrame] = [:]
    var displayMultiplier = 1.0
}

/// What the tracking saw in the latest frame, for the overlay and the status line.
struct TrackingSnapshot {
    var ball: NBox?
    var ballConfirmed = false
    var players: [NBox] = []
    var actionBox: NBox?
    var lookAt: NPoint?
    var searchArea: NBox?
    var state = DirectorState.searching
    var situation = PlaySituation.lost
    var features = FramingFeatures()
    var frame: NBox?              // the framing the zoom is heading for
    var lookMilliseconds = 0.0
    var looksPerSecond = 0.0
    var problem: String?
}

/// What the camera and the mount should do next.
struct TrackingCommand {
    var panRate = 0.0
    var tiltRate = 0.0
    var zoomTarget: Double?
    var zoomDuration = 0.1
}

struct ModelReport {
    var ball: String
    var players: String
    var hasBallModel: Bool
}

/// Runs the detectors on camera frames and turns what they see into commands.
final class TrackingEngine {
    /// Where pictures of lost-ball moments go. Set once at start-up.
    var trainingStore: TrainingStore?

    /// Called on the tracking queue after every look.
    var onResult: ((TrackingSnapshot, TrackingCommand) -> Void)?

    private let queue = DispatchQueue(label: "rugbycam.tracking", qos: .userInitiated)
    private let configLock = NSLock()
    private var lockedConfig = TrackingConfig()

    // Used on the capture queue only.
    private var busy = false
    private var lastLookStart = -1.0e9

    // Used on the tracking queue only.
    private var ballDetector: ObjectDetector?
    private var playerDetector: ObjectDetector?
    private let humanDetector = HumanDetector()
    private let tracker = BallTracker()
    private let director = Director()
    private let stepper = LensStepper()
    private var stepperStops: [Double] = []
    private var stepperActive = false
    private var areaMisses = 0
    private var lookIndex = 0
    private var cachedPlayers: [NBox] = []
    private var cachedPlayersTime = -1.0e9
    private var lastLookTime = -1.0e9
    private var looksPerSecond = 0.0
    private var problem: String?

    var config: TrackingConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return lockedConfig
        }
        set {
            configLock.lock()
            lockedConfig = newValue
            configLock.unlock()
        }
    }

    // MARK: - Models

    /// The player boxes of a ball + player model, without unsure ones.
    static func players(in found: [DetectedObject]) -> [NBox] {
        return found.filter { $0.label.lowercased() == "player" && $0.confidence >= 0.30 }.map { $0.box }
    }

    /// Finds and loads the model files. The completion runs on the tracking queue.
    func loadModels(completion: @escaping (ModelReport) -> Void) {
        queue.async {
            var report = ModelReport(ball: "", players: "", hasBallModel: false)
            self.ballDetector = nil
            self.playerDetector = nil
            do {
                if let model = try ModelStore.find(names: ModelStore.ballNames) {
                    let detector = try ObjectDetector(model: model, confidenceThreshold: 0.05, overlapThreshold: 0.45)
                    self.ballDetector = detector
                    report.ball = "\(model.sourceName), \(detector.inputWidth)x\(detector.inputHeight)"
                    report.hasBallModel = true
                } else {
                    report.ball = "No ball model yet. Copy BallDetector.mlpackage into Files > On My iPhone > RugbyCam."
                }
            } catch {
                report.ball = "Ball model could not be loaded: \(error.localizedDescription)"
            }
            do {
                if let model = try ModelStore.find(names: ModelStore.playerNames) {
                    let detector = try ObjectDetector(model: model, confidenceThreshold: 0.25, overlapThreshold: 0.45)
                    self.playerDetector = detector
                    report.players = "\(model.sourceName), \(detector.inputWidth)x\(detector.inputHeight)"
                } else if self.ballDetector?.findsPlayers == true {
                    report.players = "Your ball model also finds the players (ball + player model)."
                } else {
                    report.players = "Using the people detector built into iOS (it misses far-away players). Train a ball + player model to fix this."
                }
            } catch {
                report.players = "Player model could not be loaded (\(error.localizedDescription)). Using the built-in people detector."
            }
            self.problem = nil
            completion(report)
        }
    }

    /// Forgets the ball and the framing, for example after tracking was switched off.
    func reset() {
        queue.async {
            self.tracker.reset()
            self.director.reset()
            self.stepperActive = false
            self.areaMisses = 0
            self.cachedPlayers = []
        }
    }

    // MARK: - Frames

    /// Offers a frame. Call on the capture queue. Most frames are skipped: the
    /// engine only takes one when it is free and the interval has passed.
    func offer(_ pixelBuffer: CVPixelBuffer, time: Double, zoom: Double, captureQueue: DispatchQueue) {
        let current = config
        guard current.enabled, !busy, time - lastLookStart >= current.minInterval else {
            return
        }
        busy = true
        lastLookStart = time
        queue.async {
            self.look(at: pixelBuffer, time: time, zoom: zoom, config: current)
            captureQueue.async {
                self.busy = false
            }
        }
    }

    private func look(at pixelBuffer: CVPixelBuffer, time: Double, zoom: Double, config: TrackingConfig) {
        let started = ProcessInfo.processInfo.systemUptime
        var snapshot = TrackingSnapshot()

        // ---- Ball ----
        var candidates: [BallObservation] = []
        var usedSmallArea = false
        var playersFromBallLook: [NBox]?
        if let detector = ballDetector {
            var area = NBox.full
            if tracker.isTracking, areaMisses < 2, config.searchZoom > 1.01,
               let centre = tracker.predicted(at: time) {
                area = TrackingEngine.searchArea(around: centre, zoom: config.searchZoom, aspect: detector.aspect)
                usedSmallArea = true
            }
            do {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let found = try detector.detect(in: image, area: area)
                candidates = found
                    .filter { $0.label.lowercased() != "player" }
                    .map { BallObservation(box: $0.box, confidence: $0.confidence) }
                if detector.findsPlayers && !usedSmallArea {
                    playersFromBallLook = TrackingEngine.players(in: found)
                }
                snapshot.searchArea = area
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
        tracker.params.minConfidence = config.ballConfidence
        let chosen = tracker.update(candidates, time: time)
        if chosen != nil {
            areaMisses = 0
        } else if usedSmallArea {
            areaMisses += 1
        }

        // ---- Players (every second look is enough) ----
        lookIndex += 1
        if lookIndex % 2 == 1 || (time - cachedPlayersTime) > 0.4 {
            do {
                if let detector = playerDetector {
                    let image = CIImage(cvPixelBuffer: pixelBuffer)
                    let found = try detector.detect(in: image, area: NBox.full)
                    cachedPlayers = found.filter { !$0.label.lowercased().contains("ball") }.map { $0.box }
                } else if let fromBall = playersFromBallLook {
                    // The ball model looked at the whole picture and found the players too.
                    cachedPlayers = fromBall
                } else if let detector = ballDetector, detector.findsPlayers {
                    let image = CIImage(cvPixelBuffer: pixelBuffer)
                    cachedPlayers = TrackingEngine.players(in: try detector.detect(in: image, area: NBox.full))
                } else {
                    cachedPlayers = try humanDetector.detect(in: pixelBuffer)
                }
                cachedPlayersTime = time
            } catch {
                cachedPlayers = []
            }
        }
        let players = (time - cachedPlayersTime) <= 0.5 ? cachedPlayers : []

        // ---- Training pictures: players in view, but no ball ----
        if config.collectTraining, ballDetector != nil, !tracker.isTracking, players.count >= 3,
           let store = trainingStore {
            let best = candidates.max { $0.confidence < $1.confidence }
            store.offerLiveFrame(pixelBuffer, time: time, guess: best?.box, confidence: best?.confidence ?? 0.0)
        }

        // ---- Decide ----
        director.params.panGain = 2.2 * config.followSpeed
        director.params.fillX = config.zoomTightness
        director.params.fillY = min(0.9, config.zoomTightness + 0.05)
        director.params.tiltEnabled = config.tiltEnabled
        director.params.situationsEnabled = config.situationsEnabled
        let mountActive = config.follow && config.mountReady
        let ballPoint = tracker.isConfirmed ? tracker.predicted(at: time) : nil
        let input = DirectorInput(time: time,
                                  ball: ballPoint,
                                  ballAge: tracker.timeSinceSeen(time),
                                  players: players,
                                  zoom: zoom,
                                  zoomMin: config.zoomMin,
                                  zoomMax: max(config.zoomMax, config.zoomMin),
                                  wideZoom: config.wideZoom,
                                  mountActive: mountActive,
                                  autoZoom: config.autoZoom,
                                  ballVelocity: tracker.isConfirmed ? tracker.velocity : nil,
                                  learned: config.learnedFraming,
                                  displayMultiplier: config.displayMultiplier)
        let output = director.update(input)

        var command = TrackingCommand()
        if mountActive {
            command.panRate = config.invertPan ? -output.panRate : output.panRate
            command.tiltRate = config.invertTilt ? -output.tiltRate : output.tiltRate
        }
        if config.autoZoom {
            var target = output.zoomTarget
            if config.lensStepsOnly && !config.lensStops.isEmpty {
                if !stepperActive || stepperStops != config.lensStops {
                    stepper.setStops(config.lensStops, current: zoom)
                    stepperStops = config.lensStops
                    stepperActive = true
                }
                target = stepper.step(target)
                command.zoomDuration = 0.5
            } else {
                stepperActive = false
                command.zoomDuration = max(0.05, config.minInterval * 1.5)
            }
            command.zoomTarget = target
        } else {
            stepperActive = false
        }

        // ---- Report ----
        if lastLookTime > 0.0, time > lastLookTime {
            let rate = 1.0 / (time - lastLookTime)
            looksPerSecond = looksPerSecond <= 0.0 ? rate : looksPerSecond + (rate - looksPerSecond) * 0.2
        }
        lastLookTime = time
        snapshot.ball = tracker.isTracking ? tracker.lastBox : nil
        snapshot.ballConfirmed = tracker.isConfirmed
        snapshot.players = players
        snapshot.actionBox = output.actionBox
        snapshot.lookAt = output.lookAt
        snapshot.state = output.state
        snapshot.situation = output.situation
        snapshot.features = output.features
        snapshot.frame = output.frame
        snapshot.lookMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000.0
        snapshot.looksPerSecond = looksPerSecond
        snapshot.problem = problem
        onResult?(snapshot, command)
    }

    /// A part of the picture around `centre`, with the model's own shape, so the
    /// ball takes up more of the model's input than in the whole picture.
    static func searchArea(around centre: NPoint, zoom: Double, aspect: Double) -> NBox {
        var w = 1.0 / max(zoom, 1.0)
        var h = w * (16.0 / 9.0) / max(aspect, 0.1)
        if h > 1.0 {
            w /= h
            h = 1.0
        }
        let x = Geo.clamp(centre.x - w / 2.0, 0.0, 1.0 - w)
        let y = Geo.clamp(centre.y - h / 2.0, 0.0, 1.0 - h)
        return NBox(x: x, y: y, w: w, h: h)
    }
}
