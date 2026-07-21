# iOS Screen Capture — 三端实时屏幕共享系统 设计文档

> **日期**: 2026-07-20
> **状态**: Spec (待 Review)

## 1. 概述

构建一套三端实时屏幕共享系统：iOS 设备通过 ReplayKit 采集画面 → RTMP 推流到中转服务器 → iOS / 浏览器观看端实时播放。

### 核心需求

| 维度     | 决策                          |
| -------- | ----------------------------- |
| 采集方式 | ReplayKit Broadcast Upload Extension (系统级录屏) |
| 运行模式 | 独立 App + Extension，后台推送 |
| 音视频   | 纯视频，无音频               |
| 推流协议 | RTMP (自实现精简协议栈)       |
| 中转服务 | nginx-rtmp + HLS + HTTP API  |
| 观看端   | 浏览器 (hls.js) 或 iOS AVPlayer |
| 规模     | 精简实现，核心代码 ~900 行    |

---

## 2. 系统架构

```
┌──────────────────────┐
│  ① iOS 发送端        │
│  ScreenCapture App   │
│                      │
│  ┌─────────────────┐ │
│  │ Main App        │ │  ContentView (配置) + AppConfig (App Group)
│  │ (配置 RTMP URL) │ │
│  └────────┬────────┘ │
│           │App Group  │
│  ┌────────▼────────┐ │
│  │ Broadcast       │ │  ReplayKit → VideoToolbox → FLV → RTMP
│  │ Upload Ext      │ │  SampleHandler / RtmpConnection / VideoEncoder / FLVWriter
│  └────────┬────────┘ │
└───────────┼──────────┘
            │ RTMP (port 1935)
            ▼
┌──────────────────────┐
│  ② 中转服务器        │
│                      │
│  ┌─────────────────┐ │
│  │ nginx-rtmp      │ │  RTMP 接入 + HLS 输出
│  │ (端口 1935/8080)│ │  hls_fragment: 1s
│  └────────┬────────┘ │
│  ┌────────▼────────┐ │
│  │ Python API      │ │  设备注册 / 列表 / 回调
│  │ (端口 8081)     │ │
│  └─────────────────┘ │
│                      │
│  HLS .m3u8 ──────────┼──────────────┐
└──────────────────────┘              │
                                      │ HTTP
            ┌─────────────────────────┼───────────────┐
            │                         │               │
      ┌─────▼──────┐          ┌──────▼──────┐  ┌─────▼──────┐
      │ ③ 浏览器   │          │ ③ iOS 观看  │  │ ③ VLC     │
      │ hls.js     │          │ AVPlayer    │  │ ffplay     │
      │ 任何设备   │          │ iPhone/iPad │  │ 调试用    │
      └────────────┘          └─────────────┘  └────────────┘
```

---

## 3. 第一端：iOS 发送端

### 3.1 项目结构

```
ScreenCapture.xcodeproj
├── ScreenCapture/                     (Main App target)
│   ├── Info.plist
│   ├── ScreenCaptureApp.swift
│   ├── ContentView.swift              # RTMP URL 配置页面
│   └── AppConfig.swift                # App Group UserDefaults 封装
│
├── ScreenCaptureUpload/               (Broadcast Upload Extension target)
│   ├── Info.plist                     # com.apple.broadcast-upload
│   ├── SampleHandler.swift            # RPBroadcastSampleHandler 入口
│   ├── RtmpConnection.swift           # TCP + RTMP 协议栈
│   ├── RtmpChunk.swift                # RTMP Chunk 编解码
│   ├── Amf0Encoder.swift              # AMF0 序列化
│   ├── FLVWriter.swift                # FLV 封装 (header + video tags)
│   └── VideoEncoder.swift             # VideoToolbox H.264 硬编码
```

### 3.2 数据流路径

```
iOS 屏幕帧
  │
  ▼
ReplayKit.framework
  │ CMSampleBuffer (YUV/BGRA)
  ▼
VideoEncoder (VideoToolbox 硬编码)
  │ H.264 NAL Us (AVCC 格式)
  ▼
FLVWriter (FLV 封装)
  │ FLV Video Tags + Sequence Header
  ▼
RtmpConnection (RTMP 协议封装)
  │ RTMP Chunks over TCP
  ▼
远端 nginx-rtmp 服务器 (端口 1935)
```

### 3.3 文件职责

| 文件 | 行数 | 职责 |
|------|------|------|
| `SampleHandler.swift` | ~100 | 入口，接收 `broadcastStarted` / `processSampleBuffer` / `broadcastFinished`，协调整体流程 |
| `RtmpConnection.swift` | ~250 | TCP Socket (Network.framework)，RTMP Handshake (C0/C1/C2 ↔ S0/S1/S2)，AMF0 Command (connect/createStream/publish)，发送 Video Message |
| `RtmpChunk.swift` | ~100 | Chunk Basic Header + Message Header 编解码，分包 (128 bytes/chunk → 4096) |
| `Amf0Encoder.swift` | ~80 | AMF0 编码器：String, Number, Boolean, Object, Null |
| `FLVWriter.swift` | ~120 | FLV Header + onMetaData tag + Video Tag (AVCDecoderConfigurationRecord + NALUs) |
| `VideoEncoder.swift` | ~100 | VTCompressionSession 创建/配置/回调，输出 AVCC 格式 NAL units |
| `ContentView.swift` | ~80 | SwiftUI 界面：输入 RTMP URL，显示推流状态 |
| `AppConfig.swift` | ~40 | App Group UserDefaults 读写 RTMP URL |

### 3.4 编码参数

```
Codec:        H.264 Baseline
Profile:      Baseline 3.1
Resolution:   1280×720 (自适应屏幕比例)
Bitrate:      2 Mbps
Keyframe:     每 60 帧 (~2s 一个 I 帧)
RealTime:     true
```

### 3.5 App Group 配置

```
Group ID: group.com.screencapture.upload
Key:      rtmp_url  (String, e.g. "rtmp://192.168.1.100/live/iphone")
```

---

## 4. 第二端：中转服务器

### 4.1 项目结构

```
server/
├── docker-compose.yml       # 一键部署
├── nginx.conf               # RTMP + HLS + HTTP(S) 配置
├── server.py                # 设备管理 API (50行)
├── certs/                   # HTTPS 证书 (OTA 安装必需)
│   ├── server.crt
│   └── server.key
├── www/
│   ├── index.html           # 浏览器观看页面
│   └── ota/                 # iOS OTA 一键安装
│       ├── index.html       # 安装页面
│       ├── manifest.plist   # iOS 安装清单
│       ├── ScreenCapture.ipa
│       ├── app-icon.png
│       └── app-icon@2x.png
└── README.md                # 部署说明
```

### 4.2 服务端口

| 端口 | 服务 | 用途 |
|------|------|------|
| 1935 | RTMP | iOS 推流入口 |
| 8080 | HTTP | HLS 分发 + 观看页面 |
| 8443 | HTTPS | OTA 安装页面 + IPA 分发 (iOS 强制要求) |
| 8081 | HTTP API | 设备列表 / 推流回调 |

### 4.3 nginx 配置要点

```
rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;

            hls on;
            hls_path /tmp/hls;
            hls_fragment 1s;
            hls_playlist_length 10s;

            on_publish       http://api:8081/on_publish;
            on_publish_done  http://api:8081/on_publish_done;
        }
    }
}
```

### 4.4 API 说明

| 端点 | 方法 | 说明 |
|------|------|------|
| `/streams` | GET | 返回所有设备列表 `{streamKey: {status, started_at, client_ip}}` |
| `/on_publish` | POST | nginx 回调，标记设备上线 |
| `/on_publish_done` | POST | nginx 回调，标记设备离线 |
| `/hls/{streamKey}.m3u8` | GET | HLS 播放列表 (nginx 自动生成) |

---

## 5. 第三端：观看端

### 5.1 浏览器观看 (hls.js)

**URL**: `http://<server>:8080/?key=iphone`

- hls.js 自动解析 .m3u8
- 延迟 ~2-4 秒 (1s HLS 分片)
- 兼容 Chrome / Safari / Edge / 移动端浏览器
- 单 HTML 文件，零依赖部署

### 5.2 iOS 原生观看 (AVPlayer)

**URL**: `http://<server>:8080/hls/{streamKey}.m3u8`

```swift
// 另一台 iPhone / iPad 观看 — 仅需 3 行
import AVKit
let player = AVPlayer(url: URL(string: "http://server:8080/hls/iphone.m3u8")!)
// 嵌入 SwiftUI: VideoPlayer(player: player)
```

- AVPlayer 原生 HLS 支持
- 延迟 ~2-4 秒

### 5.3 VLC / ffplay (调试用)

**URL**: `rtmp://<server>/live/{streamKey}`

```bash
ffplay rtmp://192.168.1.100/live/iphone    # 延迟 ~1-2 秒
```

---

## 6. 完整使用方法

### Step 1: 启动服务器

```bash
cd server
docker compose up -d
# 验证: curl http://localhost:8081/streams
```

### Step 2: 一键安装 iOS App (OTA 分发)

#### 原理

iOS 支持 **OTA (Over-The-Air) 安装** — 用户在 iPhone Safari 打开一个网页，点击安装，App 直接装到桌面，和 App Store 下载体验完全一样。

```
iPhone Safari 打开 https://server/install
        │
        ▼
┌─────────────────────────────────┐
│  网页显示 App 信息 + 安装按钮   │
│  <a href="itms-services://      │
│    ?action=download-manifest     │
│    &url=https://server/manifest.plist">
│    安装 ScreenCapture           │
│  </a>                           │
└────────────┬────────────────────┘
             │ 点击
             ▼
┌─────────────────────────────────┐
│  iOS 系统下载 manifest.plist    │
│  读取 IPA 下载地址              │
│  → 弹出系统安装确认框          │
└────────────┬────────────────────┘
             │ 确认
             ▼
┌─────────────────────────────────┐
│  iOS 下载 IPA → 安装 → 桌面出现 │
│  ScreenCapture 图标             │
│  (就像从 App Store 装的一样)    │
└─────────────────────────────────┘
```

#### 签名方式选择

| 签名方案 | 设备限制 | 有效期 | 成本 | 适合 |
|----------|----------|--------|------|------|
| **个人开发者账号** | 最多 100 台 (需登记 UDID) | 1 年 | $99/年 | 自己和几个朋友 |
| **企业开发者账号** | 无限制 | 1 年 | $299/年 | 团队/组织内部 |
| **免费 Apple ID (7天)** | 自己的设备 | 7 天 | 免费 | 仅开发调试 |

#### 操作步骤

**第一步：获取签名证书**

```bash
# 方案 A: 个人开发者账号 ($99/年)
#   1. 注册: https://developer.apple.com
#   2. Xcode → Settings → Accounts → 登录你的 Apple ID
#   3. 自动生成证书

# 方案 B: 企业账号 ($299/年)
#   1. 注册 Apple Developer Enterprise Program
#   2. 同样在 Xcode 中登录即可
```

**第二步：登记目标设备 UDID（仅个人账号需要）**

```bash
# 1. iPhone 连接 Mac，在 Finder 中点击序列号显示 UDID
#    或访问: https://udid.io 在 iPhone Safari 中打开一键获取
# 2. 登录 https://developer.apple.com/account/resources/devices
# 3. 添加设备 → 输入 UDID 和名称
# 最多 100 台
```

**第三步：打包 IPA**

```bash
# Xcode Archive → 企业/Ad-Hoc 导出

# 或命令行:
xcodebuild -project ScreenCapture.xcodeproj \
  -scheme ScreenCapture \
  -archivePath ./build/ScreenCapture.xcarchive \
  archive

# 创建 exportOptions.plist:
cat > exportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>enterprise</string>  <!-- 企业账号 -->
    <!-- <string>ad-hoc</string> 个人账号用这个 -->
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath ./build/ScreenCapture.xcarchive \
  -exportOptionsPlist exportOptions.plist \
  -exportPath ./build/ipa

# 得到: ./build/ipa/ScreenCapture.ipa
```

**第四步：部署到服务器**

把 IPA 和安装页面直接放到我们的中转服务器上：

```bash
# 服务器端操作
mkdir -p server/www/ota

# 上传这些文件到服务器:
# ├── server/www/ota/
# │   ├── ScreenCapture.ipa          # 你的 App
# │   ├── manifest.plist             # iOS 安装清单
# │   ├── index.html                 # 安装页面
# │   ├── app-icon.png               # 应用图标 (57x57)
# │   └── app-icon@2x.png            # 应用图标 (114x114)

cat > server/www/ota/manifest.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
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
                    <string>https://your-server.com/ota/ScreenCapture.ipa</string>
                </dict>
                <dict>
                    <key>kind</key>
                    <string>display-image</string>
                    <key>url</key>
                    <string>https://your-server.com/ota/app-icon@2x.png</string>
                </dict>
                <dict>
                    <key>kind</key>
                    <string>full-size-image</string>
                    <key>url</key>
                    <string>https://your-server.com/ota/app-icon@2x.png</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>com.screencapture.app</string>
                <key>bundle-version</key>
                <string>1.0</string>
                <key>title</key>
                <string>ScreenCapture</string>
                <key>kind</key>
                <string>software</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF
```

**第五步：安装页面 (服务器上)**

```html
<!-- server/www/ota/index.html -->
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>安装 ScreenCapture</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, sans-serif;
            background: #f5f5f7;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh;
        }
        .card {
            background: white;
            border-radius: 20px;
            padding: 40px;
            text-align: center;
            box-shadow: 0 20px 60px rgba(0,0,0,.1);
            max-width: 360px;
            width: 90%;
        }
        .icon { width: 80px; height: 80px; border-radius: 18px; margin-bottom: 20px; }
        h1 { font-size: 22px; margin-bottom: 8px; }
        p { color: #666; font-size: 14px; margin-bottom: 30px; line-height: 1.6; }
        .btn {
            display: inline-block;
            background: #007AFF;
            color: white;
            border: none;
            border-radius: 12px;
            padding: 16px 48px;
            font-size: 18px;
            text-decoration: none;
            font-weight: 600;
        }
        .note { margin-top: 24px; font-size: 12px; color: #999; }
    </style>
</head>
<body>
    <div class="card">
        <img class="icon" src="app-icon@2x.png" alt="icon">
        <h1>ScreenCapture</h1>
        <p>iOS 屏幕实时采集推流工具<br>安装后从控制中心启动录屏</p>
        <a class="btn"
           href="itms-services://?action=download-manifest&url=https://your-server.com/ota/manifest.plist">
            安装 App
        </a>
        <p class="note">
            安装后请到 设置 → 通用 → VPN与设备管理<br>信任企业证书即可使用
        </p>
    </div>
</body>
</html>
```

#### 用户安装流程

```
用户只需 3 步:

1. iPhone Safari 打开 https://your-server.com/ota
2. 点 "安装 App" 按钮
3. 桌面出现 ScreenCapture → 首次信任证书即可

体验等同于 App Store 安装，就是标准的"安装包"方式。
```

#### HTTPS 要求

OTA 安装要求 `manifest.plist` 和 `.ipa` 必须通过 **HTTPS** 访问。给 nginx 加上自签名证书：

```nginx
# 在 nginx.conf http 段添加:
server {
    listen 443 ssl;
    server_name your-server.com;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;

    location /ota {
        alias /usr/share/nginx/html/ota;
        add_header Content-Disposition attachment;
    }
}
```

```bash
# 生成自签名证书 (或使用 Let's Encrypt 免费证书)
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout server/certs/server.key \
  -out server/certs/server.crt \
  -subj "/CN=your-server.com"
```

#### 安装后配置

```
1. 信任证书: 设置 → 通用 → VPN与设备管理 → 信任
2. 打开 ScreenCapture App
3. 输入 RTMP URL: rtmp://<server-ip>/live/iphone
4. 设置 → 控制中心 → 确保"屏幕录制"已添加
```

### Step 3: 开始推流

```
1. 下拉控制中心
2. 长按录屏按钮
3. 选择 "ScreenCapture" Extension
4. 点击"开始广播"
```

### Step 4: 观看端

```
浏览器: http://<server-ip>:8080/?key=iphone
iOS:    AVPlayer 加载 http://<server-ip>:8080/hls/iphone.m3u8
调试:   ffplay rtmp://<server-ip>/live/iphone
```

---

## 7. 限制与边界

| 限制 | 说明 |
|------|------|
| Extension 内存 | Broadcast Upload Extension 限 50MB，自实现 RTMP 栈确保不超 |
| 编码延迟 | VideoToolbox 硬编码 + HLS 分段，端到端延迟 ~2-4 秒 |
| 网络要求 | 上行带宽 ≥ 3 Mbps (2M 视频码率 + 协议开销) |
| iOS 版本 | iOS 12.0+ (ReplayKit Broadcast Extension) |
| 单路推流 | 当前设计支持单路；nginx-rtmp 天然支持多路，扩展需在 App 端增加多 streamKey 管理 |
| 安全性 | 无鉴权，任何知道 RTMP URL 的人可推流/拉流；可后续加 token 验证 |

---

## 8. 自检清单

- [x] 无 TBD / TODO 占位符
- [x] 三端职责清晰，无模糊边界
- [x] 架构数据流图完整
- [x] 文件清单与行数估计
- [x] 部署步骤可执行
- [x] 限制与边界已声明
