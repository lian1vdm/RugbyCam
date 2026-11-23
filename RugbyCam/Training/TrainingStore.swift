import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit

/// What the user decided for one training picture.
enum TrainingLabel: Codable, Equatable {
    case ball(NBox)               // the ball is here
    case noBall                   // there is no ball in this picture
}

/// One picture waiting to be checked, or already checked.
struct TrainingItem: Codable, Identifiable, Equatable {
    var id: String                // file name without extension
    var source: String            // "video" or "match"
    var created: Date
    var guess: NBox?              // the model's best guess, if it had one
    var guessConfidence: Double
    var label: TrainingLabel?     // nil = not checked yet
    var exported = false
}

/// Keeps the training pictures in Documents/Training:
///   images/<id>.jpg     the picture
///   labels/<id>.txt     YOLO label, written once the picture is checked
///   items.json          the list below
/// The images/labels layout is the same as the dataset on the PC, so the
/// checked pictures can be added to it without conversion.
final class TrainingStore: ObservableObject {
    @Published private(set) var items: [TrainingItem] = [] {
        didSet {
            let waiting = items.filter { $0.label == nil }.count
            countLock.lock()
            lockedPending = waiting
            countLock.unlock()
        }
    }

    /// How many pictures wait to be checked; safe to read from any thread.
    var pendingCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return lockedPending
    }

    private let countLock = NSLock()
    private var lockedPending = 0

    let folder: URL
    private let queue = DispatchQueue(label: "rugbycam.training")
    private var lastLiveSave = -1.0e9
    private let ciContext = CIContext()

    /// At most this many pictures waiting to be checked (each 4K picture is about 1.5 MB).
    static let maxPending = 600

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Training", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: labelsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listURL),
           let saved = try? JSONDecoder().decode([TrainingItem].self, from: data) {
            // Drop entries whose picture has gone (deleted in the Files app).
            items = saved.filter { FileManager.default.fileExists(atPath: imageURL(for: $0.id).path) }
        }
        // didSet does not run inside init, so count once here.
        lockedPending = items.filter { $0.label == nil }.count
    }

    var imagesFolder: URL { folder.appendingPathComponent("images", isDirectory: true) }
    var labelsFolder: URL { folder.appendingPathComponent("labels", isDirectory: true) }
    private var listURL: URL { folder.appendingPathComponent("items.json") }

    func imageURL(for id: String) -> URL {
        return imagesFolder.appendingPathComponent(id + ".jpg")
    }

    var pending: [TrainingItem] { items.filter { $0.label == nil } }
    var checked: [TrainingItem] { items.filter { $0.label != nil && !$0.exported } }
    var exported: [TrainingItem] { items.filter { $0.exported } }

    // MARK: - Adding pictures (any thread)

    /// Saves a picture to be checked later. Call from any thread.
    func add(jpeg: Data, source: String, guess: NBox?, confidence: Double) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let id = "phone_\(source)_\(formatter.string(from: Date()))_\(Int.random(in: 1000...9999))"
        let url = imageURL(for: id)
        queue.async {
            do {
                try jpeg.write(to: url, options: .atomic)
            } catch {
                return
            }
            let item = TrainingItem(id: id, source: source, created: Date(), guess: guess,
                                    guessConfidence: confidence, label: nil)
            DispatchQueue.main.async {
                self.items.append(item)
                self.save()
            }
        }
    }

    /// Called by the tracking while filming: keeps a picture of a moment where
    /// the players are in view but the ball is not found. At most one every
    /// 4 seconds, and only while fewer than `maxPending` pictures wait.
    func offerLiveFrame(_ pixelBuffer: CVPixelBuffer, time: Double, guess: NBox?, confidence: Double) {
        guard time - lastLiveSave >= 4.0 else { return }
        guard pendingCount < TrainingStore.maxPending else { return }
        lastLiveSave = time
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.88
        ]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(of: image, colorSpace: space, options: options) else {
            return
        }
        add(jpeg: data, source: "match", guess: guess, confidence: confidence)
    }

    // MARK: - Importing a video (main thread)

    @Published private(set) var scanText: String?
    @Published private(set) var scanFraction = 0.0
    @Published var message: String?
    private var scanner: VideoScanner?

    var isScanning: Bool { scanner != nil }

    /// Takes over `url` (a private copy of the video) and deletes it when done.
    func importVideo(_ url: URL, every: Double, keep: Int) {
        guard scanner == nil else {
            try? FileManager.default.removeItem(at: url)
            message = "A video is already being looked at. Wait until it has finished."
            return
        }
        let newScanner = VideoScanner()
        scanner = newScanner
        scanText = "Starting"
        scanFraction = 0.0
        message = nil
        newScanner.scan(video: url, every: every, keep: keep, store: self, progress: { [weak self] step in
            self?.scanFraction = step.fraction
            self?.scanText = step.text
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.scanner = nil
            self.scanText = nil
            switch result {
            case .success(let count):
                self.message = count > 0
                    ? "Added \(count) pictures to check."
                    : "No pictures were added."
            case .failure(let error):
                self.message = error.localizedDescription
            }
        })
    }

    func cancelImport() {
        scanner?.cancel()
    }

    // MARK: - Checking (main thread)

    func setLabel(_ label: TrainingLabel, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].label = label
        items[index].exported = false
        writeLabelFile(label, id: id)
        save()
    }

    /// Throws a picture away (blurry, unsure, not useful).
    func discard(_ id: String) {
        try? FileManager.default.removeItem(at: imageURL(for: id))
        try? FileManager.default.removeItem(at: labelsFolder.appendingPathComponent(id + ".txt"))
        items.removeAll { $0.id == id }
        save()
    }

    /// Deletes every picture that was already sent to the PC.
    func deleteExported() {
        for item in exported {
            try? FileManager.default.removeItem(at: imageURL(for: item.id))
            try? FileManager.default.removeItem(at: labelsFolder.appendingPathComponent(item.id + ".txt"))
        }
        items.removeAll { $0.exported }
        save()
    }

    func deleteAllPending() {
        for item in pending {
            try? FileManager.default.removeItem(at: imageURL(for: item.id))
        }
        items.removeAll { $0.label == nil }
        save()
    }

    private func writeLabelFile(_ label: TrainingLabel, id: String) {
        let url = labelsFolder.appendingPathComponent(id + ".txt")
        var text = ""
        if case .ball(let box) = label {
            // YOLO format: class centre-x centre-y width height, all 0...1.
            let c = box.center
            text = String(format: "0 %.6f %.6f %.6f %.6f\n", c.x, c.y, box.w, box.h)
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func save() {
        let snapshot = items
        let url = listURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Sending to the PC

    /// Packs every checked picture that was not sent yet into one zip file
    /// (images/ and labels/ folders, same layout as the PC dataset).
    /// Runs on a background queue; the completion runs on the main thread.
    func makeExport(completion: @escaping (Result<URL, Error>) -> Void) {
        let toSend = checked
        guard !toSend.isEmpty else {
            completion(.failure(TrainingError.nothingToSend))
            return
        }
        let imagesFolder = self.imagesFolder
        let labelsFolder = self.labelsFolder
        queue.async {
            let result: Result<URL, Error>
            do {
                result = .success(try TrainingStore.packZip(items: toSend, images: imagesFolder, labels: labelsFolder))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Marks the pictures in the zip as sent.
    func markSent(_ ids: [String]) {
        let set = Set(ids)
        for index in items.indices where set.contains(items[index].id) {
            items[index].exported = true
        }
        save()
    }

    private static func packZip(items: [TrainingItem], images: URL, labels: URL) throws -> URL {
        let files = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let name = "RugbyCam-training-\(formatter.string(from: Date()))"
        let staging = files.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? files.removeItem(at: staging)
        let stagingImages = staging.appendingPathComponent("images", isDirectory: true)
        let stagingLabels = staging.appendingPathComponent("labels", isDirectory: true)
        try files.createDirectory(at: stagingImages, withIntermediateDirectories: true)
        try files.createDirectory(at: stagingLabels, withIntermediateDirectories: true)
        for item in items {
            let image = images.appendingPathComponent(item.id + ".jpg")
            let label = labels.appendingPathComponent(item.id + ".txt")
            guard files.fileExists(atPath: image.path), files.fileExists(atPath: label.path) else {
                continue
            }
            // Hard links are instant and take no extra space; copy if that fails.
            let imageTarget = stagingImages.appendingPathComponent(item.id + ".jpg")
            if (try? files.linkItem(at: image, to: imageTarget)) == nil {
                try files.copyItem(at: image, to: imageTarget)
            }
            try files.copyItem(at: label, to: stagingLabels.appendingPathComponent(item.id + ".txt"))
        }
        let list = items.map { $0.id }.joined(separator: "\n")
        try list.write(to: staging.appendingPathComponent("ids.txt"), atomically: true, encoding: .utf8)

        // Asking the file system for a folder "for uploading" makes it hand
        // back a zip of that folder.
        let zipTarget = files.temporaryDirectory.appendingPathComponent(name + ".zip")
        try? files.removeItem(at: zipTarget)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                try files.copyItem(at: zipURL, to: zipTarget)
            } catch {
                copyError = error
            }
        }
        try? files.removeItem(at: staging)
        if let error = coordinatorError {
            throw error
        }
        if let error = copyError {
            throw error
        }
        return zipTarget
    }

    // MARK: - Loading pictures for display

    /// A smaller copy of the picture for the screen (the full 4K picture is large).
    static func loadImage(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum TrainingError: LocalizedError {
    case nothingToSend
    case noBallModel
    case unreadableVideo

    var errorDescription: String? {
        switch self {
        case .nothingToSend: return "There are no checked pictures to send yet."
        case .noBallModel: return "Add your ball model first (Settings > Models). It makes the first guesses."
        case .unreadableVideo: return "This video could not be read."
        }
    }
}
