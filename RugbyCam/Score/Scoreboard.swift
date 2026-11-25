import CoreImage
import CoreVideo
import Foundation
import UIKit

/// The match score. Saved between launches.
struct ScoreState: Codable, Equatable {
    var home = "Home"
    var away = "Away"
    var homeScore = 0
    var awayScore = 0
    var period = 1               // 1 = first half, 2 = second half
    var showInVideo = false      // draw the scoreboard into the recording and the stream

    private static let storageKey = "score.v1"

    static func load() -> ScoreState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(ScoreState.self, from: data) else {
            return ScoreState()
        }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ScoreState.storageKey)
        }
    }

    var periodText: String {
        return period == 2 ? "2nd half" : "1st half"
    }

    static func cleanName(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        return String(trimmed.prefix(16))
    }
}

/// Draws the scoreboard into the top-left corner of every video frame, before
/// the frame goes to the recording and the live stream.
///
/// The picture of the scoreboard is made on the main thread only when something
/// changes (a score, a name, the clock every second). Each frame then only
/// copies that small picture into the frame, which is cheap.
final class ScoreOverlay {
    private let lock = NSLock()
    private var image: CIImage?
    private var rect = CGRect.zero
    private var frameWidth = 0
    private var frameHeight = 0
    private var failed = false
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Main thread. `width` and `height` are the camera frame size.
    func update(score: ScoreState, clock: String, width: Int, height: Int) {
        guard score.showInVideo, width > 0, height > 0 else {
            lock.lock()
            image = nil
            lock.unlock()
            return
        }
        let unit = CGFloat(width) / 1920.0
        let picture = ScoreOverlay.render(score: score, clock: clock, unit: unit)
        guard let cgImage = picture.cgImage else { return }
        let margin = (36.0 * unit).rounded()
        // Even positions keep the colour (chroma) samples of the video lined up.
        let x = (margin / 2.0).rounded() * 2.0
        let y = ((CGFloat(height) - CGFloat(cgImage.height) - margin) / 2.0).rounded() * 2.0
        let placed = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: x, y: y))
        lock.lock()
        image = placed
        rect = placed.extent
        frameWidth = width
        frameHeight = height
        lock.unlock()
    }

    /// Capture queue. Copies the scoreboard into the frame.
    func draw(on pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let current = image
        let area = rect
        let width = frameWidth
        let height = frameHeight
        let broken = failed
        lock.unlock()
        guard let overlay = current, !broken,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else { return }
        let destination = CIRenderDestination(pixelBuffer: pixelBuffer)
        do {
            let task = try context.startTask(toRender: overlay, from: area, to: destination, at: area.origin)
            _ = try task.waitUntilCompleted()
        } catch {
            // Never risk the recording for the scoreboard: stop drawing it.
            lock.lock()
            failed = true
            lock.unlock()
        }
    }

    /// The scoreboard picture. `unit` is 1 for a 1920 wide video, 2 for 4K.
    private static func render(score: ScoreState, clock: String, unit u: CGFloat) -> UIImage {
        let nameWidth = 250.0 * u
        let scoreWidth = 76.0 * u
        let clockWidth = 170.0 * u
        let stripe = 8.0 * u
        let height = (68.0 * u / 2.0).rounded() * 2.0
        let width = ((stripe + nameWidth * 2.0 + scoreWidth * 2.0 + clockWidth) / 2.0).rounded() * 2.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let dark = UIColor(red: 0.05, green: 0.09, blue: 0.07, alpha: 1.0)
        let darker = UIColor(red: 0.02, green: 0.05, blue: 0.04, alpha: 1.0)
        let gold = UIColor(red: 0.96, green: 0.71, blue: 0.13, alpha: 1.0)
        let green = UIColor(red: 0.18, green: 0.70, blue: 0.42, alpha: 1.0)

        return renderer.image { context in
            dark.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            gold.setFill()
            context.fill(CGRect(x: 0, y: 0, width: stripe, height: height))

            var x = stripe
            draw(score.home, in: CGRect(x: x, y: 0, width: nameWidth, height: height),
                 size: 27 * u, weight: .bold, color: .white, align: .right, inset: 14 * u)
            x += nameWidth
            gold.setFill()
            context.fill(CGRect(x: x, y: 0, width: scoreWidth, height: height))
            draw("\(score.homeScore)", in: CGRect(x: x, y: 0, width: scoreWidth, height: height),
                 size: 36 * u, weight: .heavy, color: .black, align: .center, inset: 0)
            x += scoreWidth
            green.setFill()
            context.fill(CGRect(x: x, y: 0, width: scoreWidth, height: height))
            draw("\(score.awayScore)", in: CGRect(x: x, y: 0, width: scoreWidth, height: height),
                 size: 36 * u, weight: .heavy, color: .black, align: .center, inset: 0)
            x += scoreWidth
            draw(score.away, in: CGRect(x: x, y: 0, width: nameWidth, height: height),
                 size: 27 * u, weight: .bold, color: .white, align: .left, inset: 14 * u)
            x += nameWidth
            darker.setFill()
            context.fill(CGRect(x: x, y: 0, width: clockWidth, height: height))
            draw(clock, in: CGRect(x: x, y: 4 * u, width: clockWidth, height: height * 0.62),
                 size: 30 * u, weight: .bold, color: .white, align: .center, inset: 0, monospaced: true)
            draw(score.periodText.uppercased(), in: CGRect(x: x, y: height * 0.62, width: clockWidth, height: height * 0.38),
                 size: 14 * u, weight: .semibold, color: gold, align: .center, inset: 0)
        }
    }

    private static func draw(_ text: String, in box: CGRect, size: CGFloat, weight: UIFont.Weight,
                             color: UIColor, align: NSTextAlignment, inset: CGFloat, monospaced: Bool = false) {
        let font = monospaced
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let lineHeight = font.lineHeight
        let area = CGRect(x: box.minX + inset, y: box.midY - lineHeight / 2.0,
                          width: box.width - inset * 2.0, height: lineHeight)
        (text as NSString).draw(in: area, withAttributes: attributes)
    }
}
