import Foundation

// The same picture coordinates as in RugbyCam on the iPhone:
// x 0...1 left to right, y 0...1 top to bottom, (x, y) is the top-left corner.

struct NPoint: Equatable {
    var x: Double
    var y: Double
}

struct NBox: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var minX: Double { x }
    var maxX: Double { x + w }
    var minY: Double { y }
    var maxY: Double { y + h }
    var center: NPoint { NPoint(x: x + w / 2.0, y: y + h / 2.0) }

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// From the [x, y, w, h] arrays the iPhone sends.
    init?(_ values: [Double]?) {
        guard let v = values, v.count == 4 else { return nil }
        self.init(x: v[0], y: v[1], w: v[2], h: v[3])
    }

    init?(any value: Any?) {
        guard let list = value as? [Any] else { return nil }
        let numbers = list.compactMap { ($0 as? NSNumber)?.doubleValue }
        self.init(numbers)
    }

    func contains(_ point: NPoint) -> Bool {
        return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    var queryItems: [URLQueryItem] {
        return [URLQueryItem(name: "x", value: String(x)), URLQueryItem(name: "y", value: String(y)),
                URLQueryItem(name: "w", value: String(w)), URLQueryItem(name: "h", value: String(h))]
    }
}

enum Geo {
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        return Swift.max(lower, Swift.min(upper, value))
    }
}

/// The game situations, with the same names as on the iPhone.
enum PlaySituation: String, CaseIterable, Identifiable {
    case open
    case pile
    case lineout
    case kick
    case breakaway
    case lost

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

    static let choosable: [PlaySituation] = [.open, .pile, .lineout, .kick, .breakaway]
}
