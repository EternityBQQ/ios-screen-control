#!/usr/bin/env bash
# ============================================================
# ScreenCapture — iOS 一键打包脚本 (在 Mac 上运行)
# 生成 Xcode 项目 → Archive → Export IPA
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

success() { echo -e "  ${GREEN}✅${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠️${NC}  $1"; }
fail()    { echo -e "  ${RED}❌${NC} $1"; exit 1; }
step()    { echo ""; echo -e "${BOLD}▶ $1${NC}"; echo "──────────────────────────────────────────────"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/ScreenCapture"
BUILD_DIR="$PROJECT_DIR/build"

SCHEME="${SCHEME:-ScreenCapture}"
CONFIG="${CONFIG:-Release}"
TEAM_ID="${TEAM_ID:-}"

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   ScreenCapture — iOS 一键打包脚本         ║${NC}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════╝${NC}"
echo ""

# ---- Step 1: 环境检查 ----
step "1/5 检查环境"

command -v xcodebuild >/dev/null 2>&1 || fail "需要 Xcode，请从 App Store 安装"
success "Xcode: $(xcodebuild -version | head -1)"

command -v xcodegen >/dev/null 2>&1 || fail "需要 XcodeGen: brew install xcodegen"
success "XcodeGen: $(xcodegen --version 2>&1)"

[ -d "$PROJECT_DIR" ] || fail "目录不存在: $PROJECT_DIR，请在项目根目录运行"

# ---- Step 2: 生成 Xcode 项目 ----
step "2/5 生成 Xcode 项目"

cd "$PROJECT_DIR"
xcodegen generate
success "ScreenCapture.xcodeproj 已生成"

# ---- Step 3: 自动获取 Team ID ----
step "3/5 配置签名"

if [ -z "$TEAM_ID" ]; then
    # 自动从钥匙串获取第一个可用的 Team ID
    TEAM_ID=$(security find-identity -v -p codesigning 2>/dev/null | \
        grep -oE '\([A-Z0-9]{10}\)' | head -1 | tr -d '()' || echo "")

    if [ -z "$TEAM_ID" ]; then
        warn "未自动检测到 Team ID，请在 exportOptions.plist 中手动填写"
        warn "Team ID 可在 https://developer.apple.com/account 查看"
        TEAM_ID="YOUR_TEAM_ID"
    else
        success "自动检测到 Team ID: $TEAM_ID"
    fi
else
    success "使用指定 Team ID: $TEAM_ID"
fi

# ---- Step 3.5: 写入 exportOptions.plist ----
EXPORT_OPTIONS="$PROJECT_DIR/exportOptions.plist"

# 判断签名方式
SIGN_METHOD="ad-hoc"
if [ "$TEAM_ID" = "YOUR_TEAM_ID" ]; then
    SIGN_METHOD="development"
fi

cat > "$EXPORT_OPTIONS" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${SIGN_METHOD}</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>compileBitcode</key>
    <false/>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLISTEOF

success "exportOptions.plist 已写入 (method=${SIGN_METHOD})"

# ---- Step 4: Archive ----
step "4/5 Archive (编译归档)"

xcodebuild -project ScreenCapture.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$BUILD_DIR/ScreenCapture.xcarchive" \
  archive

success "Archive 完成"

# ---- Step 5: Export IPA ----
step "5/5 Export IPA"

rm -rf "$BUILD_DIR/ipa"
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/ScreenCapture.xcarchive" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$BUILD_DIR/ipa"

# ---- 输出 ----
echo ""
echo -e "${BOLD}━━━━━━━━━━━ 打包完成 ━━━━━━━━━━━━━━${NC}"
echo ""

IPA_PATH="$BUILD_DIR/ipa/ScreenCapture.ipa"
if [ -f "$IPA_PATH" ]; then
    IPA_SIZE=$(ls -lh "$IPA_PATH" | awk '{print $5}')
    success "IPA: $IPA_PATH (${IPA_SIZE})"
else
    # 有时候导出名字不一样，找 .ipa 文件
    IPA_PATH=$(find "$BUILD_DIR/ipa" -name "*.ipa" | head -1)
    if [ -f "$IPA_PATH" ]; then
        success "IPA: $IPA_PATH"
    else
        fail "IPA 未生成，请检查 Xcode 签名配置"
    fi
fi

echo ""
echo -e "  ${BOLD}下一步: 部署到服务器${NC}"
echo ""
echo -e "  ${CYAN}# 如果服务器是本机:${NC}"
echo -e "  ${GREEN}cp $IPA_PATH ../server/www/ota/${NC}"
echo ""
echo -e "  ${CYAN}# 如果服务器是远程:${NC}"
echo -e "  ${GREEN}scp $IPA_PATH user@your-server:~/ios-screen-control/server/www/ota/${NC}"
echo ""
echo -e "  ${CYAN}# 然后修改 OTA 配置中的服务器地址:${NC}"
echo -e "  ${GREEN}cd ../server/www/ota${NC}"
echo -e "  ${GREEN}sed -i 's/YOUR_SERVER/你的服务器IP/g' index.html manifest.plist${NC}"
echo ""
echo -e "  ${CYAN}# iPhone Safari 打开安装:${NC}"
echo -e "  ${GREEN}https://你的服务器IP:8444/ota/${NC}"
echo ""
