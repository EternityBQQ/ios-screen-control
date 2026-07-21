import SwiftUI

struct ContentView: View {
    @State private var rtmpUrl: String = AppConfig.shared.rtmpUrl
    @State private var saved = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("RTMP 推流地址")) {
                    TextField("rtmp://your-server/live/stream-key", text: $rtmpUrl)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .onChange(of: rtmpUrl) { _ in saved = false }
                }

                Section(footer: Text("设置后从控制中心长按录屏按钮启动")) {
                    Button("保存") {
                        AppConfig.shared.rtmpUrl = rtmpUrl
                        saved = true
                    }
                    .disabled(rtmpUrl.isEmpty)
                }

                if saved {
                    Section(footer: Text("配置已保存，Extension 将读取此地址")) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("已保存")
                        }
                    }
                }

                Section(header: Text("使用方法")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 在上面填入服务器 RTMP 地址并保存")
                        Text("2. 下拉控制中心 → 长按录屏按钮")
                        Text("3. 选择 ScreenCapture")
                        Text("4. 点击「开始广播」")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("ScreenCapture")
        }
    }
}
