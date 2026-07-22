# iOS 签名配置指南 — 零 Mac 方案

> 需要 **Apple Developer Program**（$99/年）。注册后在 developer.apple.com 操作，全程只需浏览器，不需要 Mac。

---

## 概览

```
CI 生成 CSR → 你浏览器上传到 Apple → 创建证书+Profile
→ 填入 GitHub Secrets → CI 自动签名导出 IPA
```

---

## 步骤 1: CI 生成 CSR

1. GitHub → **Actions** → **Build iOS Apps** → **Run workflow**
2. 选择 **generate-csr** → **Run workflow**
3. 等 2 分钟 → 下载 Artifact **signing-csr.zip**
4. 解压得到 `ci-signing.csr`

## 步骤 2: Apple 网站创建证书

打开 https://developer.apple.com/account → 登录:

```
Certificates → + → iOS Distribution (App Store Ad Hoc)
  → 上传 ci-signing.csr → 下载 .cer 文件
```

## 步骤 3: 创建 App ID

```
Identifiers → + → App IDs
  → Bundle ID: com.screencapture.app
  → Bundle ID: com.screencapture.app.upload
```

## 步骤 4: 获取设备 UDID

iPhone Safari 打开 https://udid.io → 点 "Tap to find UDID" → 复制

```
Devices → + → 输入 UDID 和设备名称
```

## 步骤 5: 创建 Provisioning Profile

```
Profiles → + → iOS App Development
  → App ID: com.screencapture.app
  → 选择证书
  → 选择设备
  → 下载 .mobileprovision
```

## 步骤 6: 填入 GitHub Secrets

在本地终端编码（或直接用在线 base64 工具）:

```bash
base64 -i 下载的.cer        # → BUILD_CERTIFICATE_BASE64
base64 -i ci-signing.key    # → CERTIFICATE_KEY_BASE64 (来自 signing-key-protected Artifact)
base64 -i 下载的.mobileprovision  # → PROVISIONING_PROFILE_BASE64
```

打开 https://github.com/EternityBQQ/ios-screen-control/settings/secrets/actions → New secret:

| Secret | 值 |
|--------|-----|
| `APPLE_TEAM_ID` | Team ID (developer.apple.com → Membership) |
| `BUILD_CERTIFICATE_BASE64` | .cer 文件 base64 |
| `CERTIFICATE_KEY_BASE64` | 私钥文件 base64 |
| `PROVISIONING_PROFILE_BASE64` | .mobileprovision 文件 base64 |

## 步骤 7: 构建 IPA

Actions → Build iOS Apps → Run workflow → **manual-sign** → Run

10 分钟后 → Artifacts → 下载 **ScreenCapture.ipa**

---

## OTA 安装到 iPhone

```bash
scp ScreenCapture.ipa you@server:~/ios-screen-control/server/www/ota/
# iPhone Safari → https://你的域名/ota/
# 首次: 设置 → 通用 → VPN与设备管理 → 信任证书
```

---

## 签名有效期

| 证书类型 | 有效期 | 过期后 |
|---------|--------|--------|
| iOS Development | 1 年 | 重新生成 CSR + 证书 |
| iOS Distribution | 1 年 | 重新生成 CSR + 证书 |

---

## FAQ

**Q: 免费 Apple ID 为什么不行？**

免费账号必须在 Mac 上通过 Xcode 创建签名证书，无法在开发者网站操作。CI 里的 Xcode 也无法模拟这个过程（需要交互式登录）。

**Q: 我不想花 $99，还有什么办法？**

借一台 Mac 10 分钟 → 打开 Xcode → 登录 Apple ID → 运行 `scripts/ci-export-signing.sh` → 导出证书到 GitHub Secrets → 之后全靠 CI。
