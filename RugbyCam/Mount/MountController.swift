import CoreBluetooth
import Foundation

enum MountState: Equatable {
    case unavailable(String)      // Bluetooth is off or not allowed
    case idle                     // not trying to connect
    case scanning
    case connecting(String)
    case connected(String)        // linked, but the move commands are not known yet
    case ready(String)            // linked and able to move

    var label: String {
        switch self {
        case .unavailable(let reason): return reason
        case .idle: return "Mount off"
        case .scanning: return "Looking for the mount"
        case .connecting(let name): return "Connecting to \(name)"
        case .connected(let name): return "\(name) linked (tripod mode)"
        case .ready(let name): return "\(name) ready"
        }
    }

    var canMove: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var isLinked: Bool {
        switch self {
        case .connected, .ready: return true
        default: return false
        }
    }
}

/// Talks to the XbotGo Chameleon over Bluetooth.
/// It always listens to what the mount sends. It only writes when
/// ChameleonProtocol.isReady is true.
final class MountController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Both are called on the mount's own queue.
    var onStateChange: ((MountState) -> Void)?
    var onLog: ((String) -> Void)?

    private static let rememberedNameKey = "mount.rememberedName"

    private let queue = DispatchQueue(label: "rugbycam.mount")
    private let commands: MountProtocol = ChameleonProtocol()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var deviceName = ""
    private var characteristics: [String: CBCharacteristic] = [:]
    private var wantsConnection = false
    private var candidates: [(peripheral: CBPeripheral, name: String, signal: Int)] = []
    private var pickScheduled = false
    private var state = MountState.idle
    private var moving = false
    private var lastCommandTime = 0.0
    private var lastWriteTime = 0.0
    private var watchdog: DispatchSourceTimer?
    private var lastLogLine = ""
    private var lastLogTime = 0.0

    /// The mount this phone linked to before, if any.
    static var rememberedName: String? {
        return UserDefaults.standard.string(forKey: rememberedNameKey)
    }

    // MARK: - Public

    func connect() {
        queue.async {
            self.wantsConnection = true
            if self.central == nil {
                // Creating the manager asks for Bluetooth permission the first time.
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else {
                self.startScan()
            }
        }
    }

    func disconnect() {
        queue.async {
            self.wantsConnection = false
            self.sendStop()
            self.central?.stopScan()
            if let linked = self.peripheral {
                self.central?.cancelPeripheralConnection(linked)
            }
            self.dropLink()
            self.setState(.idle)
        }
    }

    /// Forgets which mount belongs to this phone, so the next search takes the nearest one.
    func forget() {
        UserDefaults.standard.removeObject(forKey: MountController.rememberedNameKey)
        disconnect()
    }

    /// Asks the mount to turn. Both values are -1...1. Does nothing in tripod mode.
    func setVelocity(pan: Double, tilt: Double) {
        queue.async {
            guard self.commands.isReady, self.state.canMove else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastCommandTime = now
            if abs(pan) < 0.01 && abs(tilt) < 0.01 {
                if self.moving {
                    self.sendStop()
                }
                return
            }
            // Twenty messages a second is plenty for a motor.
            guard now - self.lastWriteTime >= 0.05 else { return }
            self.lastWriteTime = now
            self.moving = true
            self.write(self.commands.velocity(pan: pan, tilt: tilt))
        }
    }

    func stopMotion() {
        queue.async {
            self.sendStop()
        }
    }

    // MARK: - Scanning and connecting

    private func setState(_ newState: MountState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    private func startScan() {
        guard wantsConnection, peripheral == nil, let central = central, central.state == .poweredOn else {
            return
        }
        candidates = []
        pickScheduled = false
        setState(.scanning)
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff:
            dropLink()
            setState(.unavailable("Bluetooth is off"))
        case .unauthorized:
            setState(.unavailable("Bluetooth is not allowed for RugbyCam"))
        case .unsupported:
            setState(.unavailable("This device has no Bluetooth LE"))
        default:
            setState(.unavailable("Bluetooth is not ready"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? ""
        guard name.hasPrefix(ChameleonGATT.namePrefix) else { return }

        if let remembered = MountController.rememberedName {
            // Only ever link to the mount this phone used before.
            if name == remembered {
                link(to: peripheral, name: name)
            }
            return
        }
        // First time: several teams may have a mount here, so wait a moment and
        // take the one with the strongest signal (the nearest).
        if let index = candidates.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            candidates[index].signal = RSSI.intValue
        } else {
            candidates.append((peripheral: peripheral, name: name, signal: RSSI.intValue))
        }
        if !pickScheduled {
            pickScheduled = true
            queue.asyncAfter(deadline: .now() + 2.5) {
                self.pickNearest()
            }
        }
    }

    private func pickNearest() {
        pickScheduled = false
        guard peripheral == nil, wantsConnection else { return }
        guard let best = candidates.max(by: { $0.signal < $1.signal }) else { return }
        UserDefaults.standard.set(best.name, forKey: MountController.rememberedNameKey)
        link(to: best.peripheral, name: best.name)
    }

    private func link(to found: CBPeripheral, name: String) {
        central?.stopScan()
        peripheral = found
        deviceName = name
        found.delegate = self
        setState(.connecting(name))
        central?.connect(found, options: nil)
    }

    private func dropLink() {
        watchdog?.cancel()
        watchdog = nil
        peripheral = nil
        characteristics = [:]
        candidates = []
        moving = false
    }

    private func retrySoon() {
        guard wantsConnection else {
            setState(.idle)
            return
        }
        queue.asyncAfter(deadline: .now() + 1.5) {
            self.startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Linked to \(deviceName)")
        setState(.connected(deviceName))
        peripheral.discoverServices(nil)
        startWatchdog()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Could not connect: \(error?.localizedDescription ?? "unknown reason")")
        dropLink()
        retrySoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Mount disconnected")
        dropLink()
        retrySoon()
    }

    // MARK: - Services

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let found = service.characteristics ?? []
        for characteristic in found {
            characteristics[characteristic.uuid.uuidString.uppercased()] = characteristic
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        let names = found.map { $0.uuid.uuidString }.joined(separator: ", ")
        log("Service \(service.uuid.uuidString): \(names)")
        refreshReadiness()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        log("\(characteristic.uuid.uuidString) > \(bytes)")
    }

    /// Switches to "ready" once the commands are known and every characteristic they need is there.
    private func refreshReadiness() {
        guard commands.isReady, peripheral != nil, !state.canMove else { return }
        let needed = commands.handshake() + commands.stop()
        for frame in needed where characteristics[frame.characteristic.uppercased()] == nil {
            return
        }
        write(commands.handshake())
        setState(.ready(deviceName))
    }

    // MARK: - Writing

    private func sendStop() {
        guard commands.isReady else { return }
        moving = false
        write(commands.stop())
    }

    private func write(_ frames: [MountFrame]) {
        guard commands.isReady, let linked = peripheral else { return }
        for frame in frames {
            guard let characteristic = characteristics[frame.characteristic.uppercased()] else {
                continue
            }
            let withoutResponse = characteristic.properties.contains(.writeWithoutResponse)
            linked.writeValue(frame.data, for: characteristic, type: withoutResponse ? .withoutResponse : .withResponse)
        }
    }

    /// Safety net: if the app stops sending commands (a crash, a stall), stop the motors.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.moving else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastCommandTime > 0.6 {
                self.sendStop()
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - Log

    private func log(_ line: String) {
        // The mount repeats status messages many times a second; show each one once a while.
        let now = ProcessInfo.processInfo.systemUptime
        if line == lastLogLine && now - lastLogTime < 5.0 {
            return
        }
        // At most about five lines a second, so a chatty mount cannot slow the screen down.
        // Only messages from the mount ("AE02 > ...") are thinned out this way.
        if line.contains(" > ") && now - lastLogTime < 0.2 {
            return
        }
        lastLogLine = line
        lastLogTime = now
        onLog?(line)
    }
}
