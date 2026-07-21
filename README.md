# ScreenCapture — iOS 三端实时屏幕共享

iOS 设备通过 ReplayKit 采集屏幕 → RTMP 推流到本机中转服务器 → 浏览器 / iOS 观看端实时播放。

```
                        ┌─ 本机 Docker ─┐
iOS 发送端 ──RTMP(:1935)─→│ nginx-rtmp    │──HLS──→ 浏览器 / iOS 观看端
                        │ Python API    │
                        └───────────────┘
```

---

## 目录

- [快速开始](#快速开始)
- [一、服务端部署（Docker 本机环境）](#一服务端部署docker-本机环境)
- [二、iOS 客户端构建与打包](#二ios-客户端构建与打包)
- [三、客户端安装到 iPhone](#三客户端安装到-iphone)
- [四、开始推流](#四开始推流)
- [五、观看端](#五观看端)
- [项目结构](#项目结构)
- [架构说明](#架构说明)
- [API 文档](#api-文档)
- [常见问题](#常见问题)

---

## 快速开始

### 前提

- **服务端**：一台 Linux/macOS 机器，安装 Docker
- **客户端**：一台 Mac（用于打包 iOS App）+ 一台 iPhone
- **网络**：iPhone 和服务端在同一局域网

### 三步跑通

```bash
# 1. 部署服务器 (本机)
bash deploy.sh

# 2. Mac 上编译打包 iOS App (见第二部分)
# ... 在 Xcode 中 Archive → Export IPA

# 3. 把 IPA 放到 server/www/ota/，iPhone Safari 打开安装
```

---

## 一、服务端部署（Docker 本机环境）

### 1.1 环境要求

服务端运行在你的 **本机**（Linux 或 macOS）上，通过 Docker 容器化部署。

| 依赖 | 版本要求 | 安装方式 |
|------|----------|----------|
| Docker | 20.10+ | `curl -fsSL https://get.docker.com \| bash` |
| Docker Compose | v2+ | Docker Desktop 自带，或 `apt install docker-compose-plugin` |
| openssl | 任意 | 系统自带 |

### 1.2 一键部署

```bash
cd ios-screen-control
bash deploy.sh
```

脚本执行内容：

```
1/5 检查 Docker + Compose 是否安装
2/5 自动生成 HTTPS 自签名证书 → server/certs/
3/5 写入 docker-compose.yml (端口可自定义)
4/5 创建 hls / ota 静态文件目录
5/5 拉取镜像 → 启动容器 → 健康检查 → 输出全部访问地址
```

### 1.3 自定义端口

```bash
# 默认端口: HTTP 8082, HTTPS 8444, RTMP 1935, API 8081
bash deploy.sh

# 自定义端口:
HTTP_PORT=80 HTTPS_PORT=443 RTMP_PORT=1935 bash deploy.sh

# 指定本机 IP (多网卡时):
SERVER_IP=192.168.1.100 bash deploy.sh
```

### 1.4 手动部署（不用脚本）

```bash
cd server

# 生成证书
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt \
  -subj "/CN=$(hostname -I | awk '{print $1}')"

# 启动
docker compose up -d

# 验证
curl http://localhost:8081/health
# → {"status": "ok"}
```

### 1.5 服务端口一览

| 端口 | 协议 | 服务 | 用途 |
|------|------|------|------|
| 1935 | TCP | RTMP | iOS 推流入口 |
| 8082 | HTTP | nginx | HLS 分发 + 浏览器观看页面 |
| 8444 | HTTPS | nginx | OTA 安装页面 (iOS 强制 HTTPS) |
| 8081 | HTTP | Python | 设备管理 API + 推流回调 |

### 1.6 日常管理

```bash
cd server

# 查看日志
docker compose logs -f

# 重启
docker compose restart

# 停止
docker compose down

# 完全清理（删除 HLS 缓存）
docker compose down -v
```

---

## 二、iOS 客户端构建与打包

> **以下所有操作在 Mac 上执行。** 需要 Xcode 15+ 和 Apple ID。

### 2.1 环境准备 (只需一次)

```bash
# 1. 安装 Xcode (App Store 或 https://developer.apple.com)
#    打开一次 Xcode 完成组件安装

# 2. 安装 XcodeGen (项目生成工具)
brew install xcodegen

# 3. 安装 Xcode Command Line Tools
xcode-select --install

# 4. 登录 Apple ID
#    Xcode → Settings → Accounts → 点 + → 登录你的 Apple ID
#    免费账号即可开发和真机调试（7天签名有效期）
```

### 2.2 Apple 开发者账号选择

打包 IPA 需要签名，三种方案：

| 方案 | 年费 | 签名有效期 | 安装设备数 | 适用场景 |
|------|------|------------|------------|----------|
| **A. 免费 Apple ID** | 免费 | 7 天 | 自己的设备 | 个人开发调试 |
| **B. 个人开发者** | $99 | 1 年 | 最多 100 台 | 自己和朋友使用（推荐） |
| **C. 企业开发者** | $299 | 1 年 | 不限 | 组织内部批量分发 |

> **方案 A** 最简单，每 7 天在 Mac 上重签一次即可。**方案 B** 性价比最高，100 台设备够用一年。

### 2.3 生成 Xcode 项目

```bash
cd ios-screen-control/ScreenCapture

# 用 XcodeGen 根据 project.yml 生成 .xcodeproj
xcodegen generate

# 打开项目
open ScreenCapture.xcodeproj
```

### 2.4 配置 Bundle ID 和签名

在 Xcode 中分别对两个 Target 配置：

```
┌─ Xcode 左侧选中 ScreenCapture (Main App) ──────────────────┐
│                                                              │
│  Signing & Capabilities 标签：                               │
│  ┌──────────────────────────────────────────────────────────┐│
│  │ ☑ Automatically manage signing                          ││
│  │ Team: [你的 Apple ID / 开发者账号]                        ││
│  │ Bundle Identifier: com.screencapture.app                 ││
│  │                                                          ││
│  │ App Groups: (点 + 号添加)                                ││
│  │   group.com.screencapture.app                            ││
│  └──────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘

┌─ Xcode 左侧选中 ScreenCaptureUpload (Extension) ────────────┐
│                                                              │
│  Signing & Capabilities 标签：                               │
│  ┌──────────────────────────────────────────────────────────┐│
│  │ ☑ Automatically manage signing                          ││
│  │ Team: [同上]                                              ││
│  │ Bundle Identifier: com.screencapture.app.upload           ││
│  │                                                          ││
│  │ App Groups: (点 + 号添加)                                ││
│  │   group.com.screencapture.app  ← 和 Main App 选同一个    ││
│  └──────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘
```

> **注意**：App Group 需要在 Apple Developer 网站先创建。
> 登录 [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles → App Groups → 点 `+` → 创建 `group.com.screencapture.app`

### 2.5 编译到真机测试

```bash
# 1. iPhone 用数据线连接 Mac
# 2. 在 Xcode 顶部选择设备: ScreenCapture > [你的 iPhone]
# 3. Cmd+R 编译并安装

# 首次安装后，iPhone 上需要信任证书:
# 设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → 信任
```

可以在 Xcode 中实时查看 Extension 日志：`Window → Devices and Simulators → 选中设备 → Open Console`，搜索 `SampleHandler`

### 2.6 打包 IPA（Archive + Export）

完整打包流程：

**Step 1: 创建 exportOptions.plist**

在 `ScreenCapture/` 目录下创建签名配置：

```bash
cd ios-screen-control/ScreenCapture
```

```xml
<!-- exportOptions.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <!-- 企业账号用 enterprise，个人账号用 ad-hoc，免费账号用 development -->
    <string>ad-hoc</string>
    <key>teamID</key>
    <!-- 替换为你的 Team ID，在 https://developer.apple.com/account 查看 -->
    <string>YOUR_TEAM_ID</string>
    <key>compileBitcode</key>
    <false/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
```

**Step 2: Archive**

```bash
xcodebuild -project ScreenCapture.xcodeproj \
  -scheme ScreenCapture \
  -configuration Release \
  -archivePath ./build/ScreenCapture.xcarchive \
  archive
```

成功后输出：
```
** ARCHIVE SUCCEEDED **
```

**Step 3: Export IPA**

```bash
xcodebuild -exportArchive \
  -archivePath ./build/ScreenCapture.xcarchive \
  -exportOptionsPlist exportOptions.plist \
  -exportPath ./build/ipa
```

成功后输出：
```
** EXPORT SUCCEEDED **
```

产物在 `build/ipa/ScreenCapture.ipa`

**Step 4: 验证 IPA**

```bash
ls -lh build/ipa/ScreenCapture.ipa
# 预期: ~3-5 MB

# 查看 IPA 内容 (可选)
unzip -l build/ipa/ScreenCapture.ipa | head -20
```

### 2.7 一键打包脚本 (可选)

在 Mac 上创建 `build.sh`：

```bash
#!/usr/bin/env bash
# iOS ScreenCapture 一键打包脚本 (在 Mac 上运行)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/ScreenCapture"

echo "=== 1. 生成 Xcode 项目 ==="
cd "$PROJECT_DIR"
xcodegen generate

echo ""
echo "=== 2. Archive ==="
xcodebuild -project ScreenCapture.xcodeproj \
  -scheme ScreenCapture \
  -configuration Release \
  -archivePath ./build/ScreenCapture.xcarchive \
  archive

echo ""
echo "=== 3. Export IPA ==="
xcodebuild -exportArchive \
  -archivePath ./build/ScreenCapture.xcarchive \
  -exportOptionsPlist exportOptions.plist \
  -exportPath ./build/ipa

echo ""
echo "=== 4. 产物 ==="
ls -lh build/ipa/ScreenCapture.ipa

echo ""
echo "✅ 打包完成"
echo "IPA 路径: $PROJECT_DIR/build/ipa/ScreenCapture.ipa"
echo ""
echo "下一步: 将 IPA 复制到服务器的 server/www/ota/ 目录"
echo "  scp build/ipa/ScreenCapture.ipa user@server:ios-screen-control/server/www/ota/"
```

### 2.8 构建原生 iOS 观看端 (ScreenViewer)

原生 iOS 观看 App。**零输入**：扫码连接服务器 → 自动发现推流设备 → 点选即播。

#### 工作原理

```
服务器网页显示二维码 → ScreenViewer 扫码获取地址 → 查询 API 获取设备列表 → 点设备全屏播放
```

#### 生成项目

```bash
cd ios-screen-control/ScreenViewer
xcodegen generate
open ScreenViewer.xcodeproj
```

#### 配置签名

```
Xcode → 选中 ScreenViewer target → Signing & Capabilities:
  Team: [你的 Apple ID]
  Bundle Identifier: com.screencapture.viewer
  (不需要 App Group，不需要特殊权限)
```

#### 编译安装

```
iPhone 连 Mac → Cmd+R → 自动安装
```

#### 首次使用

```
1. 打开 ScreenViewer App
2. 点「扫描二维码连接服务器」
3. 对准服务器网页上的二维码 (http://服务器IP:8082)
4. 扫描成功 → 自动显示推流设备列表
5. 点设备 → 全屏播放
```

之后就无需再扫码，每次打开 App 自动拉取设备列表。

> ScreenViewer 使用 AVPlayer 原生 HLS 播放，延迟 ~2-4 秒。

---

## 三、客户端安装到 iPhone

### 3.1 方式 A: OTA 一键安装（推荐）

把 IPA 放到服务器上，iPhone 打开网页点一下即装，跟 App Store 体验一样。

**第一步：部署 IPA 到服务器**

```bash
# 在 Mac 上，把 IPA 传到服务器
scp ScreenCapture/build/ipa/ScreenCapture.ipa \
  user@your-server:~/ios-screen-control/server/www/ota/

# 或者直接复制（如果服务器就是本机）
cp ScreenCapture/build/ipa/ScreenCapture.ipa \
  server/www/ota/
```

**第二步：修改 OTA 配置中的服务器地址**

```bash
# 在服务器上，替换 index.html 和 manifest.plist 中的 YOUR_SERVER
cd server/www/ota

# 查看本机 IP
hostname -I | awk '{print $1}'
# 假设输出: 192.168.1.100

# 替换 YOUR_SERVER 为实际 IP
sed -i 's/YOUR_SERVER/192.168.1.100/g' index.html manifest.plist
```

**第三步：iPhone Safari 安装**

```
1. iPhone Safari 打开: https://192.168.1.100:8444/ota/
   (第一次访问会有证书警告 → 点 "继续访问")

2. 看到安装页面 → 点 "安装 App"

3. iOS 弹出确认框 → 点 "安装"

4. App 图标出现在桌面，开始安装

5. 安装完后，先去:
   设置 → 通用 → VPN与设备管理
   → 点你的开发者证书 → 信任

6. 回到桌面 → 可以打开 App 了
```

| 遇到问题 | 解决办法 |
|----------|----------|
| 点安装没反应 | 确认 manifest.plist URL 也是 HTTPS，且证书可访问 |
| 安装到一半灰图标 | IPA 签名有误，检查 Team ID 和证书 |
| "无法验证 App" | 未信任证书，去 VPN与设备管理 信任 |

### 3.2 方式 B: Xcode 直装（开发调试）

```
1. iPhone 用数据线连接 Mac
2. Xcode 中选目标设备 → Cmd+R
3. 自动编译安装
```

> 免费账号签名有效期 7 天，超期需重新 Cmd+R 安装

### 3.3 方式 C: TestFlight（团队分发）

```
1. Xcode → Product → Archive → Distribute App → TestFlight
2. 上传到 App Store Connect
3. 添加测试员邮箱
4. 测试员在 iPhone 上装 TestFlight App，通过邀请链接下载
```

> 需要 $99/年 开发者账号，签名有效期 90 天

### 3.4 签名有效期对比

| 签名方式 | 有效期 | 过期后 |
|----------|--------|--------|
| 免费 Apple ID | 7 天 | 重连 Mac 重新 Cmd+R |
| 个人开发者 Ad-Hoc | 1 年 | 重新打包 IPA 安装 |
| 企业开发者 In-House | 1 年 | 重新打包 IPA 安装 |
| TestFlight | 90 天 | App Store Connect 续期 |

---

## 四、开始推流

### 4.1 App 内配置

```
1. 打开 ScreenCapture App
2. 在 RTMP 推流地址栏输入: rtmp://192.168.1.100:1935/live/iphone
   (把 IP 换成你的服务器地址, "iphone" 是推流标识，可自定义)
3. 点 "保存"
4. 看到绿色 ✅ 已保存
```

### 4.2 启动录屏

```
1. iPhone 下拉控制中心
2. 长按 屏幕录制 按钮 (⏺)
3. 在列表中选择 "ScreenCapture"
4. 点 "开始广播"
5. 顶部状态栏变红 = 正在推流
```

### 4.3 验证推流成功

```bash
# 在服务器上查看 API
curl http://localhost:8081/streams

# 返回示例:
# {"iphone":{"status":"live","started_at":"2026-07-21T10:30:00+00:00","client_ip":"192.168.1.50"}}

# 用 ffplay 验证视频流
ffplay rtmp://localhost/live/iphone
# 看到 iOS 屏幕画面 = 推流正常
```

### 4.4 停止推流

```
方式1: 点顶部红色状态栏 → 停止
方式2: 下拉控制中心 → 点录屏按钮
```

---

## 五、观看端

### iOS 原生观看 (ScreenViewer App) — 推荐

在另一台 iPhone/iPad 上安装 ScreenViewer，**扫码即连，无需输入任何地址**：

```
1. 服务器网页上会显示二维码
2. 打开 ScreenViewer → 扫描二维码 → 自动获取设备列表
3. 点设备 → 全屏播放
```

详见 [2.8 构建原生 iOS 观看端](#28-构建原生-ios-观看端-screenviewer)。

### 浏览器观看

打开 `http://192.168.1.100:8082/?key=iphone`，hls.js 自动播放。页面也显示二维码供 ScreenViewer 扫描。

### VLC / ffplay 调试

### VLC / ffplay 调试

```bash
ffplay rtmp://192.168.1.100/live/iphone      # 拉 RTMP 直流，延迟 ~1-2s
ffplay http://192.168.1.100:8082/hls/iphone.m3u8  # 拉 HLS，延迟 ~2-4s
```

---

## 项目结构

```
ios-screen-control/
├── deploy.sh                           # 服务端一键部署
├── build_ios.sh                        # iOS 一键打包 (Mac)
├── README.md
│
├── server/                             # 中转服务器 (Docker 部署在本机)
│   ├── docker-compose.yml
│   ├── nginx.conf                      # RTMP → HLS + HTTPS
│   ├── server.py                       # 设备管理 API
│   ├── certs/                          # HTTPS 证书 (deploy.sh 自动生成)
│   └── www/
│       ├── index.html                  # 浏览器观看页面
│       └── ota/                        # iOS OTA 安装
│           ├── index.html
│           ├── manifest.plist
│           └── ScreenCapture.ipa       # 编译好的 IPA 放这里
│
├── ScreenCapture/                      # iOS 发送端 — Main App (Mac 上编译)
│   ├── project.yml                     # XcodeGen 项目定义
│   ├── Info.plist
│   ├── ScreenCaptureApp.swift
│   ├── ContentView.swift               # RTMP URL 配置页面
│   ├── AppConfig.swift                 # App Group 共享存储
│   ├── ScreenCapture.entitlements
│   └── exportOptions.plist             # 打包签名配置
│
├── ScreenCaptureUpload/                # iOS 发送端 — Broadcast Extension (核心)
│   ├── Info.plist
│   ├── SampleHandler.swift             # ReplayKit 入口
│   ├── RtmpConnection.swift            # RTMP 协议栈
│   ├── RtmpChunk.swift                 # Chunk 编解码
│   ├── Amf0Encoder.swift               # AMF0 编码
│   ├── FLVWriter.swift                 # FLV 封装
│   ├── VideoEncoder.swift              # H.264 硬编码
│   └── ScreenCaptureUpload.entitlements
│
├── ScreenViewer/                       # iOS 观看端 — 原生 AVPlayer (Mac 上编译)
│   ├── project.yml
│   ├── Info.plist
│   ├── ScreenViewerApp.swift
│   └── ContentView.swift               # HLS 播放器 + URL 输入
│
└── docs/superpowers/
    ├── specs/2026-07-20-ios-screen-capture-design.md
    └── plans/2026-07-21-ios-screen-capture-plan.md
```

---

## 架构说明

### 数据流（一帧画面如何从 iPhone 到达浏览器）

```
┌─ iPhone ──────────────────────────────────────────────┐
│                                                         │
│  屏幕渲染帧                                              │
│    │                                                     │
│    ▼                                                     │
│  ReplayKit.framework                                    │
│  (系统级录屏，采集所有 App 画面)                          │
│    │ CMSampleBuffer (YUV 或 BGRA)                       │
│    ▼                                                     │
│  VideoEncoder.swift                                     │
│  (VideoToolbox 硬件 H.264 编码 → 零 CPU 开销)            │
│    │ H.264 NAL Units (AVCC 格式)                        │
│    ▼                                                     │
│  FLVWriter.swift                                        │
│  (封装为 FLV Video Tags → SPS/PPS → AVCDecoderConfig)   │
│    │ FLV Tag bytes                                       │
│    ▼                                                     │
│  RtmpConnection.swift                                   │
│  (AMF0 命令 + RTMP Chunk 层 + TCP Socket)               │
│    │ RTMP Data Message over TCP (:1935)                 │
└────┼─────────────────────────────────────────────────────┘
     │
     ▼
┌─ 服务器 (本机 Docker) ──────────────────────────────────┐
│                                                         │
│  nginx-rtmp                                             │
│    ├─ 接收 RTMP 流                                      │
│    ├─ 转换为 HLS (.m3u8 + .ts 分片, 每 1s 一个)        │
│    ├─ 回调 Python API (记录设备上线/离线)                │
│    └─ 通过 HTTP(S) 分发                                 │
│                                                         │
└────┬────────────────────────────────────────────────────┘
     │ HTTP GET /hls/iphone.m3u8
     ▼
┌─ 观看端 ────────────────────────────────────────────────┐
│                                                         │
│  浏览器 (hls.js) 或 iOS AVPlayer                         │
│    └→ 自动下载 .m3u8 播放列表 → 依次请求 .ts 分片 → 播放│
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 自实现 RTMP 协议栈

Extension 有严格 50MB 内存限制，不能引入第三方推流库。所有 RTMP 逻辑从零自实现：

| 模块 | 功能 | 代码量 |
|------|------|:---:|
| `Amf0Encoder` | AMF0 数据编码 (String/Number/Boolean/Object/Null/Command) | 78行 |
| `RtmpChunk` | Chunk Header 编解码 + 消息分包 (128→4096 bytes) | 110行 |
| `RtmpConnection` | TCP Socket + Handshake (C0/C1/C2) + connect/publish + 视频发送 | 172行 |

### 编码参数

```
Codec:         H.264 Baseline Profile Level 3.1
编码方式:      VideoToolbox 硬件编码 (零 CPU)
分辨率:        1280×720 (自动适配屏幕宽高比)
码率:          2 Mbps CBR
关键帧间隔:    每 60 帧 (~2秒一个 I 帧)
帧率:          30 FPS
色彩格式:      YUV 4:2:0
```

---

## API 文档

### `GET /api/streams`

在线设备列表：

```json
{
  "iphone": {
    "status": "live",
    "started_at": "2026-07-21T10:30:00+00:00",
    "client_ip": "192.168.1.50",
    "client_id": ""
  }
}
```

### `GET /health`

健康检查：

```json
{"status": "ok"}
```

---

## 常见问题

<details>
<summary><b>Q: iPhone 上点 OTA 安装没反应？</b></summary>

1. 确认 manifest.plist 中的 URL 是 HTTPS 开头（不是 HTTP）
2. 确认 IPA 路径正确：`server/www/ota/ScreenCapture.ipa`
3. 自签名证书需要在 Safari 中先访问一次 `https://IP:8444/ota/`，点"继续访问"
</details>

<details>
<summary><b>Q: IPA 安装后 App 灰图标 / 无法打开？</b></summary>

证书签名问题：
1. 确认 Xcode 中选择了正确的 Team
2. 免费账号：去 设置→通用→VPN与设备管理 信任证书
3. 企业账号：同上
4. Ad-Hoc：确认目标设备 UDID 已在 Developer Portal 注册
</details>

<details>
<summary><b>Q: 推流后观看端没有画面？</b></summary>

排查顺序：
```bash
# 1. 确认设备在线
curl http://localhost:8081/streams
# 应看到 status: "live"

# 2. 确认 HLS 文件生成
ls /tmp/hls/
# 应有 iphone.m3u8 和 .ts 文件

# 3. 用 ffplay 拉流验证
ffplay rtmp://localhost/live/iphone

# 4. 查看 nginx 日志
docker compose -f server/docker-compose.yml logs media-server
```
</details>

<details>
<summary><b>Q: Extension 推流到一半断开？</b></summary>

可能是 Extension 内存超 50MB 被系统杀掉了。日志中搜 `SampleHandler`：
1. 确认未引入任何第三方库
2. 降低编码分辨率到 640×360 试试
3. 降低码率到 1 Mbps
</details>

<details>
<summary><b>Q: 如何多台 iPhone 同时推流？</b></summary>

每台设备用不同的 stream key：
```
iPhone-A: rtmp://server/live/iphone-a
iPhone-B: rtmp://server/live/iphone-b
```
观看端对应切换 stream key 参数：`?key=iphone-a`
</details>

<details>
<summary><b>Q: 防火墙 / 端口不通？</b></summary>

```bash
# 开放端口 (Ubuntu)
sudo ufw allow 1935/tcp
sudo ufw allow 8082/tcp
sudo ufw allow 8444/tcp
sudo ufw allow 8081/tcp

# macOS 检查防火墙 (系统设置 → 网络 → 防火墙)
```
</details>

---

## 限制

| 项目 | 说明 |
|------|------|
| 端到端延迟 | ~2-4 秒 (HLS 1s 分片 + 编码缓冲) |
| 上行带宽 | ≥ 3 Mbps (2M 视频码率 + 协议开销) |
| iOS 最低版本 | iOS 12.0 |
| Extension 内存 | ≤ 50MB |
| 同时推流数 | nginx-rtmp 默认支持多路 |
| 安全性 | 无鉴权，建议仅在内网使用 |

## License

MIT
