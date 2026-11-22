import CoreMedia
import Foundation

struct StreamConfig {
    var url: String               // for example rtmp://a.rtmp.youtube.com/live2
    var key: String               // the stream key (YouTube) or stream name (home PC)
    var width: Int
    var height: Int
    var keepEveryNthFrame: Int    // 1 = send every frame, 2 = every second frame (60 -> 30 fps)
    var frameRate: Double         // frames per second that reach the server
    var videoBitrate: Int         // bits per second
    var audioBitrate: Int         // bits per second
}

enum StreamState: Equatable {
    case off
    case connecting
    case live
    case retrying(String)
    case failed(String)

    var label: String {
        switch self {
        case .off: return "Stream off"
        case .connecting: return "Connecting"
        case .live: return "LIVE"
        case .retrying(let reason): return "Reconnecting: \(reason)"
        case .failed(let reason): return "Stream failed: \(reason)"
        }
    }

    /// True while the app should keep handing frames to the streamer.
    var wantsFrames: Bool {
        switch self {
        case .connecting, .live, .retrying: return true
        case .off, .failed: return false
        }
    }
}

/// Sends the camera's picture and sound to a live-stream server.
protocol LiveStreamer: AnyObject {
    /// False when the app was built without the streaming library.
    var isAvailable: Bool { get }
    /// Called on any thread whenever the state changes.
    var onStateChange: ((StreamState) -> Void)? { get set }
    func start(_ config: StreamConfig)
    func stop()
    /// Both may be called on the capture queue, many times a second.
    func appendVideo(_ sampleBuffer: CMSampleBuffer)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
}

/// Used when the app is built without the streaming library (the Lite project).
final class UnavailableStreamer: LiveStreamer {
    let isAvailable = false
    var onStateChange: ((StreamState) -> Void)?

    func start(_ config: StreamConfig) {
        onStateChange?(.failed("this build has no streaming library (use the RugbyCam project, not RugbyCam-Lite)"))
    }

    func stop() {
        onStateChange?(.off)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    }
}

enum Streamers {
    static func make() -> LiveStreamer {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        return HaishinStreamer()
        #else
        return UnavailableStreamer()
        #endif
    }
}
