import Foundation

// The Bluetooth "language" of the XbotGo Chameleon.
//
// WHAT IS KNOWN (seen with nRF Connect on firmware 152):
//   - The mount advertises as "XbotGo-xxxxxx" with service AF30.
//   - It connects without pairing.
//   - Service AE30: AE01 (write without response), AE02 (notify),
//                   AE03 (write without response), AE04 (notify),
//                   AE05 (indicate), AE10 (read, write)
//   - Service AE3A: AE3B (write without response), AE3C (notify)
//   - One message from the mount on AE02 was: AA 55 02 00 52 1E 05 27
//     so messages seem to start with the two bytes AA 55.
//
// WHAT IS NOT KNOWN YET: which bytes make the mount pan and tilt.
// Until those are captured from the XbotGo app (with a Bluetooth sniffer or an
// Android phone's Bluetooth log), `isReady` stays false and this app never
// writes anything to the mount. It only listens. The app then runs in
// "tripod mode": it tracks and zooms, but the mount does not turn.
//
// HOW TO FINISH THIS FILE once the commands are captured:
//   1. Fill in `handshake()` with whatever the XbotGo app sends right after it
//      connects (if anything), in the same order.
//   2. Fill in `velocity(pan:tilt:)` so it builds the "move" message. `pan` and
//      `tilt` are -1...1, where +pan means turn right and +tilt means tilt down.
//   3. Fill in `stop()` with the message that stops the motors.
//   4. Set `isReady` to true.
// `MountFrame.hex("AA 55 ...")` turns a copied hex string into bytes.

/// One Bluetooth write: which characteristic to write to, and the bytes.
struct MountFrame {
    var characteristic: String    // short identifier such as "AE01"
    var data: Data

    /// Builds a frame from a hex string such as "AA 55 02 00".
    static func hex(_ text: String, to characteristic: String) -> MountFrame {
        var bytes: [UInt8] = []
        var pending: Character?
        for character in text where character.isHexDigit {
            if let first = pending {
                if let value = UInt8(String([first, character]), radix: 16) {
                    bytes.append(value)
                }
                pending = nil
            } else {
                pending = character
            }
        }
        return MountFrame(characteristic: characteristic, data: Data(bytes))
    }
}

protocol MountProtocol {
    /// False until the real commands are filled in. While false, nothing is ever written.
    var isReady: Bool { get }
    /// Messages to send once, right after connecting.
    func handshake() -> [MountFrame]
    /// Messages that make the mount turn. Both values are -1...1.
    func velocity(pan: Double, tilt: Double) -> [MountFrame]
    /// Messages that stop the motors.
    func stop() -> [MountFrame]
}

enum ChameleonGATT {
    static let namePrefix = "XbotGo"
    static let advertisedService = "AF30"
    static let mainService = "AE30"
    static let secondService = "AE3A"
    static let write1 = "AE01"
    static let notify1 = "AE02"
    static let write2 = "AE03"
    static let notify2 = "AE04"
    static let indicate = "AE05"
    static let config = "AE10"
    static let write3 = "AE3B"
    static let notify3 = "AE3C"
}

struct ChameleonProtocol: MountProtocol {
    let isReady = false

    func handshake() -> [MountFrame] {
        return []
    }

    func velocity(pan: Double, tilt: Double) -> [MountFrame] {
        // Example of what this will look like once the bytes are known:
        //   let speed = UInt8(abs(pan) * 100)
        //   return [MountFrame.hex("AA 55 ...", to: ChameleonGATT.write1)]
        return []
    }

    func stop() -> [MountFrame] {
        return []
    }
}
