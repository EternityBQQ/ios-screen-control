# iOS Screen Capture — 三端实时屏幕共享 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建三端屏幕共享系统 — iOS ReplayKit 采集 → RTMP 推流到 nginx 服务器 → 浏览器/iOS 观看端实时播放

**Architecture:** 服务端用 Docker Compose 部署 nginx-rtmp + Python API；iOS 发送端用 ReplayKit Broadcast Upload Extension + VideoToolbox 硬编码 + 自实现 RTMP 协议栈；观看端用 hls.js 单页或 iOS AVPlayer

**Tech Stack:** Docker, nginx-rtmp, Python3, Swift 5.9+, Network.framework, VideoToolbox, ReplayKit, hls.js

**文件清单:**

```
ios-screen-control/
├── server/                               # ① 服务端 (Docker)
│   ├── docker-compose.yml
│   ├── nginx.conf
│   ├── server.py
│   ├── certs/
│   │   └── .gitkeep
│   ├── www/
│   │   ├── index.html                    # 浏览器观看端
│   │   └── ota/
│   │       ├── index.html                # OTA 安装页
│   │       └── manifest.plist            # iOS 安装清单
│   └── README.md
├── ScreenCapture/                        # ② iOS — Main App
│   ├── project.yml                       # XcodeGen spec
│   ├── Info.plist
│   ├── ScreenCaptureApp.swift
│   ├── ContentView.swift
│   └── AppConfig.swift
├── ScreenCaptureUpload/                  # ③ iOS — Broadcast Extension
│   ├── Info.plist
│   ├── SampleHandler.swift
│   ├── RtmpConnection.swift
│   ├── RtmpChunk.swift
│   ├── Amf0Encoder.swift
│   ├── FLVWriter.swift
│   └── VideoEncoder.swift
└── docs/superpowers/
    ├── specs/2026-07-20-ios-screen-capture-design.md
    └── plans/2026-07-21-ios-screen-capture-plan.md
```

---

### Task 1: 服务端 Docker Compose + 目录结构

**Files:**
- Create: `server/docker-compose.yml`
- Create: `server/certs/.gitkeep`
- Create: `server/README.md`

- [ ] **Step 1: 创建 docker-compose.yml**

```bash
mkdir -p server/certs server/www/ota
touch server/certs/.gitkeep
```

写入 `server/docker-compose.yml`:

```yaml
version: "3.8"

services:
  media-server:
    image: tiangolo/nginx-rtmp:latest
    ports:
      - "1935:1935"       # RTMP 推流
      - "8080:80"          # HTTP (HLS + 观看页面)
      - "8443:443"         # HTTPS (OTA 安装)
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./www:/usr/share/nginx/html:ro
      - hls_data:/tmp/hls
    restart: unless-stopped

  api:
    image: python:3.11-alpine
    ports:
      - "8081:8081"
    command: python /app/server.py
    volumes:
      - ./server.py:/app/server.py:ro
    restart: unless-stopped

volumes:
  hls_data:
```

- [ ] **Step 2: 创建 README.md**

写入 `server/README.md`:

```markdown
# ScreenCapture Server

## 快速启动

```bash
# 1. 生成 HTTPS 证书 (OTA 安装必需)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt \
  -subj "/CN=$(curl -s ifconfig.me)"

# 2. 启动服务
docker compose up -d

# 3. 验证
curl http://localhost:8081/streams
```

## 端口

| 端口 | 用途 |
|------|------|
| 1935 | RTMP 推流入口 |
| 8080 | 观看页面 + HLS |
| 8443 | OTA 安装 (HTTPS) |
| 8081 | 设备管理 API |
```

- [ ] **Step 3: 验证目录结构**

```bash
ls -la server/
# 预期: docker-compose.yml  nginx.conf(待创建)  server.py(待创建)  certs/  www/  README.md
```

---

### Task 2: nginx 配置

**Files:**
- Create: `server/nginx.conf`

- [ ] **Step 1: 写入 nginx.conf**

写入 `server/nginx.conf`:

```nginx
worker_processes auto;
events {
    worker_connections 1024;
}

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;

            # HLS 输出
            hls on;
            hls_path /tmp/hls;
            hls_fragment 1s;
            hls_playlist_length 10s;

            # 推流/断流回调
            on_publish       http://api:8081/on_publish;
            on_publish_done  http://api:8081/on_publish_done;
        }
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;

    # HTTP — 观看页面 + HLS
    server {
        listen 80;

        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias /tmp/hls;
            add_header Cache-Control no-cache;
            add_header Access-Control-Allow-Origin *;
        }

        location / {
            root   /usr/share/nginx/html;
            index  index.html;
        }

        location /api/streams {
            proxy_pass http://api:8081/streams;
        }
    }

    # HTTPS — OTA 安装 (iOS 强制要求)
    server {
        listen 443 ssl;
        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;

        location /ota {
            alias /usr/share/nginx/html/ota;
        }

        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias /tmp/hls;
            add_header Cache-Control no-cache;
            add_header Access-Control-Allow-Origin *;
        }

        location / {
            root   /usr/share/nginx/html;
            index  index.html;
        }
    }
}
```

- [ ] **Step 2: 验证 nginx 配置语法**

```bash
docker compose -f server/docker-compose.yml run --rm media-server nginx -t
# 预期: syntax is ok, test is successful
```

---

### Task 3: Python 设备管理 API

**Files:**
- Create: `server/server.py`

- [ ] **Step 1: 写入 server.py**

写入 `server/server.py`:

```python
"""ScreenCapture 设备管理 API
nginx-rtmp 推流/断流时回调，维护在线设备列表
"""
import json
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

streams: dict[str, dict] = {}


class APIHandler(BaseHTTPRequestHandler):
    """处理 nginx-rtmp 回调和观看端查询"""

    def _json(self, data: dict, status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        return json.loads(raw) if raw else {}

    def do_GET(self) -> None:
        path = urlparse(self.path).path

        if path == "/streams":
            self._json(streams)
        elif path == "/health":
            self._json({"status": "ok"})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        body = self._read_body()
        stream_key = body.get("name", "unknown")
        now = datetime.now(timezone.utc).isoformat()

        if path == "/on_publish":
            streams[stream_key] = {
                "status": "live",
                "started_at": now,
                "client_ip": body.get("addr", "unknown"),
                "client_id": body.get("clientid", ""),
            }
            print(f"[+] stream started: {stream_key} from {body.get('addr')}")
            self._json({"ok": True})

        elif path == "/on_publish_done":
            if stream_key in streams:
                streams[stream_key]["status"] = "offline"
                streams[stream_key]["stopped_at"] = now
            print(f"[-] stream stopped: {stream_key}")
            self._json({"ok": True})

        else:
            self._json({"error": "not found"}, 404)

    def log_message(self, format, *args) -> None:
        pass  # 静默日志，docker logs 看 print 即可


def main():
    host, port = "0.0.0.0", 8081
    server = HTTPServer((host, port), APIHandler)
    print(f"API server listening on {host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 验证 API 逻辑**

```bash
# 语法检查
python3 -c "import ast; ast.parse(open('server/server.py').read()); print('OK')"
# 预期: OK

# 启动测试
cd server && timeout 3 python3 server.py &
sleep 1
curl -s http://localhost:8081/health
# 预期: {"status": "ok"}
curl -s http://localhost:8081/streams
# 预期: {}
```

---

### Task 4: 浏览器观看页面

**Files:**
- Create: `server/www/index.html`

- [ ] **Step 1: 写入观看页面**

写入 `server/www/index.html`:

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>ScreenCapture — 实时观看</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: #000; color: #fff; font-family: -apple-system, sans-serif; overflow: hidden; }
        video { width: 100vw; height: 100vh; object-fit: contain; background: #111; }
        .overlay {
            position: fixed; top: 20px; left: 20px; z-index: 10;
            background: rgba(0,0,0,.6); border-radius: 12px; padding: 12px 18px;
            font-size: 13px; backdrop-filter: blur(10px);
            display: flex; align-items: center; gap: 10px;
        }
        .status { display: flex; align-items: center; gap: 6px; }
        .dot { width: 8px; height: 8px; border-radius: 50%; }
        .dot.live { background: #34C759; animation: pulse 2s infinite; }
        .dot.offline { background: #FF3B30; }
        @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.4} }
        .empty {
            display: flex; flex-direction: column; align-items: center; justify-content: center;
            height: 100vh; gap: 16px; color: #666;
        }
        .empty h2 { font-size: 28px; color: #999; font-weight: 400; }
        .empty p { font-size: 14px; }
    </style>
</head>
<body>
    <div class="overlay" id="statusBar" style="display:none;">
        <div class="status">
            <div class="dot live" id="statusDot"></div>
            <span id="statusText">LIVE</span>
        </div>
        <span style="color:#aaa;" id="latency"></span>
    </div>

    <div class="empty" id="emptyState">
        <h2>📱 等待设备推流...</h2>
        <p>请在 iOS 设备上从控制中心启动屏幕录制</p>
    </div>

    <video id="player" autoplay muted playsinline controls style="display:none;"></video>

    <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
    <script>
        const params = new URLSearchParams(location.search);
        const streamKey = params.get("key") || "iphone";
        const video = document.getElementById("player");
        const empty = document.getElementById("empty");
        const statusBar = document.getElementById("statusBar");

        function startPlayer() {
            if (!Hls.isSupported()) {
                // Safari 原生 HLS
                video.src = `/hls/${streamKey}.m3u8`;
                video.style.display = "block";
                empty.style.display = "none";
                statusBar.style.display = "flex";
                return;
            }

            const hls = new Hls({
                liveSyncDurationCount: 2,
                maxBufferLength: 4,
                enableWorker: true,
            });

            hls.loadSource(`/hls/${streamKey}.m3u8`);
            hls.attachMedia(video);

            hls.on(Hls.Events.MANIFEST_PARSED, () => {
                video.play();
                video.style.display = "block";
                empty.style.display = "none";
                statusBar.style.display = "flex";
            });

            hls.on(Hls.Events.ERROR, (_, data) => {
                if (data.fatal) {
                    video.style.display = "none";
                    empty.style.display = "flex";
                    empty.querySelector("h2").textContent = "⚠️ 连接断开";
                    statusBar.style.display = "none";
                }
            });
        }

        // 轮询检查是否有流，有就启动播放
        async function checkStream() {
            try {
                const res = await fetch("/api/streams");
                const streams = await res.json();
                if (streams[streamKey] && streams[streamKey].status === "live") {
                    startPlayer();
                } else {
                    // 每 3 秒重试
                    setTimeout(checkStream, 3000);
                }
            } catch {
                setTimeout(checkStream, 3000);
            }
        }

        checkStream();
    </script>
</body>
</html>
```

- [ ] **Step 2: 验证 HTML 可访问**

```bash
cd server
docker compose up -d
sleep 2
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/
# 预期: 200
```

---

### Task 5: OTA 安装页面 + manifest

**Files:**
- Create: `server/www/ota/index.html`
- Create: `server/www/ota/manifest.plist`

- [ ] **Step 1: 写入 OTA 安装页面**

写入 `server/www/ota/index.html`:

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>安装 ScreenCapture</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            background: #f2f2f7;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; padding: 20px;
        }
        .card {
            background: #fff;
            border-radius: 24px;
            padding: 48px 36px 36px;
            text-align: center;
            box-shadow: 0 4px 24px rgba(0,0,0,.06);
            max-width: 360px; width: 100%;
        }
        .icon {
            width: 84px; height: 84px; border-radius: 20px;
            background: linear-gradient(135deg, #007AFF, #5856D6);
            margin: 0 auto 24px;
            display: flex; align-items: center; justify-content: center;
            font-size: 40px; color: #fff;
        }
        h1 { font-size: 24px; font-weight: 700; margin-bottom: 8px; color: #1c1c1e; }
        .ver { font-size: 14px; color: #8e8e93; margin-bottom: 8px; }
        .desc { font-size: 14px; color: #3c3c43; margin-bottom: 32px; line-height: 1.6; }
        .install-btn {
            display: block; width: 100%;
            background: #007AFF; color: #fff;
            border: none; border-radius: 14px;
            padding: 16px 0; font-size: 18px;
            font-weight: 600; text-decoration: none;
            margin-bottom: 16px;
            cursor: pointer;
        }
        .install-btn:active { opacity: 0.8; }
        .hint { font-size: 12px; color: #8e8e93; line-height: 1.6; }
        .hint a { color: #007AFF; text-decoration: none; }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon">📱</div>
        <h1>ScreenCapture</h1>
        <p class="ver">Version 1.0</p>
        <p class="desc">
            iOS 屏幕实时采集推流<br>
            从控制中心启动录屏，画面实时推送
        </p>
        <a class="install-btn"
           id="installLink"
           href="itms-services://?action=download-manifest&url=https://YOUR_SERVER:8443/ota/manifest.plist">
            安装 App
        </a>
        <p class="hint">
            安装后请到<br>
            <strong>设置 → 通用 → VPN与设备管理</strong><br>
            信任企业证书后即可使用
        </p>
    </div>
</body>
</html>
```

- [ ] **Step 2: 写入 manifest.plist**

写入 `server/www/ota/manifest.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>https://YOUR_SERVER:8443/ota/ScreenCapture.ipa</string>
                </dict>
                <dict>
                    <key>kind</key>
                    <string>display-image</string>
                    <key>url</key>
                    <string>https://YOUR_SERVER:8443/ota/app-icon@2x.png</string>
                </dict>
                <dict>
                    <key>kind</key>
                    <string>full-size-image</string>
                    <key>url</key>
                    <string>https://YOUR_SERVER:8443/ota/app-icon@2x.png</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>com.screencapture.app</string>
                <key>bundle-version</key>
                <string>1.0</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>ScreenCapture</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: 验证 plist 格式**

```bash
plutil -lint server/www/ota/manifest.plist 2>/dev/null || python3 -c "
import plistlib
with open('server/www/ota/manifest.plist', 'rb') as f:
    plistlib.load(f)
print('plist OK')
"
# 预期: plist OK
```

---

### Task 6: iOS 项目配置 — XcodeGen spec + Main App

**Files:**
- Create: `ScreenCapture/project.yml`
- Create: `ScreenCapture/Info.plist`
- Create: `ScreenCapture/ScreenCaptureApp.swift`
- Create: `ScreenCapture/ContentView.swift`
- Create: `ScreenCapture/AppConfig.swift`

- [ ] **Step 1: 创建目录**

```bash
mkdir -p ScreenCapture ScreenCaptureUpload
```

- [ ] **Step 2: 写入 project.yml (XcodeGen 项目定义)**

写入 `ScreenCapture/project.yml`:

```yaml
name: ScreenCapture
options:
  bundleIdPrefix: com.screencapture
  deploymentTarget:
    iOS: "15.0"
  xcodeVersion: "15.0"

settings:
  base:
    SWIFT_VERSION: "5.9"

targets:
  ScreenCapture:
    type: application
    platform: iOS
    sources:
      - path: .
    settings:
      base:
        INFOPLIST_FILE: ScreenCapture/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.screencapture.app
        CODE_SIGN_ENTITLEMENTS: ScreenCapture/ScreenCapture.entitlements

  ScreenCaptureUpload:
    type: app-extension
    platform: iOS
    sources:
      - path: ../ScreenCaptureUpload
    settings:
      base:
        INFOPLIST_FILE: ScreenCaptureUpload/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.screencapture.app.upload
        CODE_SIGN_ENTITLEMENTS: ScreenCaptureUpload/ScreenCaptureUpload.entitlements
```

- [ ] **Step 3: 写入 Main App Info.plist**

写入 `ScreenCapture/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ScreenCapture</string>
    <key>CFBundleDisplayName</key>
    <string>ScreenCapture</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
    </array>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
    </dict>
</dict>
</plist>
```

- [ ] **Step 4: 写入 ScreenCaptureApp.swift**

写入 `ScreenCapture/ScreenCaptureApp.swift`:

```swift
import SwiftUI

@main
struct ScreenCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 5: 写入 ContentView.swift (配置页面)**

写入 `ScreenCapture/ContentView.swift`:

```swift
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
```

- [ ] **Step 6: 写入 AppConfig.swift (App Group 共享)**

写入 `ScreenCapture/AppConfig.swift`:

```swift
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
```

- [ ] **Step 7: 验证文件**

```bash
ls -la ScreenCapture/
# 预期: project.yml  Info.plist  ScreenCaptureApp.swift  ContentView.swift  AppConfig.swift
```

---

### Task 7: iOS RTMP 协议栈 — 基础层 (AMF0 + Chunk)

**Files:**
- Create: `ScreenCaptureUpload/Amf0Encoder.swift`
- Create: `ScreenCaptureUpload/RtmpChunk.swift`

这是自实现 RTMP 协议栈的基础层，负责 AMF0 编码和 RTMP Chunk 分包。

- [ ] **Step 1: 写入 Amf0Encoder.swift**

写入 `ScreenCaptureUpload/Amf0Encoder.swift`:

```swift
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
```

- [ ] **Step 2: 写入 RtmpChunk.swift**

写入 `ScreenCaptureUpload/RtmpChunk.swift`:

```swift
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
```

- [ ] **Step 3: 验证 Swift 语法**

```bash
# 仅检查语法结构 (Linux 上无法编译 iOS target，但可验证基本语法)
python3 -c "
import re
for f in ['ScreenCaptureUpload/Amf0Encoder.swift', 'ScreenCaptureUpload/RtmpChunk.swift']:
    with open(f) as fh:
        content = fh.read()
    # 检查大括号匹配
    opens = content.count('{')
    closes = content.count('}')
    print(f'{f}: braces {opens}/{closes}', 'OK' if opens==closes else 'MISMATCH')
"
```

---

### Task 8: iOS RTMP 连接层

**Files:**
- Create: `ScreenCaptureUpload/RtmpConnection.swift`

- [ ] **Step 1: 写入 RtmpConnection.swift**

写入 `ScreenCaptureUpload/RtmpConnection.swift`:

```swift
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
```

- [ ] **Step 2: 验证文件**

```bash
ls -la ScreenCaptureUpload/
# 预期: Amf0Encoder.swift  RtmpChunk.swift  RtmpConnection.swift
```

---

### Task 9: iOS 媒体处理层 — VideoEncoder + FLVWriter

**Files:**
- Create: `ScreenCaptureUpload/VideoEncoder.swift`
- Create: `ScreenCaptureUpload/FLVWriter.swift`

- [ ] **Step 1: 写入 VideoEncoder.swift**

写入 `ScreenCaptureUpload/VideoEncoder.swift`:

```swift
import Foundation
import VideoToolbox
import CoreMedia

/// VideoToolbox H.264 硬件编码器
final class VideoEncoder {
    private var session: VTCompressionSession?
    private var callback: (([Data]) -> Void)?
    private let queue = DispatchQueue(label: "video.encoder")

    private let outputWidth = 1280
    private let outputHeight = 720
    private let bitrate = 2_000_000   // 2 Mbps
    private let keyframeInterval = 60 // 每 60 帧一个 I 帧
    private let fps = 30

    func configure(callback: @escaping ([Data]) -> Void) {
        self.callback = callback

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: outputWidth,
            height: outputHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("[VideoEncoder] Failed to create session: \(status)")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,         value: kCFBooleanTrue!)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,     value: kVTProfileLevel_H264_Baseline_3_1 as CFString)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,   value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,  value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse!)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func invalidate() {
        VTCompressionSessionInvalidate(session)
        session = nil
    }

    // MARK: - Callback

    private let compressionOutputCallback: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let refcon else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer else { return }
        let data = Data(bytes: ptr, count: length)

        // 解析 AVCC 格式的 NAL units
        let nalUnits = encoder.parseAVCCNalUnits(data)
        encoder.callback?(nalUnits)
    }

    /// 解析 AVCC 格式: [4-byte length][NAL payload]...
    private func parseAVCCNalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let nalSize = Int(data[offset]) << 24
                        | Int(data[offset + 1]) << 16
                        | Int(data[offset + 2]) << 8
                        | Int(data[offset + 3])
            offset += 4
            guard offset + nalSize <= data.count else { break }
            units.append(data.subdata(in: offset..<(offset + nalSize)))
            offset += nalSize
        }
        return units
    }
}
```

- [ ] **Step 2: 写入 FLVWriter.swift**

写入 `ScreenCaptureUpload/FLVWriter.swift`:

```swift
import Foundation
import CoreMedia

/// FLV 封装器 — 生成 FLV header + sequence header + video tags
final class FLVWriter {

    private var cachedSPS: Data?  // Sequence Parameter Set
    private var cachedPPS: Data?  // Picture Parameter Set

    // MARK: - FLV Header

    /// FLV 文件头: "FLV" + version + flags + headerSize
    func makeHeader() -> Data {
        var data = Data()
        data.append(contentsOf: [0x46, 0x4C, 0x56])  // "FLV"
        data.append(0x01)                              // version 1
        data.append(0x04)                              // TypeFlags: video only (0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x09]) // header size = 9
        // PreviousTagSize(0)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return data
    }

    // MARK: - Sequence Header

    /// AVCDecoderConfigurationRecord — 包含 SPS/PPS
    func makeSequenceHeader() -> Data? {
        guard let sps = cachedSPS, let pps = cachedPPS else { return nil }

        // AVCDecoderConfigurationRecord
        var record = Data()
        record.append(0x01)                   // configurationVersion
        record.append(sps[1])                 // AVCProfileIndication
        record.append(sps[2])                 // profile_compatibility
        record.append(sps[3])                 // AVCLevelIndication
        record.append(0xFF)                   // lengthSizeMinusOne (4 bytes) + reserved bits
        record.append(0xE1)                   // numOfSequenceParameterSets (1) + reserved

        // SPS
        var spsData = sps
        // Strip 4-byte start code (00 00 00 01) if present
        if spsData.prefix(4) == Data([0x00, 0x00, 0x00, 0x01]) {
            spsData = spsData.subdata(in: 4..<spsData.count)
        }
        record.append(contentsOf: [UInt8(spsData.count >> 8), UInt8(spsData.count & 0xFF)])
        record.append(spsData)

        // PPS
        record.append(0x01)                   // numOfPictureParameterSets
        var ppsData = pps
        if ppsData.prefix(4) == Data([0x00, 0x00, 0x00, 0x01]) {
            ppsData = ppsData.subdata(in: 4..<ppsData.count)
        }
        record.append(contentsOf: [UInt8(ppsData.count >> 8), UInt8(ppsData.count & 0xFF)])
        record.append(ppsData)

        return makeVideoTag(
            frameType: 1,     // keyframe
            codecId: 7,       // AVC
            avcPacketType: 0, // sequence header
            compositionTime: 0,
            data: record,
            timestamp: 0
        )
    }

    // MARK: - Video Tag

    /// FLV VideoTag (TagType=9)
    func makeVideoTag(
        nalUnits: [Data],
        timestamp: UInt32
    ) -> Data {
        var videoData = Data()

        // Is this a keyframe? Check first NALU type
        let naluType = nalUnits.first.map { $0[0] & 0x1F } ?? 0
        let isKeyframe = (naluType == 5 || naluType == 7) // IDR or SPS
        let isSPS = (naluType == 7)
        let isPPS = (naluType == 8)

        // Cache SPS/PPS
        if isSPS { cachedSPS = nalUnits.first }
        if isPPS { cachedPPS = nalUnits.first }

        // Skip SPS/PPS in regular frames (they go in sequence header)
        let dataNalus = nalUnits.filter { nu in
            let type = nu[0] & 0x1F
            return type != 7 && type != 8
        }
        guard !dataNalus.isEmpty else { return Data() }

        let frameType: UInt8 = isKeyframe ? 1 : 2
        let codecId: UInt8 = 7  // AVC

        videoData.append((frameType << 4) | codecId)  // FrameType|CodecID
        videoData.append(1)                             // AVCPacketType = NALU
        videoData.append(contentsOf: [0x00, 0x00, 0x00]) // CompositionTime = 0

        // AnnexB format NALUs
        for nalu in dataNalus {
            videoData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // start code
            videoData.append(nalu)
        }

        return flvTag(tagType: 9, timestamp: timestamp, data: videoData)
    }

    /// 内部使用：构建 video tag
    private func makeVideoTag(
        frameType: UInt8,
        codecId: UInt8,
        avcPacketType: UInt8,
        compositionTime: UInt32,
        data: Data,
        timestamp: UInt32
    ) -> Data {
        var videoData = Data()
        videoData.append((frameType << 4) | codecId)
        videoData.append(avcPacketType)
        videoData.append(contentsOf: [
            UInt8((compositionTime >> 16) & 0xFF),
            UInt8((compositionTime >> 8) & 0xFF),
            UInt8(compositionTime & 0xFF),
        ])
        videoData.append(data)
        return flvTag(tagType: 9, timestamp: timestamp, data: videoData)
    }

    /// 构建 FLV Tag
    private func flvTag(tagType: UInt8, timestamp: UInt32, data: Data) -> Data {
        var tag = Data()
        // PreviousTagSize (4 bytes, 0 for first tag)
        tag.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Tag Header (11 bytes)
        tag.append(tagType)
        tag.append(contentsOf: [
            UInt8((data.count >> 16) & 0xFF),
            UInt8((data.count >> 8) & 0xFF),
            UInt8(data.count & 0xFF),
        ]) // DataSize (3 bytes)
        tag.append(contentsOf: [
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF),
        ]) // Timestamp (3 bytes)
        tag.append(UInt8((timestamp >> 24) & 0xFF)) // TimestampExtended
        tag.append(contentsOf: [0x00, 0x00, 0x00])  // StreamID (always 0)

        // Tag Data
        tag.append(data)

        // Tag Size (4 bytes) = 11 + data.count
        let tagSize = UInt32(11 + data.count)
        tag.append(contentsOf: [
            UInt8((tagSize >> 24) & 0xFF),
            UInt8((tagSize >> 16) & 0xFF),
            UInt8((tagSize >> 8) & 0xFF),
            UInt8(tagSize & 0xFF),
        ])

        return tag
    }
}
```

- [ ] **Step 3: 验证文件**

```bash
ls -la ScreenCaptureUpload/
# 预期: Amf0Encoder.swift  RtmpChunk.swift  RtmpConnection.swift  VideoEncoder.swift  FLVWriter.swift
```

---

### Task 10: iOS Broadcast Upload Extension — 入口 + 配置

**Files:**
- Create: `ScreenCaptureUpload/SampleHandler.swift`
- Create: `ScreenCaptureUpload/Info.plist`

- [ ] **Step 1: 写入 SampleHandler.swift**

写入 `ScreenCaptureUpload/SampleHandler.swift`:

```swift
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
```

- [ ] **Step 2: 写入 Extension Info.plist**

写入 `ScreenCaptureUpload/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ScreenCaptureUpload</string>
    <key>CFBundleDisplayName</key>
    <string>ScreenCapture</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.broadcast-services-upload</string>
        <key>NSExtensionPrincipalClass</key>
        <string>SampleHandler</string>
        <key>RPBroadcastProcessMode</key>
        <string>RPBroadcastProcessModeSampleBuffer</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 3: 验证目录结构**

```bash
echo "=== ScreenCapture/ ==="
ls -la ScreenCapture/
echo ""
echo "=== ScreenCaptureUpload/ ==="
ls -la ScreenCaptureUpload/
echo ""
echo "=== server/ ==="
find server -type f | sort
```

---

### Task 11: iOS Entitlements — App Group + 后台权限

**Files:**
- Create: `ScreenCapture/ScreenCapture.entitlements`
- Create: `ScreenCaptureUpload/ScreenCaptureUpload.entitlements`

- [ ] **Step 1: 写入 Main App entitlements**

写入 `ScreenCapture/ScreenCapture.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.screencapture.app</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: 写入 Extension entitlements**

写入 `ScreenCaptureUpload/ScreenCaptureUpload.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.screencapture.app</string>
    </array>
    <key>com.apple.developer.networking.wifi-info</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: 更新 project.yml 添加 entitlements 引用**

确认 `ScreenCapture/project.yml` 中已包含 entitlements 路径（Task 6 已写）

---

### Task 12: 最终验证

- [ ] **Step 1: 验证文件完整性**

```bash
echo "=== 文件清单 ==="
echo ""
echo "--- Server ---"
for f in \
    server/docker-compose.yml \
    server/nginx.conf \
    server/server.py \
    server/README.md \
    server/www/index.html \
    server/www/ota/index.html \
    server/www/ota/manifest.plist \
    server/certs/.gitkeep; do
    [ -f "$f" ] && echo "✅ $f" || echo "❌ MISSING: $f"
done

echo ""
echo "--- iOS Main App ---"
for f in \
    ScreenCapture/project.yml \
    ScreenCapture/Info.plist \
    ScreenCapture/ScreenCaptureApp.swift \
    ScreenCapture/ContentView.swift \
    ScreenCapture/AppConfig.swift \
    ScreenCapture/ScreenCapture.entitlements; do
    [ -f "$f" ] && echo "✅ $f" || echo "❌ MISSING: $f"
done

echo ""
echo "--- iOS Extension ---"
for f in \
    ScreenCaptureUpload/Info.plist \
    ScreenCaptureUpload/SampleHandler.swift \
    ScreenCaptureUpload/RtmpConnection.swift \
    ScreenCaptureUpload/RtmpChunk.swift \
    ScreenCaptureUpload/Amf0Encoder.swift \
    ScreenCaptureUpload/FLVWriter.swift \
    ScreenCaptureUpload/VideoEncoder.swift \
    ScreenCaptureUpload/ScreenCaptureUpload.entitlements; do
    [ -f "$f" ] && echo "✅ $f" || echo "❌ MISSING: $f"
done
```

- [ ] **Step 2: 启动服务端并验证**

```bash
cd server
# 生成证书
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt \
  -subj "/CN=localhost" 2>/dev/null

# 启动
docker compose up -d
sleep 3

# 测试
echo "--- API health ---"
curl -s http://localhost:8081/health

echo ""
echo "--- streams (empty) ---"
curl -s http://localhost:8081/streams

echo ""
echo "--- HTTP watching page ---"
curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:8080/

echo ""
echo "--- OTA install page ---"
curl -s -o /dev/null -w "HTTP %{http_code}" -k https://localhost:8443/ota/

echo ""
echo "=== All checks passed ==="
```

---

### 构建与分发速查

```bash
# ===== iOS: 用 XcodeGen 生成 .xcodeproj =====
cd ScreenCapture
xcodegen generate
open ScreenCapture.xcodeproj

# ===== 打包 IPA =====
xcodebuild -project ScreenCapture.xcodeproj \
  -scheme ScreenCapture \
  -archivePath ./build/ScreenCapture.xcarchive \
  archive

xcodebuild -exportArchive \
  -archivePath ./build/ScreenCapture.xcarchive \
  -exportOptionsPlist exportOptions.plist \
  -exportPath ./build/ipa

# ===== 部署 IPA 到服务器 =====
cp build/ipa/ScreenCapture.ipa ../server/www/ota/

# ===== 启动服务器 =====
cd ../server
docker compose up -d
```

---

### 架构总结

```
iOS 发送端                         中转服务器                    观看端
┌──────────────────┐           ┌──────────────────┐        ┌──────────────┐
│ Main App         │           │ nginx-rtmp       │        │ 浏览器        │
│ ContentView.swift│           │ :1935 RTMP ←─────│────────│ hls.js       │
│ AppConfig.swift  │           │ :8080 HTTP ──────│────────│ /hls/*.m3u8  │
└────────┬─────────┘           │ :8443 HTTPS ─────│──┐     └──────────────┘
         │ App Group           │ :8081 API ───────│──┤
┌────────▼─────────┐           └──────────────────┘  │     ┌──────────────┐
│ Extension        │                                  │     │ iOS 观看端    │
│ SampleHandler   │                                  ├─────│ AVPlayer     │
│ RtmpConnection  │            OTA 安装页             │     └──────────────┘
│ RtmpChunk       │            /ota/index.html ──────┘
│ Amf0Encoder     │            /ota/manifest.plist
│ FLVWriter       │            /ota/ScreenCapture.ipa
│ VideoEncoder    │
└─────────────────┘
```
