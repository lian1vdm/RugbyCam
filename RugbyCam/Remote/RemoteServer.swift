import CoreImage
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Network

/// What the iPad control panel shows. Built on the main thread.
struct RemoteStatus: Encodable {
    var recording = false
    var recordingTime = ""
    var follow = false
    var autoZoom = false
    var zoomText = ""
    var zoomPosition = 0.0
    var streamAvailable = false
    var streamOn = false
    var streamText = ""
    var battery = -1                 // percent, -1 when unknown
    var charging = false
    var hot = false
    var freeSpace = ""
    var camera = ""
    var cameraPaused = false         // the settings are open on the iPhone
    var tracking = ""
    var mount = ""
    var notice: String?
    var ball: [Double]?              // x, y, w, h (0...1)
    var ballConfirmed = false
    var players: [[Double]] = []
}

/// A very small web server inside the app. An iPad (or any browser on the same
/// Wi-Fi or on the iPhone's hotspot) opens the control panel page, sees a small
/// live picture and the status, and can start and stop recording, the
/// following, the auto zoom, the stream and change the zoom.
///
/// Every request except the page itself needs the PIN shown on the iPhone.
final class RemoteServer {
    static let port: UInt16 = 8080
    private static let pinKey = "remote.pin"

    /// Called on the main thread to build the status.
    var statusProvider: (() -> RemoteStatus)?
    /// Called on the main thread with a command and its value.
    var onCommand: ((String, Double?) -> Void)?
    /// Called on the main thread whenever a control panel asks for the status.
    var onClientSeen: (() -> Void)?
    /// Called on the main thread: all settings as JSON.
    var settingsProvider: (() -> Data)?
    /// Called on the main thread to change one setting. Returns a problem, or nil.
    var onSet: ((String, String) -> String?)?
    /// Called on the main thread when the server starts, stops or fails.
    var onStateChange: ((String?) -> Void)?

    private(set) var pin: String

    private let queue = DispatchQueue(label: "rugbycam.remote", qos: .utility)
    private var listener: NWListener?

    // Small preview pictures. Encoded only while a control panel is watching.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let frameLock = NSLock()
    private var latestJPEG: Data?
    private var lastFrameRequest = -1.0e9
    private var lastEncode = -1.0e9
    private var encoding = false

    init() {
        if let saved = UserDefaults.standard.string(forKey: RemoteServer.pinKey), saved.count == 4 {
            pin = saved
        } else {
            pin = RemoteServer.randomPin()
            UserDefaults.standard.set(pin, forKey: RemoteServer.pinKey)
        }
    }

    var isRunning: Bool {
        return listener != nil
    }

    func newPin() {
        pin = RemoteServer.randomPin()
        UserDefaults.standard.set(pin, forKey: RemoteServer.pinKey)
    }

    private static func randomPin() -> String {
        return String(format: "%04d", Int.random(in: 0...9999))
    }

    // MARK: - Start and stop (main thread)

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RemoteServer.port)!)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    DispatchQueue.main.async {
                        self?.listener?.cancel()
                        self?.listener = nil
                        self?.onStateChange?("The iPad remote could not start: \(error.localizedDescription)")
                    }
                case .ready:
                    DispatchQueue.main.async {
                        self?.onStateChange?(nil)
                    }
                default:
                    break
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            onStateChange?("The iPad remote could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        frameLock.lock()
        latestJPEG = nil
        frameLock.unlock()
        onStateChange?(nil)
    }

    // MARK: - Preview frames (capture queue)

    /// Offer a camera frame. Cheap when nobody watches: it returns at once.
    func offerFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        frameLock.lock()
        let wanted = now - lastFrameRequest < 3.0 && now - lastEncode >= 0.2 && !encoding
        if wanted {
            encoding = true
            lastEncode = now
        }
        frameLock.unlock()
        guard wanted else { return }

        // Make the small picture straight away, so the camera gets its buffer back quickly.
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 640.0 / max(image.extent.width, 1.0)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        queue.async {
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55
            ]
            let jpeg = self.ciContext.jpegRepresentation(of: image, colorSpace: self.colorSpace, options: options)
            self.frameLock.lock()
            if let jpeg = jpeg {
                self.latestJPEG = jpeg
            }
            self.encoding = false
            self.frameLock.unlock()
        }
    }

    // MARK: - Connections (server queue)

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop connections that never finish their request.
        queue.asyncAfter(deadline: .now() + 10.0) {
            connection.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var all = buffer
            if let data = data {
                all.append(data)
            }
            if let end = all.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: all[all.startIndex..<end.lowerBound], as: UTF8.self)
                self.handle(head, on: connection)
            } else if error != nil || isComplete || all.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: all)
            }
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", type: "text/plain", body: Data("bad request".utf8), on: connection)
            return
        }
        let target = String(parts[1])
        let components = URLComponents(string: "http://phone" + target)
        let path = components?.path ?? "/"
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        if path == "/" || path == "/index.html" {
            send(status: "200 OK", type: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8), on: connection)
            return
        }
        guard query["pin"] == pin else {
            send(status: "403 Forbidden", type: "text/plain", body: Data("wrong pin".utf8), on: connection)
            return
        }
        switch path {
        case "/frame.jpg":
            frameLock.lock()
            lastFrameRequest = ProcessInfo.processInfo.systemUptime
            let jpeg = latestJPEG
            frameLock.unlock()
            if let jpeg = jpeg {
                send(status: "200 OK", type: "image/jpeg", body: jpeg, on: connection)
            } else {
                send(status: "204 No Content", type: "image/jpeg", body: Data(), on: connection)
            }
        case "/status":
            sendStatus(on: connection, command: nil, value: nil)
        case "/cmd":
            let value = query["v"].flatMap { Double($0) }
            sendStatus(on: connection, command: query["do"] ?? "", value: value)
        case "/settings":
            sendSettings(on: connection, key: nil, value: "")
        case "/set":
            sendSettings(on: connection, key: query["key"] ?? "", value: query["v"] ?? "")
        default:
            send(status: "404 Not Found", type: "text/plain", body: Data("not found".utf8), on: connection)
        }
    }

    private func sendStatus(on connection: NWConnection, command: String?, value: Double?) {
        DispatchQueue.main.async {
            if let command = command, !command.isEmpty {
                self.onCommand?(command, value)
            }
            self.onClientSeen?()
            let status = self.statusProvider?() ?? RemoteStatus()
            let body = (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
            self.queue.async {
                self.send(status: "200 OK", type: "application/json", body: body, on: connection)
            }
        }
    }

    private func sendSettings(on connection: NWConnection, key: String?, value: String) {
        DispatchQueue.main.async {
            var problem: String?
            if let key = key {
                if let handler = self.onSet {
                    problem = handler(key, value)
                } else {
                    problem = "Settings cannot be changed right now."
                }
            }
            self.onClientSeen?()
            var body = Data("{\"settings\":".utf8)
            body.append(self.settingsProvider?() ?? Data("{}".utf8))
            body.append(Data(",\"error\":".utf8))
            body.append((try? JSONEncoder().encode(problem)) ?? Data("null".utf8))
            body.append(Data("}".utf8))
            self.queue.async {
                self.send(status: "200 OK", type: "application/json", body: body, on: connection)
            }
        }
    }

    private func send(status: String, type: String, body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Addresses

    /// The addresses to type into the iPad, for example "Wi-Fi: http://192.168.1.23:8080".
    static func addresses() -> [String] {
        var result: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return result }
        defer { freeifaddrs(first) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            let label: String
            if name == "en0" {
                label = "Wi-Fi"
            } else if name.hasPrefix("bridge") {
                label = "Hotspot"
            } else if name.hasPrefix("en") {
                label = "Network"
            } else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") {
                    result.append("\(label): http://\(ip):\(port)")
                }
            }
        }
        return result
    }
}
