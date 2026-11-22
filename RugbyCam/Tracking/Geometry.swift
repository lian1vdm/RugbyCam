import CoreGraphics
import Foundation

// Pure maths shared by the tracker and the director.
// This file, BallTracker.swift and Director.swift are a line-for-line port of
// reference/tracking_logic.py, which is the version that was run in simulation.

/// A point in normalised image coordinates: x 0...1 left to right, y 0...1 top to bottom.
struct NPoint: Equatable {
    var x: Double
    var y: Double
}

/// A rectangle in normalised image coordinates. (x, y) is the top-left corner.
struct NBox: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let full = NBox(x: 0.0, y: 0.0, w: 1.0, h: 1.0)

    var minX: Double { x }
    var maxX: Double { x + w }
    var minY: Double { y }
    var maxY: Double { y + h }
    var center: NPoint { NPoint(x: x + w / 2.0, y: y + h / 2.0) }

    func union(_ other: NBox) -> NBox {
        let x0 = Swift.min(minX, other.minX)
        let y0 = Swift.min(minY, other.minY)
        let x1 = Swift.max(maxX, other.maxX)
        let y1 = Swift.max(maxY, other.maxY)
        return NBox(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    func including(_ point: NPoint) -> NBox {
        return union(NBox(x: point.x, y: point.y, w: 0.0, h: 0.0))
    }
}

enum Geo {
    static let frameHeightOverWidth = 9.0 / 16.0

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        return Swift.max(lower, Swift.min(upper, value))
    }

    /// Distance in frame widths (y is scaled so that a circle stays a circle).
    static func frameDistance(_ a: NPoint, _ b: NPoint) -> Double {
        let dx = a.x - b.x
        let dy = (a.y - b.y) * frameHeightOverWidth
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// One possible ball, as reported by the ball model.
struct BallObservation: Equatable {
    var box: NBox
    var confidence: Double
}
