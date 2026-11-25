import Foundation
import Security

enum CaptureQuality: String, Codable, CaseIterable, Identifiable {
    case uhd60
    case uhd30
    case hd60

    var id: String { rawValue }

    var width: Int {
        return self == .hd60 ? 1920 : 3840
    }

    var height: Int {
        return self == .hd60 ? 1080 : 2160
    }

    var fps: Int {
        return self == .uhd30 ? 30 : 60
    }

    var label: String {
        switch self {
        case .uhd60: return "4K 60"
        case .uhd30: return "4K 30"
        case .hd60: return "1080p 60"
        }
    }

    /// The next lower quality to try when the phone does not offer this one.
    var fallback: CaptureQuality? {
        switch self {
        case .uhd60: return .uhd30
        case .uhd30: return .hd60
        case .hd60: return nil
        }
    }
}

enum RecordingCodec: String, Codable, CaseIterable, Identifiable {
    case hevc
    case h264

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hevc: return "HEVC (smaller files)"
        case .h264: return "H.264 (most compatible)"
        }
    }
}

enum StreamResolution: String, Codable, CaseIterable, Identifiable {
    case p720
    case p1080
    case p1440
    case p2160

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .p720: return 1280
        case .p1080: return 1920
        case .p1440: return 2560
        case .p2160: return 3840
        }
    }

    var height: Int {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }

    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
}

/// Everything the user can change, saved between launches.
struct AppSettings: Codable, Equatable {
    // Recording
    var quality = CaptureQuality.uhd60
    var codec = RecordingCodec.hevc
    var saveToPhotos = true
    var stabilisation = false

    // Tracking
    var showOverlay = true
    var lensStepsOnly = false
    var autoZoomMinDisplay = 1.0      // widest zoom the auto zoom may use, as shown on screen
    var autoZoomMaxDisplay = 4.0      // tightest zoom the auto zoom may use
    var followSpeed = 1.0             // multiplies how eagerly the mount turns
    var zoomTightness = 0.55          // share of the picture the players should fill
    var detectionRate = 12.0          // looks per second
    var ballConfidence = 0.12
    var searchZoom = 2.0              // how far the ball search zooms into the picture
    var tiltEnabled = true
    var invertPan = false
    var invertTilt = false
    var manualSpeed = 0.5             // speed of the arrow buttons, 0.1 ... 1

    // Training
    var saveHardFrames = false        // keep pictures of moments the ball is lost while recording
    var importEvery = 1.0             // seconds between two looks when importing a video
    var importKeep = 60               // pictures kept per imported video

    // iPad remote
    var remoteEnabled = false

    // Streaming
    var streamURL = "rtmp://a.rtmp.youtube.com/live2"
    var streamResolution = StreamResolution.p1080
    var streamFPS = 60
    var streamBitrateMbps = 9.0
    var streamAudioKbps = 128

    private static let storageKey = "settings.v1"

    static func load() -> AppSettings {
        let defaults = AppSettings()
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return defaults
        }
        if let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return decoded
        }
        // An older version saved fewer settings: lay the saved values over the defaults.
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] else {
            return defaults
        }
        for (key, value) in saved {
            merged[key] = value
        }
        if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: mergedData) {
            return decoded
        }
        return defaults
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.storageKey)
        }
    }
}

/// Keeps the stream key in the iPhone's keychain instead of plain settings.
enum Keychain {
    private static let service = "RugbyCam"

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            return
        }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
