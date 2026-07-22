# iOS 签名配置指南 — 零 Mac 方案

> **核心思路**: GitHub Actions 的 macOS runner 本身就是一台 Mac。CI 可以自己生成密钥和 CSR，你只需要一个浏览器完成 Apple 端的操作。

---

## 三种方案速览

| 方案 | 需要什么 | 产物 | 有效期 |
|------|---------|------|--------|
| **A. 编译检查** (默认) | 无 | 验证编译 | — |
| **B. 自动签名** | 免费 Apple ID + 专用密码 | 可安装 IPA | 7 天 |
| **C. 手动签名** (推荐) | 付费开发者账号 ($99/年) | 可安装 IPA | 1 年 |

---

## 方案 A: 编译检查

**什么都不用做。** push 代码 → CI 自动验证编译。

---

## 方案 B: 自动签名 (免费 Apple ID)

> ⚠️ 此方案尝试在 CI 中用 Xcode 自动管理签名。由于 Apple 的认证机制，有一定概率失败。失败了就用方案 C。

### 步骤

**1. 获取 Apple ID 专用密码 (2 分钟)**

打开 https://appleid.apple.com → 登录你的 Apple ID
→ **Sign-In and Security** → **App-Specific Passwords**
→ 点 + 号，名称填 `GitHub CI`，复制生成的密码

**2. 获取 Team ID**

打开 https://developer.apple.com/account → 登录
→ **Membership** → 复制 Team ID (10 位字母数字)

**3. 添加到 GitHub Secrets**

仓库 → **Settings** → **Secrets and variables** → **Actions** → New secret:

| Secret | 值 |
|--------|-----|
| `APPLE_ID_EMAIL` | 你的 Apple ID 邮箱 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 第一步生成的专用密码 |
| `APPLE_TEAM_ID` | 第二步的 Team ID |

**4. 触发构建**

Actions → Build iOS Apps → Run workflow → 选 `auto-sign` → Run

---

## 方案 C: 手动签名 (付费开发者 $99/年) — 零 Mac，最可靠 ✅

**整个流程不需要 Mac。** CI 生成 CSR → 你浏览器上传 Apple → CI 签名。

### 步骤 1: CI 生成 CSR

Actions → Build iOS Apps → Run workflow → 选 `generate-csr` → Run

等 2 分钟 → 下载 Artifact **signing-csr.zip** 解压得到 `ci-signing.csr`

### 步骤 2: Apple 网站创建证书 (纯浏览器操作)

打开 https://developer.apple.com/account → 登录:

```
☐ Certificates, Identifiers & Profiles
  ├─ Certificates → +
  │   └─ 选 "Apple Distribution" (分发) 或 "iOS App Development" (开发)
  │       └─ 上传 ci-signing.csr → 下载 .cer 文件
  │
  ├─ Identifiers → +
  │   ├─ App ID: com.screencapture.app
  │   └─ App ID: com.screencapture.app.upload
  │
  ├─ Devices → +
  │   └─ 输入 iPhone UDID (获取: iPhone Safari 打开 udid.io)
  │
  └─ Profiles → +
      ├─ 选 "App Store Connect" 或 "iOS App Development"
      ├─ 选 App ID: com.screencapture.app
      ├─ 选刚创建的证书
      ├─ 选设备
      └─ 下载 .mobileprovision 文件
```

### 步骤 3: 编码并填入 GitHub Secrets

在 **Gitee/GitHub Actions 的 macOS runner 上**(或你本地 Linux 的终端):

```bash
# 对下载的 .cer 编码
base64 -i ~/Downloads/ios_distribution.cer

# 对下载的私钥（来自 signing-key-protected Artifact）编码
base64 -i ~/Downloads/ci-signing.key

# 对下载的 .mobileprovision 编码
base64 -i ~/Downloads/YourApp.mobileprovision
```

填入 GitHub Secrets:

| Secret | 值 |
|--------|-----|
| `APPLE_TEAM_ID` | 你的 Team ID |
| `BUILD_CERTIFICATE_BASE64` | .cer 文件的 base64 |
| `CERTIFICATE_KEY_BASE64` | ci-signing.key 的 base64 |
| `PROVISIONING_PROFILE_BASE64` | .mobileprovision 的 base64 |

### 步骤 4: 构建

Actions → Build iOS Apps → Run workflow → 选 `manual-sign` → Run

10 分钟后 → Artifacts → 下载 **ScreenCapture-Signed.ipa**

---

## 获取 iPhone UDID (无需 Mac)

1. iPhone Safari 打开 **https://udid.io**
2. 点 "Tap to find UDID"
3. 允许安装临时 Profile
4. 页面显示 UDID → 复制/发到邮箱

---

## OTA 安装到 iPhone

```bash
# 1. 把 IPA 传到服务器
scp ScreenCapture-Signed.ipa you@server:~/ios-screen-control/server/www/ota/ScreenCapture.ipa

# 2. iPhone Safari 打开 OTA 页面
# https://你的域名/ota/

# 3. 首次打开需信任证书:
#    设置 → 通用 → VPN与设备管理 → 信任
```

---

## 签名有效期

| 账号 | 证书类型 | 有效期 | 过期处理 |
|------|---------|--------|----------|
| 免费 Apple ID | Development | 7 天 | 重新触发 CI |
| 个人开发者 ($99) | Distribution | 1 年 | 重新生成 CSR + 证书 |
| 企业开发者 ($299) | Distribution | 1 年 | 重新生成 CSR + 证书 |

---

## FAQ

**Q: 为什么自动签名 (方案 B) 可能失败？**

Apple 的 Xcode 自动签名设计为交互式使用。在 CI 中认证可能遇到 2FA 问题。方案 C 的手动签名通过 Apple Developer 网站操作，100% 可靠。

**Q: 免费 Apple ID 能用方案 C 吗？**

不能。免费 Apple ID 在 developer.apple.com 上没有创建证书和 Profile 的权限，只能通过 Xcode 自动管理。要方案 C 需要付费账号 ($99/年)。

**Q: 我不想付 $99，也不想借 Mac，怎么办？**

方案 B 值得一试。如果 Xcode 自动签名在 CI 中跑通了，你就彻底不需要 Mac。如果失败，考虑花 $99（个人开发者账号），之后一年都无需 Mac。
