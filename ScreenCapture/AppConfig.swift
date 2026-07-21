import Foundation

/// 通过 App Group UserDefaults 在主 App 和 Extension 间共享 RTMP URL
final class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults(suiteName: "group.com.screencapture.app")!

    private enum Key {
        static let rtmpUrl = "rtmp_url"
    }

    var rtmpUrl: String {
        get { defaults.string(forKey: Key.rtmpUrl) ?? "rtmp://localhost/live/iphone" }
        set { defaults.set(newValue, forKey: Key.rtmpUrl) }
    }
}
