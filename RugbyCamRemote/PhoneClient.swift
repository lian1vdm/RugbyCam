import Foundation
import SwiftUI
import UIKit

/// What the iPhone reports, the same JSON the web control panel reads.
/// Every field is optional so an older or newer iPhone app still works.
struct PhoneStatus: Decodable {
    var recording: Bool?
    var recordingTime: String?
    var follow: Bool?
    var autoZoom: Bool?
    var zoomText: String?
    var zoomPosition: Double?
    var streamAvailable: Bool?
    var streamOn: Bool?
    var streamText: String?
    var battery: Int?
    var charging: Bool?
    var hot: Bool?
    var freeSpace: String?
    var camera: String?
    var cameraPaused: Bool?
    var tracking: String?
    var mount: String?
    var notice: String?
    var ball: [Double]?
    var ballConfirmed: Bool?
    var players: [[Double]]?
    var mountReady: Bool?
    var home: String?
    var away: String?
    var homeScore: Int?
    var awayScore: Int?
    var period: Int?
    var scoreInVideo: Bool?
}

/// Talks to RugbyCam on the iPhone over the local network.
@MainActor
final class PhoneClient: ObservableObject {
    enum Link: Equatable {
        case idle           // not connected to anything
        case connecting
        case connected
        case unreachable    // was connected, now no answer
        case wrongPin
    }

    private static let addressKey = "phone.address"
    private static let pinKey = "phone.pin"

    @Published var address: String = UserDefaults.standard.string(forKey: PhoneClient.addressKey) ?? ""
    @Published var pin: String = UserDefaults.standard.string(forKey: PhoneClient.pinKey) ?? ""
    @Published private(set) var link: Link = .idle
    @Published private(set) var status: PhoneStatus?
    @Published private(set) var picture: UIImage?
    @Published private(set) var settings: [String: Any] = [:]
    @Published private(set) var settingsProblem: String?
    @Published private(set) var moving = false

    private let session: URLSession
    private var statusTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var failures = 0
    private var lastZoomSent = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3.0
        configuration.timeoutIntervalForResource = 6.0
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    var hasSavedPhone: Bool {
        return !address.isEmpty && pin.count == 4
    }

    // MARK: - Connecting

    /// Connect to an address such as "http://192.168.1.23:8080" or just "192.168.1.23".
    func connect(to rawAddress: String, pin rawPin: String) {
        address = PhoneClient.clean(rawAddress)
        pin = rawPin.filter { $0.isNumber }
        UserDefaults.standard.set(address, forKey: PhoneClient.addressKey)
        UserDefaults.standard.set(pin, forKey: PhoneClient.pinKey)
        stopLoops()
        status = nil
        picture = nil
        failures = 0
        link = .connecting
        startLoops()
    }

    /// Reconnect to the saved phone, for example when the app comes back to the front.
    func resume() {
        guard hasSavedPhone, statusTask == nil, link != .wrongPin, link != .idle else { return }
        startLoops()
    }

    func pause() {
        stopMove()
        stopLoops()
    }

    func disconnect() {
        stopMove()
        stopLoops()
        link = .idle
        status = nil
        picture = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return value }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        // Add the RugbyCam port when only an address was typed.
        if let components = URLComponents(string: value), components.port == nil {
            value += ":8080"
        }
        return value
    }

    private func startLoops() {
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.refreshStatus()
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                if self.link == .connected {
                    await self.refreshPicture()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    private func stopLoops() {
        statusTask?.cancel()
        statusTask = nil
        frameTask?.cancel()
        frameTask = nil
    }

    // MARK: - Requests

    private func makeURL(_ path: String, _ items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: address + path) else { return nil }
        components.queryItems = [URLQueryItem(name: "pin", value: pin)] + items
        return components.url
    }

    private func get(_ path: String, _ items: [URLQueryItem] = [], timeout: TimeInterval = 2.5) async -> (Data, Int)? {
        guard let url = makeURL(path, items) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        } catch {
            return nil
        }
    }

    private func refreshStatus() async {
        let result = await get("/status")
        handleStatus(result)
    }

    private func handleStatus(_ result: (Data, Int)?) {
        guard case let (data, code)? = result else {
            failures += 1
            if failures >= 4 && link != .idle {
                link = .unreachable
            }
            return
        }
        if code == 403 {
            stopLoops()
            link = .wrongPin
            return
        }
        guard code == 200, let decoded = try? JSONDecoder().decode(PhoneStatus.self, from: data) else {
            failures += 1
            return
        }
        failures = 0
        status = decoded
        if link != .connected {
            link = .connected
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func refreshPicture() async {
        let result = await get("/frame.jpg", timeout: 2.0)
        guard case let (data, code)? = result, code == 200, !data.isEmpty else { return }
        if let image = UIImage(data: data) {
            picture = image
        }
    }

    // MARK: - Commands

    func command(_ name: String, _ value: Double? = nil) {
        var items = [URLQueryItem(name: "do", value: name)]
        if let value = value {
            items.append(URLQueryItem(name: "v", value: String(value)))
        }
        Task {
            let result = await get("/cmd", items)
            handleStatus(result)
        }
    }

    func toggle(_ name: String, isOn: Bool?) {
        command(name, (isOn ?? false) ? 0 : 1)
    }

    /// Zoom slider: sends at most about 12 times a second while dragging, and always the last position.
    func zoom(to position: Double, final: Bool) {
        let now = Date()
        if final || now.timeIntervalSince(lastZoomSent) > 0.08 {
            lastZoomSent = now
            command("zoom", min(max(position, 0), 1))
        }
    }

    /// Start turning the mount while an arrow is held. axis is "pan" or "tilt".
    func startMove(_ axis: String, _ direction: Int) {
        moveTask?.cancel()
        moving = true
        let items = [URLQueryItem(name: "do", value: axis), URLQueryItem(name: "v", value: direction > 0 ? "1" : "-1")]
        moveTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                guard let self = self else { return }
                // Safety: never keep turning for more than 20 seconds without a new touch.
                if Date().timeIntervalSince(started) > 20 {
                    self.stopMove()
                    return
                }
                _ = await self.get("/cmd", items, timeout: 1.0)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopMove() {
        let wasMoving = moving || moveTask != nil
        moveTask?.cancel()
        moveTask = nil
        moving = false
        guard wasMoving else { return }
        let items = [URLQueryItem(name: "do", value: "moveStop")]
        Task {
            _ = await get("/cmd", items, timeout: 1.0)
            // A move request still on its way could arrive after the first stop, so stop once more.
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await get("/cmd", items, timeout: 1.0)
        }
    }

    // MARK: - Settings

    func loadSettings() {
        Task {
            handleSettings(await get("/settings"))
        }
    }

    func setSetting(_ key: String, _ value: String) {
        settings[key] = value
        Task {
            handleSettings(await get("/set", [URLQueryItem(name: "key", value: key), URLQueryItem(name: "v", value: value)]))
        }
    }

    private func handleSettings(_ result: (Data, Int)?) {
        guard case let (data, code)? = result else {
            settingsProblem = "The iPhone did not answer."
            return
        }
        if code == 403 {
            link = .wrongPin
            stopLoops()
            return
        }
        guard code == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = object["settings"] as? [String: Any] else {
            settingsProblem = "The iPhone sent something unexpected. Update RugbyCam on the iPhone."
            return
        }
        settings = values
        settingsProblem = object["error"] as? String
    }

    // Reading settings values.

    func bool(_ key: String) -> Bool {
        if let value = settings[key] as? Bool { return value }
        if let value = settings[key] as? NSNumber { return value.boolValue }
        if let value = settings[key] as? String { return value == "1" || value == "true" }
        return false
    }

    func number(_ key: String) -> Double {
        if let value = settings[key] as? NSNumber { return value.doubleValue }
        if let value = settings[key] as? String, let parsed = Double(value) { return parsed }
        return 0
    }

    func text(_ key: String) -> String {
        if let value = settings[key] as? String { return value }
        if let value = settings[key] as? NSNumber { return value.stringValue }
        return ""
    }
}
