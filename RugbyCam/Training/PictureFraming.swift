import CoreGraphics
import CoreImage
import Foundation
import Vision

/// What the app sees in one training picture, for the framing question.
struct PictureFraming {
    var players: [NBox] = []
    var situation = PlaySituation.open
    var action: NBox?
    var appFrame: NBox?
    var features = FramingFeatures()
}

enum PictureFramer {
    /// Finds the people in a picture and works out how the app would frame it.
    /// Runs in the background; the completion runs on the main thread.
    static func analyze(imageURL: URL, ball: NBox?, tightness: Double,
                        learned: [String: LearnedFrame],
                        completion: @escaping (PictureFraming) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var players: [NBox] = []
            if let image = TrainingStore.loadImage(at: imageURL, maxPixels: 1920) {
                players = findPlayers(in: image)
            }
            let situation = FramingMath.stillSituation(players)
            let result = frame(players: players, ball: ball, situation: situation,
                               tightness: tightness, learned: learned)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// The app's framing for a chosen situation (when the person picks another one).
    static func frame(players: [NBox], ball: NBox?, situation: PlaySituation,
                      tightness: Double, learned: [String: LearnedFrame]) -> PictureFraming {
        var result = PictureFraming()
        result.players = players
        result.situation = situation
        result.action = FramingMath.actionBox(players: players, ball: ball, situation: situation)
        var fill = FramingMath.ruleFill(situation, tightness: tightness)
        var offset = 0.0
        if let memory = learned[situation.rawValue], memory.count > 0 {
            fill = fill * (1.0 - memory.weight) + memory.fill * memory.weight
            offset = memory.offsetX * memory.weight
        }
        if players.count < 2 {
            // Without players there is no real framing to suggest: show a half-wide frame.
            if let centre = ball?.center ?? result.action?.center {
                let size = 0.5
                result.appFrame = NBox(x: Geo.clamp(centre.x - size / 2, 0, 1 - size),
                                       y: Geo.clamp(centre.y - size / 2, 0, 1 - size), w: size, h: size)
            }
        } else if let action = result.action {
            result.appFrame = FramingMath.frame(around: action, fill: fill, offsetX: offset)
        }
        var features = FramingFeatures()
        features.players = players.count
        let cluster = FramingMath.compactCluster(players)
        features.compactShare = cluster.share
        features.lineRatio = FramingMath.lineRatio(players)
        features.spread = FramingMath.spread(players)
        features.ballSeen = ball != nil
        result.features = features
        return result
    }

    // The ball model, when it also knows players. Only used on `modelQueue`.
    private static let modelQueue = DispatchQueue(label: "rugbycam.pictureframer")
    private static var model: ObjectDetector?
    private static var modelLoaded = false

    /// Forget the loaded model, for example after a new model file was copied in.
    static func reloadModel() {
        modelQueue.async {
            model = nil
            modelLoaded = false
        }
    }

    /// Players from the ball + player model when there is one, otherwise from iOS.
    static func findPlayers(in image: CGImage) -> [NBox] {
        return modelQueue.sync { () -> [NBox] in
            if !modelLoaded {
                modelLoaded = true
                // A separate player model first, else the ball model if it also knows players.
                if let playerModel = (try? ModelStore.find(names: ModelStore.playerNames)) ?? nil,
                   let detector = try? ObjectDetector(model: playerModel, confidenceThreshold: 0.2, overlapThreshold: 0.45) {
                    model = detector
                } else if let ballModel = (try? ModelStore.find(names: ModelStore.ballNames)) ?? nil,
                          let detector = try? ObjectDetector(model: ballModel, confidenceThreshold: 0.2, overlapThreshold: 0.45),
                          detector.findsPlayers {
                    model = detector
                }
            }
            if let detector = model {
                let picture = CIImage(cgImage: image)
                if let found = try? detector.detect(in: picture, area: NBox.full) {
                    let players = found.filter { $0.label.lowercased() != "ball" && $0.confidence >= 0.30 }.map { $0.box }
                    return players
                }
            }
            return detectPeople(in: image)
        }
    }

    static func detectPeople(in image: CGImage) -> [NBox] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map { observation in
            let rect = observation.boundingBox
            return NBox(x: Double(rect.minX), y: 1.0 - Double(rect.maxY),
                        w: Double(rect.width), h: Double(rect.height))
        }
    }
}
