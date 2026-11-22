// Live streaming through the open-source HaishinKit library (RTMP / RTMPS).
//
// This whole file is skipped when the library is not part of the project
// (the RugbyCam-Lite project), so the rest of the app builds without it.
//
// It was written against HaishinKit 2.2.x. The library changes its interface
// between versions, and this file could not be compiled where it was written.
// If the build stops here, the most likely places are marked "API:" below.

#if canImport(HaishinKit) && canImport(RTMPHaishinKit)

import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

private struct MediaItem: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let isVideo: Bool
}

private enum StreamFailure: Error {
    case disconnected
}

final class HaishinStreamer: LiveStreamer, @unchecked Sendable {
    let isAvailable = true
    var onStateChange: ((StreamState) -> Void)?

    private let lock = NSLock()
    private var continuation: AsyncStream<MediaItem>.Continuation?
    private var runTask: Task<Void, Never>?
    private var keepEvery = 1
    private var frameIndex = 0

    func start(_ config: StreamConfig) {
        stopInternal()

        var feed: AsyncStream<MediaItem>.Continuation?
        // Keep only the newest few frames if the network cannot keep up. Every
        // waiting frame holds one of the camera's own picture buffers, and the
        // camera has only a handful; holding more would make the recording drop frames.
        let items = AsyncStream<MediaItem>(bufferingPolicy: .bufferingNewest(4)) { feed = $0 }

        lock.lock()
        continuation = feed
        keepEvery = max(1, config.keepEveryNthFrame)
        frameIndex = 0
        lock.unlock()

        report(.connecting)
        let reporter: @Sendable (StreamState) -> Void = { [weak self] state in
            self?.report(state)
        }
        let task = Task {
            await HaishinStreamer.run(config: config, items: items, report: reporter)
        }
        lock.lock()
        runTask = task
        lock.unlock()
    }

    func stop() {
        stopInternal()
        report(.off)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        frameIndex += 1
        let keep = frameIndex % keepEvery == 0
        let feed = continuation
        lock.unlock()
        if keep, let feed = feed {
            feed.yield(MediaItem(buffer: sampleBuffer, isVideo: true))
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let feed = continuation
        lock.unlock()
        if let feed = feed {
            feed.yield(MediaItem(buffer: sampleBuffer, isVideo: false))
        }
    }

    private func stopInternal() {
        lock.lock()
        let task = runTask
        let feed = continuation
        runTask = nil
        continuation = nil
        lock.unlock()
        feed?.finish()
        task?.cancel()
    }

    private func report(_ state: StreamState) {
        onStateChange?(state)
    }

    /// Connects, publishes, and reconnects after a drop, until the task is cancelled.
    private static func run(config: StreamConfig,
                            items: AsyncStream<MediaItem>,
                            report: @escaping @Sendable (StreamState) -> Void) async {
        // API: "manual" means the app hands frames over itself (the library does not open the camera).
        let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: false)
        var mixerSettings = await mixer.videoMixerSettings
        mixerSettings.mode = .passthrough
        await mixer.setVideoMixerSettings(mixerSettings)
        await mixer.startRunning()

        // One task hands the frames over in the order they arrived.
        let feeder = Task {
            for await item in items {
                if item.isVideo {
                    await mixer.append(item.buffer)
                } else {
                    await mixer.append(item.buffer, track: 0)
                }
            }
        }

        var attempt = 0
        while !Task.isCancelled {
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection)
            do {
                // API: video and audio encoder settings.
                var video = await stream.videoSettings
                video.videoSize = CGSize(width: config.width, height: config.height)
                video.bitRate = config.videoBitrate
                video.maxKeyFrameIntervalDuration = 2
                video.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
                video.expectedFrameRate = config.frameRate
                try? await stream.setVideoSettings(video)

                var audio = AudioCodecSettings()
                audio.bitRate = config.audioBitrate
                try? await stream.setAudioSettings(audio)

                await mixer.addOutput(stream)
                // API: connect to the server address, then publish under the stream key.
                _ = try await connection.connect(config.url)
                _ = try await stream.publish(config.key)
                attempt = 0
                report(.live)

                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    // API: "connected" tells whether the link to the server is still up.
                    let stillConnected = await connection.connected
                    if !stillConnected {
                        throw StreamFailure.disconnected
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let reason = (error as? StreamFailure) == .disconnected ? "connection lost" : "\(error)"
                    report(.retrying(String(reason.prefix(80))))
                }
            }
            await mixer.removeOutput(stream)
            try? await connection.close()
            if Task.isCancelled {
                break
            }
            attempt += 1
            let wait = UInt64(min(10, 1 + attempt * 2))
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
        feeder.cancel()
        await mixer.stopRunning()
    }
}

#endif
