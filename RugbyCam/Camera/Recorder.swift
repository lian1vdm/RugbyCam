import AVFoundation
import Foundation
import Photos

enum RecorderError: LocalizedError {
    case cannotAddInput
    case cannotStart
    case notRecording
    case noFrames
    case failed

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: return "The video encoder refused these settings."
        case .cannotStart: return "The file could not be opened for writing."
        case .notRecording: return "No recording was running."
        case .noFrames: return "The recording was stopped before any picture arrived."
        case .failed: return "The recording could not be finished."
        }
    }
}

/// Writes the camera's frames to a movie file.
/// Every method must be called on the capture queue.
final class Recorder {
    enum State {
        case idle
        case starting       // waiting for the first picture
        case recording
        case finishing
    }

    private(set) var state = State.idle
    private(set) var droppedFrames = 0

    /// Called on the capture queue if writing breaks in the middle (disk full, and so on).
    var onFailure: ((Error) -> Void)?

    private let queue: DispatchQueue
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startTime = CMTime.invalid

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var isActive: Bool {
        return state == .starting || state == .recording
    }

    func start(url: URL, videoSettings: [String: Any], audioSettings: [String: Any]?) throws {
        guard state == .idle else { return }
        let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Close the file in pieces, so a crash or an empty battery does not lose the whole match.
        newWriter.movieFragmentInterval = CMTime(seconds: 10.0, preferredTimescale: 600)

        // Settings the writer cannot use make iOS throw an exception that closes
        // the app, so check them first and fall back to plain H.264.
        var usableVideo = videoSettings
        if !newWriter.canApply(outputSettings: usableVideo, forMediaType: .video) {
            usableVideo = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoSettings[AVVideoWidthKey] ?? 1920,
                AVVideoHeightKey: videoSettings[AVVideoHeightKey] ?? 1080
            ]
            guard newWriter.canApply(outputSettings: usableVideo, forMediaType: .video) else {
                throw RecorderError.cannotAddInput
            }
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: usableVideo)
        video.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(video) else {
            throw RecorderError.cannotAddInput
        }
        newWriter.add(video)

        var audio: AVAssetWriterInput?
        if let settings = audioSettings, newWriter.canApply(outputSettings: settings, forMediaType: .audio) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if newWriter.canAdd(input) {
                newWriter.add(input)
                audio = input
            }
        }

        guard newWriter.startWriting() else {
            throw newWriter.error ?? RecorderError.cannotStart
        }
        writer = newWriter
        videoInput = video
        audioInput = audio
        startTime = CMTime.invalid
        droppedFrames = 0
        state = .starting
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isActive, let writer = writer, let input = videoInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if state == .starting {
            writer.startSession(atSourceTime: time)
            startTime = time
            state = .recording
        }
        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                fail(writer.error ?? RecorderError.failed)
            }
        } else {
            droppedFrames += 1
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, let writer = writer, let input = audioInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(time, startTime) >= 0 else { return }
        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                fail(writer.error ?? RecorderError.failed)
            }
        }
    }

    /// Finishes the file. The completion runs on the capture queue.
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isActive, let writer = writer else {
            completion(.failure(RecorderError.notRecording))
            return
        }
        if state == .starting {
            writer.cancelWriting()
            clear()
            completion(.failure(RecorderError.noFrames))
            return
        }
        state = .finishing
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let url = writer.outputURL
        writer.finishWriting { [weak self] in
            let result: Result<URL, Error>
            if writer.status == .completed {
                result = .success(url)
            } else {
                result = .failure(writer.error ?? RecorderError.failed)
            }
            guard let self = self else {
                completion(result)
                return
            }
            self.queue.async {
                self.clear()
                completion(result)
            }
        }
    }

    private func fail(_ error: Error) {
        writer?.cancelWriting()
        clear()
        onFailure?(error)
    }

    private func clear() {
        writer = nil
        videoInput = nil
        audioInput = nil
        startTime = CMTime.invalid
        state = .idle
    }
}

/// Where recordings are kept, and how they get into the Photos library.
enum RecordingStore {
    static func newFileURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return folder.appendingPathComponent("Match_\(formatter.string(from: Date())).mov")
    }

    /// Free space on the phone in gigabytes, or nil if it cannot be read.
    static func freeGigabytes() -> Double? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return Double(bytes) / 1_000_000_000.0
    }

    /// Moves a finished recording into the Photos library (no second copy is kept).
    static func moveToPhotos(_ url: URL, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "Photos access was refused, so the video stays in the Files app under RugbyCam.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }, completionHandler: { success, error in
                completion(success, error?.localizedDescription)
            })
        }
    }
}
