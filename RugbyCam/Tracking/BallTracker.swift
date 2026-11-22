import Foundation

struct BallTrackerParams {
    var minConfidence = 0.12      // ignore anything weaker
    var relockConfidence = 0.40   // needed to start a track from nothing
    var strongConfidence = 0.60   // needed to jump to a far-away detection
    var baseRadius = 0.035        // gate radius right after a detection (frame widths)
    var growPerSecond = 0.55      // gate growth while the ball is missing
    var maxRadius = 0.30
    var lostAfter = 0.6           // seconds without a detection before the track is dropped
    var maxPredict = 0.3          // seconds of straight-line prediction
    var maxSpeed = 1.5            // frame widths per second
    var velocityBlend = 0.5
    var confirmHits = 2           // detections in a row before the ball may steer the camera
}

/// Decides which detection, if any, is the ball. A ball cannot jump across the
/// picture between two looks, so far-away detections are rejected unless the
/// model is very sure.
final class BallTracker {
    var params = BallTrackerParams()

    private(set) var last: NPoint?
    private(set) var lastBox: NBox?
    private(set) var velocity = NPoint(x: 0.0, y: 0.0)
    private(set) var lastSeen = -1.0e9
    private(set) var hits = 0

    var isTracking: Bool {
        return last != nil
    }

    var isConfirmed: Bool {
        return last != nil && hits >= params.confirmHits
    }

    func reset() {
        last = nil
        lastBox = nil
        velocity = NPoint(x: 0.0, y: 0.0)
        lastSeen = -1.0e9
        hits = 0
    }

    func timeSinceSeen(_ time: Double) -> Double {
        return time - lastSeen
    }

    func predicted(at time: Double) -> NPoint? {
        guard let from = last else { return nil }
        let dt = Geo.clamp(time - lastSeen, 0.0, params.maxPredict)
        return NPoint(x: Geo.clamp(from.x + velocity.x * dt, 0.0, 1.0),
                      y: Geo.clamp(from.y + velocity.y * dt, 0.0, 1.0))
    }

    func update(_ candidates: [BallObservation], time: Double) -> BallObservation? {
        let p = params
        let usable = candidates
            .filter { $0.confidence >= p.minConfidence }
            .sorted { $0.confidence > $1.confidence }

        var chosen: BallObservation?
        var withinGate = false
        if let from = last {
            let dt = max(time - lastSeen, 0.0)
            let pred = predicted(at: time) ?? from
            let radius = min(p.maxRadius, p.baseRadius + p.growPerSecond * dt)
            for candidate in usable where Geo.frameDistance(candidate.box.center, pred) <= radius {
                chosen = candidate
                withinGate = true
                break
            }
            if chosen == nil {
                for candidate in usable where candidate.confidence >= p.strongConfidence {
                    chosen = candidate
                    break
                }
            }
        } else {
            for candidate in usable where candidate.confidence >= p.relockConfidence {
                chosen = candidate
                break
            }
        }

        if let found = chosen {
            let c = found.box.center
            if let from = last, withinGate {
                let dt = time - lastSeen
                if dt > 1.0e-3 && dt < 1.0 {
                    var vx = (c.x - from.x) / dt
                    var vy = (c.y - from.y) / dt
                    let speed = (vx * vx + vy * vy).squareRoot()
                    if speed > p.maxSpeed {
                        vx *= p.maxSpeed / speed
                        vy *= p.maxSpeed / speed
                    }
                    let b = p.velocityBlend
                    velocity = NPoint(x: velocity.x + (vx - velocity.x) * b,
                                      y: velocity.y + (vy - velocity.y) * b)
                } else {
                    velocity = NPoint(x: 0.0, y: 0.0)
                }
                hits += 1
            } else {
                velocity = NPoint(x: 0.0, y: 0.0)
                hits = 1
            }
            last = c
            lastBox = found.box
            lastSeen = time
        } else if last != nil && (time - lastSeen) > p.lostAfter {
            last = nil
            lastBox = nil
            velocity = NPoint(x: 0.0, y: 0.0)
            hits = 0
        }
        return chosen
    }
}
