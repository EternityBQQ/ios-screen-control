# iOS 签名配置指南 (For GitHub Actions CI)

没有 Mac 也能通过 GitHub Actions 自动构建 iOS App。但生成**可安装的 IPA** 需要 Apple 签名证书。

本指南覆盖两种场景：

| 场景 | 需要 Mac 吗 | 产出物 |
|------|------------|--------|
| **A. 仅编译检查** | ❌ 不需要 | 验证代码能编译，不能安装 |
| **B. 导出可安装 IPA** | 需要 (一次性) | 可安装到 iPhone 的 IPA |

---

## 场景 A: 编译检查 (零配置)

**什么都不用做。** 每次 push 代码到 GitHub，CI 自动验证代码能否编译通过。

- 在 GitHub 仓库页面 → Actions → 查看 Build Check 结果
- 编译失败会收到邮件通知

---

## 场景 B: 导出可安装 IPA

需要一次性在 Mac 上提取签名证书和描述文件，然后存入 GitHub Secrets。

### 前提

- 一个 **Apple ID**（免费即可，注册地址: https://appleid.apple.com）
- **一次性**借用 Mac（朋友、公司、或云服务 MacinCloud/MacStadium）
- GitHub 仓库

### 步骤 1: 在 Mac 上生成签名证书 (仅一次)

在 Mac 上打开 **终端 (Terminal)**，执行：

```bash
# 1. 创建证书签名请求 (CSR)
openssl genrsa -out ios_distribution.key 2048
openssl req -new -key ios_distribution.key -out ios_distribution.csr \
  -subj "/emailAddress=your@email.com/CN=ScreenCapture CI/O=Personal"

# 2. 打开 Keychain Access
open /System/Library/Keychain\ Access.app

# 3. Keychain Access → Certificate Assistant → Create a Certificate
#    - Name: "ScreenCapture CI"
#    - Identity Type: Self Signed Root
#    - Certificate Type: Code Signing
#    - ☑ Let me override defaults
#    - 点 Continue 直到生成完成
```

然后导出为 .p12：

```bash
# 4. 在 Keychain Access 中找到刚创建的证书 (搜索 "ScreenCapture CI")
#    右键 → Export → 保存为 build-certificate.p12
#    设置密码 (记下来! 这就是 P12_PASSWORD)

# 5. 编码为 Base64 (用于 GitHub Secrets)
base64 -i ~/Desktop/build-certificate.p12 -o ~/Desktop/cert-base64.txt
```

### 步骤 2: 创建 App ID 和 Provisioning Profile

打开 https://developer.apple.com → 用 Apple ID 登录：

1. **Certificates, Identifiers & Profiles** → **Identifiers** → **+**
2. 创建 App ID:
   - Type: App
   - Bundle ID: `com.screencapture.app`
   - Capabilities: App Groups
3. 再创建 Extension App ID:
   - Bundle ID: `com.screencapture.app.upload`
   - Capabilities: App Groups
4. **App Groups** → **+** → `group.com.screencapture.app`
5. **Profiles** → **+** → Development → 选择上述 App ID → 选择证书 → 选择设备 → 下载

### 步骤 3: 获取设备 UDID

```bash
# 在 iPhone Safari 打开:
# https://udid.io
# 按指引安装临时 Profile → 获取 UDID 发送到邮箱
```

### 步骤 4: 添加到 GitHub Secrets

在 GitHub 仓库 → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**：

| Secret 名称 | 值 |
|-------------|-----|
| `APPLE_TEAM_ID` | 你的 Team ID (在 https://developer.apple.com/account 查看) |
| `BUILD_CERTIFICATE_BASE64` | `cert-base64.txt` 文件内容 |
| `P12_PASSWORD` | 导出 .p12 时设置的密码 |
| `PROVISIONING_PROFILE_BASE64` | `base64 -i ~/Downloads/YourProfile.mobileprovision` 输出 |

### 步骤 5: 触发构建

1. GitHub 仓库 → **Actions** → **Build iOS Apps** → **Run workflow**
2. 选择 `export-ipa` → 点击 **Run workflow**
3. 等待 ~15 分钟
4. 在构建结果页 → **Artifacts** → 下载 `ScreenCapture.ipa`

---

## 自动部署到 OTA 服务器 (可选)

如果你有服务器运行着 `deploy.sh` 部署的服务，可以配置 CI 自动上传 IPA：

1. 在服务器上创建一个上传接口（或直接用 SCP）
2. 添加 GitHub Secrets:
   - `OTA_DEPLOY_URL`: 上传接口 URL
   - `OTA_DEPLOY_TOKEN`: 认证 Token
3. 推送到 main 分支时 IPA 会自动上传

---

## 云 Mac 服务 (如果没有 Mac)

| 服务 | 价格 | 说明 |
|------|------|------|
| [MacinCloud](https://macincloud.com) | ~$1/小时 | 按小时租用，有 Xcode 预装 |
| [MacStadium](https://macstadium.com) | ~$99/月 | 专用 Mac mini |
| [AWS EC2 Mac](https://aws.amazon.com/ec2/mac/) | ~$1.08/小时 | AWS 托管 Mac mini |

**推荐**: 租 MacinCloud 2-3 小时完成一次性证书配置，之后全靠 CI 自动构建。

---

## 签名有效期

| 账号类型 | 签名方式 | 有效期 |
|----------|----------|--------|
| 免费 Apple ID | Development | **7 天** |
| 个人开发者 ($99/年) | Ad-Hoc | **1 年** |
| 企业开发者 ($299/年) | In-House | **1 年** |

> 免费账号每 7 天需重新触发 CI 构建，证书会自动续签。推荐用个人开发者账号（$99/年）。
