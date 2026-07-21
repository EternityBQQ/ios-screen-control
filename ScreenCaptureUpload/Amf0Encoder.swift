import Foundation

/// AMF0 编码器 — 仅实现 RTMP 推流所需的子集
enum Amf0Encoder {

    // MARK: - Type markers

    static let numberMarker: UInt8  = 0x00
    static let booleanMarker: UInt8 = 0x01
    static let stringMarker: UInt8  = 0x02
    static let objectMarker: UInt8  = 0x03
    static let nullMarker: UInt8    = 0x05

    // MARK: - Encoders

    static func encodeString(_ value: String) -> Data {
        var data = Data()
        data.append(stringMarker)
        let utf8 = value.data(using: .utf8)!
        let len = UInt16(utf8.count)
        data.append(contentsOf: [UInt8(len >> 8), UInt8(len & 0xFF)])
        data.append(utf8)
        return data
    }

    static func encodeNumber(_ value: Double) -> Data {
        var data = Data()
        data.append(numberMarker)
        var bigEndian = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func encodeBoolean(_ value: Bool) -> Data {
        Data([booleanMarker, value ? 1 : 0])
    }

    static func encodeNull() -> Data {
        Data([nullMarker])
    }

    static func encodeObject(_ dict: [(String, Data)]) -> Data {
        var data = Data()
        data.append(objectMarker)
        for (key, value) in dict {
            let utf8 = key.data(using: .utf8)!
            data.append(contentsOf: [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
            data.append(utf8)
            data.append(value)
        }
        // Object end marker
        data.append(contentsOf: [0x00, 0x00, 0x09])
        return data
    }

    // MARK: - Command helpers

    /// 构建 AMF0 Command: "commandName", transactionId, [commandObject], [optionalArgs...]
    static func encodeCommand(
        name: String,
        transactionId: Double,
        commandObject: [(String, Data)] = [],
        additionalArgs: Data...
    ) -> Data {
        var data = Data()
        data.append(encodeString(name))
        data.append(encodeNumber(transactionId))
        if commandObject.isEmpty {
            data.append(encodeNull())
        } else {
            data.append(encodeObject(commandObject))
        }
        for arg in additionalArgs {
            data.append(arg)
        }
        return data
    }
}
