import Foundation

/// RTMP Chunk 层 — 负责 Chunk Header 编解码和消息分包
enum RtmpChunk {

    /// Chunk Stream ID 常量
    enum StreamID: UInt8 {
        case control   = 2   // 协议控制消息
        case command   = 3   // AMF0 命令 (connect/publish/...)
        case audio     = 4   // 音频数据
        case video     = 6   // 视频数据 (FLV VideoTag)
    }

    /// RTMP Message Type
    enum MessageType: UInt8 {
        case setChunkSize            = 0x01
        case abort                   = 0x02
        case ack                     = 0x03
        case userControl             = 0x04
        case windowAckSize           = 0x05
        case setPeerBandwidth        = 0x06
        case audio                   = 0x08
        case video                   = 0x09
        case amf0Command             = 0x14  // AMF0 命令 (connect/publish)
        case amf0Data                = 0x12  // AMF0 数据 (@setDataFrame)
    }

    /// 编码 Chunk Basic Header (FMT + CSID)
    static func encodeBasicHeader(fmt: UInt8, csid: StreamID) -> Data {
        // For csid 2-63: 1 byte: [fmt:2][csid:6]
        Data([(fmt << 6) | csid.rawValue])
    }

    /// 编码 Chunk Message Header (FMT=0, 完整头: 11 bytes + optional extended timestamp)
    static func encodeMessageHeader(
        timestamp: UInt32,
        messageLength: Int,
        messageType: MessageType,
        messageStreamId: UInt32 = 0
    ) -> Data {
        var data = Data()

        // Timestamp (3 bytes, big-endian)
        let ts = min(timestamp, 0xFFFFFF)
        data.append(contentsOf: [
            UInt8((ts >> 16) & 0xFF),
            UInt8((ts >> 8) & 0xFF),
            UInt8(ts & 0xFF),
        ])

        // Message Length (3 bytes, big-endian)
        data.append(contentsOf: [
            UInt8((messageLength >> 16) & 0xFF),
            UInt8((messageLength >> 8) & 0xFF),
            UInt8(messageLength & 0xFF),
        ])

        // Message Type ID (1 byte)
        data.append(messageType.rawValue)

        // Message Stream ID (4 bytes, little-endian)
        var sid = messageStreamId.littleEndian
        withUnsafeBytes(of: &sid) { data.append(contentsOf: $0) }

        return data
    }

    /// 将消息拆分为 Chunk 并发送，每个 chunk 最多 chunkSize 字节 (含 header)
    static func sendChunked(
        _ send: (Data) -> Void,
        fmt: UInt8,
        csid: StreamID,
        timestamp: UInt32,
        messageType: MessageType,
        messageStreamId: UInt32 = 0,
        payload: Data,
        chunkSize: Int
    ) {
        let basicHeader = encodeBasicHeader(fmt: fmt, csid: csid)
        let msgHeader = encodeMessageHeader(
            timestamp: timestamp,
            messageLength: payload.count,
            messageType: messageType,
            messageStreamId: messageStreamId
        )

        var offset = 0
        var firstChunk = true

        while offset < payload.count {
            let maxDataSize = chunkSize - basicHeader.count - (firstChunk ? msgHeader.count : 0)
            let end = min(offset + maxDataSize, payload.count)
            let chunk = payload[offset..<end]

            var chunkData = Data()
            chunkData.append(basicHeader)
            if firstChunk {
                chunkData.append(msgHeader)
            }
            chunkData.append(contentsOf: chunk)

            send(chunkData)

            offset = end
            firstChunk = false
            // 后续 chunk 用 FMT=3 (无 Message Header)
            // 实际上后续 chunk 只用 1-byte basic header (FMT=3)
        }
    }
}
