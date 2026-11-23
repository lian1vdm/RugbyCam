import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Goes through an imported video, lets the ball model look at it, and keeps
/// the pictures that are most worth checking: the ones where the model is
/// unsure, and some where it found nothing.
final class VideoScanner {
    struct Progress {
        var fraction: Double
        var text: String
    }

    private struct Look {
        var time: CMTime
        var box: NBox?
        var confidence: Double
    }

    private let queue = DispatchQueue(label: "rugbycam.videoscan", qos: .userInitiated)
    private var cancelled = false
    private let lock = NSLock()

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// - Parameters:
    ///   - every: seconds between two looks
    ///   - keep: at most this many pictures are kept for checking
    /// Progress and completion are called on the main thread. The completion
    /// gets the number of pictures kept.
    func scan(video url: URL, every: Double, keep: Int, store: TrainingStore,
              progress: @escaping (Progress) -> Void,
              completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async {
            let result: Result<Int, Error>
            do {
                result = .success(try self.run(url: url, every: every, keep: keep, store: store, progress: progress))
            } catch {
                result = .failure(error)
            }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func run(url: URL, every: Double, keep: Int, store: TrainingStore,
                     progress: @escaping (Progress) -> Void) throws -> Int {
        guard let model = try ModelStore.find(names: ModelStore.ballNames) else {
            throw TrainingError.noBallModel
        }
        let detector = try ObjectDetector(model: model, confidenceThreshold: 0.05, overlapThreshold: 0.45)

        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else {
            throw TrainingError.unreadableVideo
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: min(0.2, every / 2.0), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // ---- Pass 1: let the model look at the whole video ----
        var looks: [Look] = []
        let steps = max(1, Int(duration / every))
        for step in 0..<steps {
            if isCancelled { return 0 }
            let time = CMTime(seconds: Double(step) * every, preferredTimescale: 600)
            var actual = CMTime.zero
            guard let frame = try? generator.copyCGImage(at: time, actualTime: &actual) else {
                continue
            }
            let found = (try? detector.detect(in: CIImage(cgImage: frame), area: NBox.full)) ?? []
            let best = found.max { $0.confidence < $1.confidence }
            looks.append(Look(time: actual, box: best?.box, confidence: best?.confidence ?? 0.0))
            if step % 5 == 0 {
                let fraction = 0.8 * Double(step + 1) / Double(steps)
                let text = "Looking at the video: \(Int(Double(step) * every / 60.0)) of \(Int(duration / 60.0) + 1) min"
                DispatchQueue.main.async {
                    progress(Progress(fraction: fraction, text: text))
                }
            }
        }
        if looks.isEmpty {
            throw TrainingError.unreadableVideo
        }

        // ---- Choose the pictures worth checking ----
        // 60 % unsure guesses, 25 % nothing found, 15 % sure guesses (to confirm them).
        let unsure = looks.filter { $0.confidence >= 0.08 && $0.confidence < 0.55 }
            .sorted { abs($0.confidence - 0.3) < abs($1.confidence - 0.3) }
        let nothing = looks.filter { $0.confidence < 0.08 }
        let sure = looks.filter { $0.confidence >= 0.55 }
        var chosen: [Look] = []
        chosen += VideoScanner.spread(unsure, count: Int(Double(keep) * 0.60))
        chosen += VideoScanner.spread(nothing, count: Int(Double(keep) * 0.25))
        chosen += VideoScanner.spread(sure, count: keep - chosen.count)
        // Fill up with whatever is left if one group was small.
        if chosen.count < keep {
            let taken = Set(chosen.map { $0.time.seconds })
            let rest = looks.filter { !taken.contains($0.time.seconds) }
            chosen += VideoScanner.spread(rest, count: keep - chosen.count)
        }
        chosen.sort { $0.time.seconds < $1.time.seconds }

        // ---- Pass 2: save the chosen pictures at full size ----
        let exact = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = exact
        generator.requestedTimeToleranceAfter = exact
        var saved = 0
        for (index, look) in chosen.enumerated() {
            if isCancelled { break }
            guard let frame = try? generator.copyCGImage(at: look.time, actualTime: nil),
                  let jpeg = UIImage(cgImage: frame).jpegData(compressionQuality: 0.88) else {
                continue
            }
            store.add(jpeg: jpeg, source: "video", guess: look.box, confidence: look.confidence)
            saved += 1
            let fraction = 0.8 + 0.2 * Double(index + 1) / Double(chosen.count)
            let text = "Saving pictures: \(index + 1) of \(chosen.count)"
            DispatchQueue.main.async {
                progress(Progress(fraction: fraction, text: text))
            }
        }
        return saved
    }

    /// Picks `count` items spread evenly over the list (keeps its order).
    private static func spread(_ items: [Look], count: Int) -> [Look] {
        guard count > 0, !items.isEmpty else { return [] }
        if items.count <= count { return items }
        var picked: [Look] = []
        let stride = Double(items.count) / Double(count)
        for k in 0..<count {
            picked.append(items[Int(Double(k) * stride)])
        }
        return picked
    }
}
