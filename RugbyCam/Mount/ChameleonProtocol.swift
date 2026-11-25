import Foundation

// The Bluetooth "language" of the XbotGo Chameleon.
//
// Recorded from the official XbotGo app on 25 Nov 2026 (Android Bluetooth log,
// firmware already on the mount, no update). Everything below was seen in that
// recording; nothing is guessed.
//
//   - Service AE30: the app writes to AE01 (write without response) and gets
//     replies on AE02 (notify).
//   - Every message: AA 55 <length> 00 <command> <length bytes of data> <check>
//     <check> is CRC-16/XMODEM (polynomial 0x1021, start 0) over all bytes
//     before it, stored low byte first. It matched all 760 recorded messages.
//   - Move: AA 55 07 00 41 <axis> <direction> <speed lo> <speed hi> FA 00 <check>
//       axis       00 = pan (left/right), 01 = tilt (up/down)
//       direction  66 = right / down, 62 = left / up
//       speed      recorded 100 ... 1000 for pan, 400 for tilt
//       FA 00      always the same (250, probably how long one message lasts in ms)
//     The XbotGo app repeats the move message about 30 times a second while a
//     button is held and simply stops sending to stop. There is no stop message.
//   - Right after connecting, the XbotGo app sent these short messages
//     (AA 55 02 00 <cmd> <value>): 76 01, 58 01, 62 01, 6B 08. The mount answers
//     each one. RugbyCam sends the same four once, exactly as recorded.

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
    /// False while the commands are unknown. While false, nothing is ever written.
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
    let isReady = true

    /// Highest speed the XbotGo app used (pan, button held for a while).
    static let maxSpeed = 1000
    /// Below this the mount is not asked to move at all.
    static let minSpeed = 20

    func handshake() -> [MountFrame] {
        // Exactly as recorded from the XbotGo app.
        return [
            MountFrame.hex("AA 55 02 00 76 01 F9 0E", to: ChameleonGATT.write1),
            MountFrame.hex("AA 55 02 00 58 01 10 2B", to: ChameleonGATT.write1),
            MountFrame.hex("AA 55 02 00 62 01 4E C1", to: ChameleonGATT.write1),
            MountFrame.hex("AA 55 02 00 6B 08 FF EA", to: ChameleonGATT.write1)
        ]
    }

    /// One move message per axis that should turn. +pan = right, +tilt = down.
    func velocity(pan: Double, tilt: Double) -> [MountFrame] {
        var frames: [MountFrame] = []
        if let frame = ChameleonProtocol.move(axis: 0x00, rate: pan) {
            frames.append(frame)
        }
        if let frame = ChameleonProtocol.move(axis: 0x01, rate: tilt) {
            frames.append(frame)
        }
        return frames
    }

    /// The mount stops by itself when the move messages stop coming.
    func stop() -> [MountFrame] {
        return []
    }

    static func move(axis: UInt8, rate: Double) -> MountFrame? {
        guard rate.isFinite else { return nil }
        let speed = Int((min(abs(rate), 1.0) * Double(maxSpeed)).rounded())
        guard speed >= minSpeed else { return nil }
        let direction: UInt8 = rate > 0 ? 0x66 : 0x62
        let body: [UInt8] = [0xAA, 0x55, 0x07, 0x00, 0x41, axis, direction,
                             UInt8(speed & 0xFF), UInt8((speed >> 8) & 0xFF), 0xFA, 0x00]
        return MountFrame(characteristic: ChameleonGATT.write1, data: Data(withCheck(body)))
    }

    /// Adds the CRC-16/XMODEM check, low byte first.
    static func withCheck(_ body: [UInt8]) -> [UInt8] {
        var crc: UInt16 = 0
        for byte in body {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return body + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }
}
