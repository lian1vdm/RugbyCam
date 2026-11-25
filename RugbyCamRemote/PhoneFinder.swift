import Foundation
import Network

/// An iPhone running RugbyCam that was found on the network.
struct FoundPhone: Identifiable, Hashable {
    let id: String          // the Bonjour name
    var address: String?    // for example "http://192.168.1.23:8080", nil until resolved
}

/// Looks for iPhones that run RugbyCam with "Allow control from an iPad" on.
/// They announce themselves on the local network as _rugbycam._tcp.
final class PhoneFinder: ObservableObject {
    static let serviceType = "_rugbycam._tcp"

    @Published private(set) var phones: [FoundPhone] = []
    @Published private(set) var problem: String?

    private let queue = DispatchQueue(label: "rugbycam.remote.finder")
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]     // only touched on queue
    private var addresses: [String: String] = [:]           // only touched on queue

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let newBrowser = NWBrowser(for: .bonjour(type: PhoneFinder.serviceType, domain: nil), using: parameters)
        newBrowser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.problem = nil }
            case .waiting:
                DispatchQueue.main.async {
                    self?.problem = "The iPad is not allowed to search the network. Open the iPad Settings > Privacy & Security > Local Network and turn on RC Remote."
                }
            case .failed(let error):
                DispatchQueue.main.async {
                    self?.problem = "Searching stopped: \(error.localizedDescription)"
                    self?.restart()
                }
            default:
                break
            }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser = newBrowser
        newBrowser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        queue.async {
            for connection in self.resolving.values {
                connection.cancel()
            }
            self.resolving = [:]
        }
    }

    /// Search again from scratch, for example after the iPad joined another network.
    func restart() {
        stop()
        queue.async {
            self.addresses = [:]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.phones = []
            self.start()
        }
    }

    // MARK: - On the finder queue

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [(String, NWEndpoint)] = []
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                found.append((name, result.endpoint))
            }
        }
        let names = Set(found.map { $0.0 })
        for (name, connection) in resolving where !names.contains(name) {
            connection.cancel()
            resolving[name] = nil
        }
        for name in addresses.keys where !names.contains(name) {
            addresses[name] = nil
        }
        for (name, endpoint) in found where addresses[name] == nil && resolving[name] == nil {
            resolve(endpoint, name: name)
        }
        publish(names: names)
    }

    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                   let address = PhoneFinder.address(host: host, port: port) {
                    self.addresses[name] = address
                }
                self.resolving[name] = nil
                connection.cancel()
                self.publish(names: nil)
            case .failed, .waiting:
                self.resolving[name] = nil
                connection.cancel()
                // Try again a little later; the phone may still be joining the network.
                self.queue.asyncAfter(deadline: .now() + 3.0) {
                    if self.addresses[name] == nil, self.resolving[name] == nil, self.browser != nil {
                        self.resolve(endpoint, name: name)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private var knownNames: Set<String> = []

    private func publish(names: Set<String>?) {
        if let names = names {
            knownNames = names
        }
        let list = knownNames.sorted().map { FoundPhone(id: $0, address: addresses[$0]) }
        DispatchQueue.main.async {
            self.phones = list
        }
    }

    static func address(host: NWEndpoint.Host, port: NWEndpoint.Port) -> String? {
        var text: String
        switch host {
        case .ipv4(let ip):
            text = "\(ip)"
        case .ipv6(let ip):
            text = "\(ip)"
        case .name(let name, _):
            text = name
        @unknown default:
            return nil
        }
        if let percent = text.firstIndex(of: "%") {
            text = String(text[text.startIndex..<percent])
        }
        if text.contains(":") {
            text = "[" + text + "]"
        }
        return "http://\(text):\(port.rawValue)"
    }
}
