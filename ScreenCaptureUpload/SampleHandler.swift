import ReplayKit
import Foundation

/// Broadcast Upload Extension 入口
/// 接收 ReplayKit 的 CMSampleBuffer，编码后 RTMP 推流
final class SampleHandler: RPBroadcastSampleHandler {

    private var connection: RtmpConnection?
    private var encoder: VideoEncoder?
    private var flvWriter: FLVWriter?
    private var hasSentHeader = false
    private var hasSentFlvHeader = false
    private var frameCount: UInt32 = 0
    private let frameDurationMs: UInt32 = 33  // ~30fps

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let rtmpUrl = AppConfig.shared.rtmpUrl
        print("[SampleHandler] broadcastStarted, rtmpUrl=\(rtmpUrl)")

        guard let (host, port, app, streamKey) = parseRtmpUrl(rtmpUrl) else {
            print("[SampleHandler] Invalid RTMP URL: \(rtmpUrl)")
            finishBroadcastWithError(NSError(
                domain: "ScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid RTMP URL"]
            ))
            return
        }

        connection = RtmpConnection()
        encoder = VideoEncoder()
        flvWriter = FLVWriter()

        encoder?.configure { [weak self] nalUnits in
            self?.onEncodedNalUnits(nalUnits)
        }

        let tcUrl = "rtmp://\(host):\(port)/\(app)"

        Task {
            do {
                try await connection?.connect(host: host, port: port)
                try await connection?.handshake()
                connection?.setChunkSize(4096)
                try await Task.sleep(nanoseconds: 100_000_000)
                connection?.connectApp(app, tcUrl: tcUrl)
                try await Task.sleep(nanoseconds: 100_000_000)
                connection?.publish(streamKey)
                print("[SampleHandler] RTMP publish started for \(streamKey)")
            } catch {
                print("[SampleHandler] RTMP connection failed: \(error)")
                finishBroadcastWithError(error)
            }
        }
    }

    override func broadcastFinished() {
        print("[SampleHandler] broadcastFinished, frames=\(frameCount)")
        encoder?.invalidate()
        connection?.disconnect()
    }

    // MARK: - Video frames

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        encoder?.encode(sampleBuffer)
    }

    // MARK: - Encoding output

    private func onEncodedNalUnits(_ nalUnits: [Data]) {
        guard let connection, let flvWriter else { return }

        // Send FLV header once
        if !hasSentFlvHeader {
            connection.sendVideoData(flvWriter.makeHeader(), timestamp: 0)
            hasSentFlvHeader = true
        }

        // Send sequence header once (after first SPS/PPS are cached)
        if !hasSentHeader, let seqHeader = flvWriter.makeSequenceHeader() {
            connection.sendVideoData(seqHeader, timestamp: 0)
            hasSentHeader = true
        }

        // Send video frame
        let timestamp = frameCount * frameDurationMs
        let videoTag = flvWriter.makeVideoTag(nalUnits: nalUnits, timestamp: timestamp)
        connection.sendVideoData(videoTag, timestamp: timestamp)

        frameCount += 1
    }

    // MARK: - URL parser

    /// 解析 rtmp://host:port/app/streamKey
    private func parseRtmpUrl(_ url: String) -> (host: String, port: UInt16, app: String, streamKey: String)? {
        // rtmp://host:port/app/streamKey
        guard let urlObj = URL(string: url),
              urlObj.scheme == "rtmp" || urlObj.scheme == "rtmps",
              let host = urlObj.host else { return nil }

        let port = UInt16(urlObj.port ?? 1935)
        let path = urlObj.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/", maxSplits: 1)
        let app = parts.first.map(String.init) ?? "live"
        let streamKey = parts.count > 1 ? String(parts[1]) : "iphone"

        return (host, port, app, streamKey)
    }
}

// MARK: - AppConfig (Extension 侧复用)

/// 从 App Group 读取共享配置
/// 注: 这个 struct 和 Main App 中的 AppConfig 逻辑相同，Extension 中是独立编译单元
private struct AppConfig {
    static let shared = AppConfig()
    private let defaults = UserDefaults(suiteName: "group.com.screencapture.app")!

    var rtmpUrl: String {
        defaults.string(forKey: "rtmp_url") ?? "rtmp://localhost/live/iphone"
    }
}
