import Foundation
import Network

/// RTMP 连接 — 封装 TCP Socket + Handshake + Command + 数据发送
final class RtmpConnection {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "rtmp.connection")
    private var chunkSize: Int = 128
    private var streamId: UInt32 = 0
    private var videoTimestamp: UInt32 = 0
    private let sendLock = DispatchQueue(label: "rtmp.connection.send")

    // MARK: - Lifecycle

    func connect(host: String, port: UInt16 = 1935) async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )

        return try await withCheckedThrowingContinuation { cont in
            connection = NWConnection(to: endpoint, using: .tcp)
            connection?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let err):
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            connection?.start(queue: queue)
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Send

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func sendCommand(
        name: String,
        transactionId: Double,
        commandObject: [(String, Data)] = [],
        additionalArgs: Data...
    ) {
        let body = Amf0Encoder.encodeCommand(
            name: name,
            transactionId: transactionId,
            commandObject: commandObject,
            additionalArgs: additionalArgs
        )
        RtmpChunk.sendChunked(
            sendRaw,
            fmt: 0,
            csid: .command,
            timestamp: 0,
            messageType: .amf0Command,
            payload: body,
            chunkSize: chunkSize
        )
    }

    // MARK: - RTMP Handshake

    func handshake() async throws {
        // C0 + C1
        var c0c1 = Data()
        c0c1.append(0x03) // RTMP version
        // C1: 4 bytes timestamp + 4 bytes zero + 1528 random bytes
        c0c1.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // timestamp
        c0c1.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // zero
        var random = Data(count: 1528)
        random.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 1528, ptr.baseAddress!)
        }
        c0c1.append(random)
        sendRaw(c0c1)

        // Wait for S0+S1+S2... simplified: just wait briefly for server response
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // C2
        var c2 = Data()
        c2.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // timestamp
        c2.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // timestamp echo
        c2.append(random) // echo server's random (we send our own in practice)
        sendRaw(c2)

        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    }

    // MARK: - RTMP Commands

    /// connect("appName")
    func connectApp(_ app: String, tcUrl: String) {
        let cmdObj: [(String, Data)] = [
            ("app", Amf0Encoder.encodeString(app)),
            ("tcUrl", Amf0Encoder.encodeString(tcUrl)),
            ("type", Amf0Encoder.encodeString("nonprivate")),
            ("flashVer", Amf0Encoder.encodeString("FMLE/3.0")),
            ("fpad", Amf0Encoder.encodeBoolean(false)),
            ("capabilities", Amf0Encoder.encodeNumber(31)),
            ("audioCodecs", Amf0Encoder.encodeNumber(0)),  // no audio
            ("videoCodecs", Amf0Encoder.encodeNumber(1)),  // H.264 only
            ("videoFunction", Amf0Encoder.encodeNumber(1)),
        ]
        sendCommand(name: "connect", transactionId: 1, commandObject: cmdObj)
    }

    /// releaseStream + FCPublish + createStream + publish
    func publish(_ streamKey: String) {
        // releaseStream
        sendCommand(name: "releaseStream", transactionId: 2,
                    additionalArgs: Amf0Encoder.encodeNull(), Amf0Encoder.encodeString(streamKey))

        // FCPublish
        sendCommand(name: "FCPublish", transactionId: 3,
                    additionalArgs: Amf0Encoder.encodeNull(), Amf0Encoder.encodeString(streamKey))

        // createStream → 获取 streamId
        sendCommand(name: "createStream", transactionId: 4, additionalArgs: Amf0Encoder.encodeNull())
        streamId = 1  // 服务器在 _result 中返回，简化处理

        // publish
        sendCommand(name: "publish", transactionId: 5,
                    additionalArgs: Amf0Encoder.encodeNull(),
                    Amf0Encoder.encodeString(streamKey),
                    Amf0Encoder.encodeString("live"))
    }

    /// 设置 Chunk Size
    func setChunkSize(_ size: Int) {
        var data = Data()
        var bigEndian = UInt32(size).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        // Pad to 4 bytes
        RtmpChunk.sendChunked(
            sendRaw,
            fmt: 0,
            csid: .control,
            timestamp: 0,
            messageType: .setChunkSize,
            payload: data,
            chunkSize: chunkSize
        )
        chunkSize = size
    }

    // MARK: - Data sending

    func sendVideoData(_ flvVideoTagData: Data, timestamp: UInt32) {
        sendLock.sync {
            RtmpChunk.sendChunked(
                sendRaw,
                fmt: 0,
                csid: .video,
                timestamp: timestamp,
                messageType: .video,
                payload: flvVideoTagData,
                chunkSize: chunkSize
            )
        }
    }
}
