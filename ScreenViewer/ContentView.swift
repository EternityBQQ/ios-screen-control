import SwiftUI
import AVKit
import AVFoundation

// MARK: - Design Tokens

private enum Design {
    static let cornerRadius: CGFloat = 20
    static let smallCorner: CGFloat = 12
    static let spacing: CGFloat = 16
    static let iconSize: CGFloat = 44
}

// MARK: - Model

struct StreamInfo: Codable, Identifiable {
    let key: String
    let status: String
    let startedAt: String?
    let clientIp: String?

    var id: String { key }
    var isLive: Bool { status == "live" }
    var displayName: String { key }
    var subtitle: String { isLive ? "正在推流" : "已离线" }

    enum CodingKeys: String, CodingKey {
        case key, status
        case startedAt = "started_at"
        case clientIp = "client_ip"
    }
}

// MARK: - Root

struct ContentView: View {
    @AppStorage("server_url") private var serverUrl: String = ""
    @State private var streams: [String: StreamInfo] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedStream: String?
    @State private var showScanner = false

    private var hasServer: Bool { !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty }
    private var liveStreams: [StreamInfo] {
        streams.values.filter(\.isLive).sorted(by: { $0.key < $1.key })
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let key = selectedStream, hasServer {
                PlayerView(
                    url: URL(string: "http://\(serverUrl)/hls/\(key).m3u8")!,
                    streamName: key,
                    onDismiss: { selectedStream = nil }
                )
                .ignoresSafeArea()
                .transition(.opacity)
            } else if !hasServer {
                OnboardingView(showScanner: $showScanner) { url in
                    serverUrl = extractHostPort(url)
                    Task { await fetchStreams() }
                }
            } else {
                DeviceListView(
                    serverUrl: serverUrl,
                    streams: liveStreams,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onRefresh: fetchStreams,
                    onDisconnect: { serverUrl = ""; streams = [:] },
                    onSelect: { selectedStream = $0 }
                )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedStream)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: hasServer)
        .task(id: serverUrl) {
            if hasServer { await fetchStreams() }
        }
    }

    // MARK: - Network

    private func fetchStreams() async {
        guard hasServer else { return }
        isLoading = true; errorMessage = nil

        let url = URL(string: "http://\(serverUrl)/api/streams")!
        var req = URLRequest(url: url); req.timeoutInterval = 5

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            streams = try JSONDecoder().decode([String: StreamInfo].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
            streams = [:]
        }
        isLoading = false
    }

    private func extractHostPort(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let host = url.host ?? ""
        let port = url.port.map { ":\($0)" } ?? ":8082"
        return "\(host)\(port)"
    }
}

// MARK: - Onboarding

private struct OnboardingView: View {
    @Binding var showScanner: Bool
    let onScanResult: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 100, height: 100)

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(spacing: 6) {
                    Text("ScreenViewer")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("实时观看 iOS 屏幕推流")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 48)

            // QR Scan button — the only way in
            Button(action: { showScanner = true }) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.accentColor)
                            .frame(width: 52, height: 52)

                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("扫描二维码连接服务器")
                            .font(.system(size: 17, weight: .semibold))
                        Text("打开服务器网页，扫描页面上的二维码")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Design.cornerRadius)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .sheet(isPresented: $showScanner) {
                QRScannerView { url in
                    showScanner = false
                    onScanResult(url)
                }
            }

            Spacer()

            // Bottom hint
            Text("不会自动发现服务器，需扫描二维码连接")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.bottom, 40)
        }
    }
}

// MARK: - Device List

private struct DeviceListView: View {
    let serverUrl: String
    let streams: [StreamInfo]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () async -> Void
    let onDisconnect: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("可用设备")
                    .font(.system(.title2, design: .rounded).bold())

                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(serverUrl)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: { Task { await onRefresh() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .disabled(isLoading)

                Menu {
                    Button(role: .destructive, action: onDisconnect) {
                        Label("断开服务器", systemImage: "link.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            VStack(spacing: 16) {
                ProgressView().scaleEffect(1.2)
                Text("正在查询设备...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else if let error = errorMessage {
            Spacer()
            ErrorStateView(message: error, onRetry: { Task { await onRefresh() } })
            Spacer()
        } else if streams.isEmpty {
            Spacer()
            EmptyStateView(onRefresh: { Task { await onRefresh() } })
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Count badge
                    HStack {
                        Text("\(streams.count) 台设备推流中")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                    ForEach(streams) { stream in
                        DeviceCard(stream: stream, onSelect: { onSelect(stream.key) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .refreshable { await onRefresh() }
        }
    }
}

// MARK: - Device Card

private struct DeviceCard: View {
    let stream: StreamInfo
    let onSelect: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: Design.smallCorner)
                        .fill(Color.green.opacity(0.12))
                        .frame(width: Design.iconSize, height: Design.iconSize)

                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.green)
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text(stream.subtitle)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                Spacer()

                // Play button
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                    .opacity(isPressed ? 0.5 : 1)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerRadius)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .contentShape(Rectangle())
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    let onRefresh: () async -> Void

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 120, height: 120)

                Image(systemName: "iphone.gen3")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.accentColor.opacity(0.6))
                    .offset(y: isAnimating ? -4 : 4)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isAnimating)
            }
            .onAppear { isAnimating = true }

            VStack(spacing: 6) {
                Text("等待设备推流")
                    .font(.title3.weight(.semibold))
                Text("在 iOS 设备上从控制中心\n启动屏幕录制后会出现这里")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: { Task { await onRefresh() } }) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
    }
}

// MARK: - Error State

private struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.08))
                    .frame(width: 100, height: 100)

                Image(systemName: "wifi.slash")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(.red.opacity(0.6))
            }

            VStack(spacing: 6) {
                Text("连接失败").font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button(action: onRetry) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Scale Button Style

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - QR Scanner

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onScan = onScan
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private var session: AVCaptureSession?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()

        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        // Scan overlay
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        overlay.layer.borderWidth = 3
        overlay.layer.cornerRadius = 16
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlay.widthAnchor.constraint(equalToConstant: 220),
            overlay.heightAnchor.constraint(equalToConstant: 220),
        ])

        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasScanned,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = obj.stringValue else { return }
        hasScanned = true
        onScan?(string)
    }
}

// MARK: - Player

struct PlayerView: UIViewControllerRepresentable {
    let url: URL
    let streamName: String
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()

        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = context.coordinator

        // Minimal UI
        controller.showsPlaybackControls = true

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
    }
}
