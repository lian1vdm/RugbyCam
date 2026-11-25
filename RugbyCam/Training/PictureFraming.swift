import CoreGraphics
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
            if let image = TrainingStore.loadImage(at: imageURL, maxPixels: 1600) {
                players = detectPeople(in: image)
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
        if let action = result.action {
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
