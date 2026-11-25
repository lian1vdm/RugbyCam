import Foundation

/// What is happening in the game right now, as far as the tracking can tell.
enum PlaySituation: String, Codable, CaseIterable, Identifiable {
    case open           // open play
    case pile           // scrum, ruck or maul: players packed together and hardly moving
    case lineout        // players standing in a line, hardly moving
    case kick           // the ball goes up fast
    case breakaway      // line break or fast run: the ball moves fast sideways
    case lost           // ball and players not found

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "Open play"
        case .pile: return "Scrum / ruck / maul"
        case .lineout: return "Lineout"
        case .kick: return "Kick"
        case .breakaway: return "Line break"
        case .lost: return "Ball lost"
        }
    }

    /// The situations a person can pick when showing the framing.
    static let choosable: [PlaySituation] = [.open, .pile, .lineout, .kick, .breakaway]
}

/// The numbers the situation is guessed from. Saved with every framing example,
/// so a real model can be trained from them later.
struct FramingFeatures: Codable, Equatable {
    var players = 0
    var spread = 0.0              // width of the group, in player heights
    var compactShare = 0.0        // share of players packed around the densest spot
    var lineRatio = 1.0           // how much the players form a line (1 = round blob)
    var groupSpeed = 0.0          // frame widths per second
    var ballSeen = false
    var ballSpeedX = 0.0          // frame widths per second, + = right
    var ballSpeedY = 0.0          // frame heights per second, + = down
    var zoom = 1.0                // shown zoom (0.5x, 1x, ...)
}

/// How the person likes one situation framed, learned from their examples.
struct LearnedFrame: Codable, Equatable {
    var fill = 0.5                // share of the frame the action should take
    var offsetX = 0.0             // where the action sits: + = more room on the right
    var count = 0                 // examples so far

    /// How much the learned value counts compared with the built-in rule.
    var weight: Double {
        return min(0.85, Double(count) / 6.0)
    }
}

/// Maths shared by the live tracking and the training pictures.
enum FramingMath {
    static let heightOverWidth = 9.0 / 16.0

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// The densest group: the player with the most neighbours and those neighbours.
    /// Returns the share of all players in that group and the group's box.
    static func compactCluster(_ players: [NBox]) -> (share: Double, box: NBox?) {
        guard players.count >= 2 else {
            return (players.isEmpty ? 0.0 : 1.0, players.first)
        }
        let height = median(players.map { $0.h }) * heightOverWidth   // in frame widths
        let radius = max(height * 2.0, 0.02)
        var bestIndex = 0
        var bestCount = -1
        for (index, player) in players.enumerated() {
            var count = 0
            for other in players where Geo.frameDistance(player.center, other.center) <= radius {
                count += 1
            }
            if count > bestCount {
                bestCount = count
                bestIndex = index
            }
        }
        let centre = players[bestIndex].center
        var box: NBox?
        var members = 0
        for other in players where Geo.frameDistance(centre, other.center) <= radius {
            box = box.map { $0.union(other) } ?? other
            members += 1
        }
        return (Double(members) / Double(players.count), box)
    }

    /// 1 for a round group, large when the players stand in a line.
    static func lineRatio(_ players: [NBox]) -> Double {
        guard players.count >= 3 else { return 1.0 }
        let points = players.map { ($0.center.x, $0.center.y * heightOverWidth) }
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + $1.0 } / n
        let my = points.reduce(0.0) { $0 + $1.1 } / n
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for (x, y) in points {
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
            sxy += (x - mx) * (y - my)
        }
        sxx /= n
        syy /= n
        sxy /= n
        let trace = sxx + syy
        let det = sxx * syy - sxy * sxy
        let root = max(trace * trace / 4.0 - det, 0.0).squareRoot()
        let big = trace / 2.0 + root
        let small = max(trace / 2.0 - root, 1.0e-6)
        return min((big / small).squareRoot(), 50.0)
    }

    /// Width of the group in player heights.
    static func spread(_ players: [NBox]) -> Double {
        guard let first = players.first else { return 0.0 }
        let box = players.dropFirst().reduce(first) { $0.union($1) }
        let height = max(median(players.map { $0.h }) * heightOverWidth, 1.0e-3)
        return box.w / height
    }

    /// Players without the outermost ones on each side (stragglers, the full-back).
    static func trimmed(_ players: [NBox]) -> [NBox] {
        guard players.count >= 5 else { return players }
        let drop = max(1, players.count / 10)
        let byX = players.sorted { $0.center.x < $1.center.x }
        return Array(byX[drop..<(byX.count - drop)])
    }

    /// Guess from one still picture (no movement known): pile, lineout or open play.
    static func stillSituation(_ players: [NBox]) -> PlaySituation {
        guard players.count >= 6 else { return .open }
        let cluster = compactCluster(players)
        if cluster.share >= 0.5 {
            return .pile
        }
        if lineRatio(players) >= 3.0 {
            return .lineout
        }
        return .open
    }

    /// The part of the picture that should be in the frame.
    static func actionBox(players: [NBox], ball: NBox?, situation: PlaySituation) -> NBox? {
        var box: NBox?
        if situation == .pile, let cluster = compactCluster(players).box {
            box = cluster
        } else {
            let kept = trimmed(players)
            if let first = kept.first {
                box = kept.dropFirst().reduce(first) { $0.union($1) }
            }
        }
        if let ball = ball {
            box = box.map { $0.union(ball) } ?? ball
        }
        return box
    }

    /// The share of the frame the action should take, by the built-in rules.
    static func ruleFill(_ situation: PlaySituation, tightness: Double) -> Double {
        switch situation {
        case .open, .lost: return tightness
        case .pile: return 0.42
        case .lineout: return 0.60
        case .kick: return 0.30
        case .breakaway: return 0.40
        }
    }

    /// The frame (same shape as the picture, so w == h in picture units) that
    /// shows `action` taking `fill` of it, moved by `offsetX`, kept inside the picture.
    static func frame(around action: NBox, fill: Double, offsetX: Double) -> NBox {
        let f = Geo.clamp(fill, 0.1, 0.98)
        var size = max(action.w / f, action.h / f, 0.05)
        size = min(size, 1.0)
        let centre = action.center
        let x = Geo.clamp(centre.x + offsetX * size - size / 2.0, 0.0, 1.0 - size)
        let y = Geo.clamp(centre.y - size / 2.0, 0.0, 1.0 - size)
        return NBox(x: x, y: y, w: size, h: size)
    }

    /// What one example of a person's framing teaches: the fill and the offset.
    static func lesson(action: NBox, chosen frame: NBox) -> (fill: Double, offsetX: Double)? {
        guard frame.w > 0.01, frame.h > 0.01, action.w > 0.0 || action.h > 0.0 else { return nil }
        let fill = Geo.clamp(max(action.w / frame.w, action.h / frame.h), 0.1, 0.98)
        let offset = Geo.clamp((frame.center.x - action.center.x) / frame.w, -0.35, 0.35)
        return (fill, offset)
    }
}

/// A person's framing, saved to teach the zoom.
struct FramingExample: Codable {
    var created: Date
    var source: String            // "match" (box drawn while filming) or "picture" (training picture)
    var pictureID: String?        // the training picture, if any
    var situation: PlaySituation
    var detectedSituation: PlaySituation
    var players: [NBox]
    var ball: NBox?
    var action: NBox?
    var appFrame: NBox?           // what the app would have shown
    var chosenFrame: NBox         // what the person drew
    var features: FramingFeatures
}
