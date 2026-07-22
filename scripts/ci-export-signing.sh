#!/usr/bin/env bash
# ============================================================
# ci-export-signing.sh — 在 Mac 上一次性导出 CI 签名资产
#
# 使用方法:
#   1. 确保已用 Xcode 登录 Apple ID 并配置好签名
#   2. chmod +x ci-export-signing.sh && ./ci-export-signing.sh
#   3. 按提示操作，输出 GitHub Secrets 所需的值
#
# 输出:
#   - APPLE_TEAM_ID
#   - BUILD_CERTIFICATE_BASE64
#   - P12_PASSWORD
#   - PROVISIONING_PROFILE_BASE64
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

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║   CI 签名资产导出工具                         ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  此脚本将导出:"
    echo "  1. Apple Team ID"
    echo "  2. 签名证书 (.p12 → Base64)"
    echo "  3. Provisioning Profile → Base64"
    echo ""
    echo "  操作完成后，将值填入 GitHub Secrets 即可"
    echo ""
}

banner

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop/ci-signing-export}"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ─── Step 1: Team ID ─────────────────────────
step "1/4 获取 Team ID"

# 尝试从 Keychain / Xcode 自动检测
TEAM_ID=""
TEAM_ID=$(security find-identity -v -p codesigning 2>/dev/null | \
    grep -oE '\([A-Z0-9]{10}\)' | head -1 | tr -d '()' || echo "")

if [ -z "$TEAM_ID" ]; then
    warn "未自动检测到 Team ID"
    echo ""
    echo "  手动查找:"
    echo "  1. 打开 https://developer.apple.com/account"
    echo "  2. 登录 → Membership → Team ID"
    echo ""
    read -r -p "  请输入你的 Team ID (10位字母数字): " TEAM_ID
fi

if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "YOUR_TEAM_ID" ]; then
    fail "Team ID 无效，请手动输入"
fi
success "Team ID: $TEAM_ID"

# ─── Step 2: 导出签名证书 ─────────────────────
step "2/4 导出签名证书"

CERT_NAME=""
CERT_NAMES=$(security find-identity -v -p codesigning 2>/dev/null | \
    grep -oE '"[^"]+"' | tr -d '"' || echo "")

if [ -z "$CERT_NAMES" ]; then
    echo "  未找到任何代码签名证书。"
    echo ""
    echo "  请先完成以下步骤:"
    echo ""
    echo "  方式 A — Xcode 自动管理 (推荐):"
    echo "    1. 打开 Xcode → Settings → Accounts → 登录 Apple ID"
    echo "    2. Xcode → 打开 ScreenCapture.xcodeproj"
    echo "    3. Signing & Capabilities → ☑ Automatically manage signing"
    echo "    4. Team: 选你的 Apple ID"
    echo "    5. 等待 Xcode 自动创建证书和 Profile (~30秒)"
    echo ""
    echo "  方式 B — 手动创建证书:"
    echo "    1. 打开 Keychain Access"
    echo "    2. Certificate Assistant → Create a Certificate"
    echo "    3. Type: Code Signing, 勾选 'Let me override defaults'"
    echo ""
    fail "请先配置签名证书，然后重新运行此脚本"
fi

# 列出可用证书让用户选择
echo "  找到以下签名证书:"
echo ""
IFS=$'\n' read -r -d '' -a CERT_ARRAY <<< "$CERT_NAMES" || true
i=1
for cert in "${CERT_ARRAY[@]}"; do
    echo "    $i) $cert"
    ((i++))
done
echo ""

if [ ${#CERT_ARRAY[@]} -eq 1 ]; then
    CERT_NAME="${CERT_ARRAY[0]}"
    success "自动选择: $CERT_NAME"
else
    read -r -p "  选择证书编号 (1-${#CERT_ARRAY[@]}): " CERT_IDX
    CERT_NAME="${CERT_ARRAY[$((CERT_IDX-1))]}"
    success "已选择: $CERT_NAME"
fi

# 导出 .p12
P12_PATH="$OUTPUT_DIR/build-certificate.p12"
P12_PASSWORD=$(openssl rand -base64 24)
echo "  (导出密码: $P12_PASSWORD)"

security export -k login.keychain-db \
    -t identities -f pkcs12 \
    -P "$P12_PASSWORD" \
    -o "$P12_PATH" 2>/dev/null || {
    # 备用: 用 cert 名称导出
    security export -k login.keychain-db \
        -t identities -f pkcs12 \
        -P "$P12_PASSWORD" \
        -o "$P12_PATH" \
        -l "$CERT_NAME" 2>/dev/null || \
    fail "导出证书失败。请在 Keychain Access 中手动导出: 右键证书 → Export → .p12"
}

CERT_BASE64=$(base64 -i "$P12_PATH")
echo "$CERT_BASE64" > "$OUTPUT_DIR/cert-base64.txt"
success "证书已导出: $OUTPUT_DIR/build-certificate.p12"

# ─── Step 3: 导出 Provisioning Profile ────────
step "3/4 导出 Provisioning Profile"

PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
if [ ! -d "$PROFILE_DIR" ]; then
    warn "未找到 Provisioning Profiles 目录"
    echo ""
    echo "  请先在 Xcode 中配置 App 签名:"
    echo "  1. 打开 ScreenCapture.xcodeproj"
    echo "  2. Signing & Capabilities:"
    echo "     - Bundle: com.screencapture.app"
    echo "     - Team: 选你的 Apple ID"
    echo "     - ☑ Automatically manage signing"
    echo "  3. 等待 Xcode 自动生成 Profile"
    echo ""
fi

# 查找相关的 Provisioning Profiles
PROFILES=$(find "$PROFILE_DIR" -name "*.mobileprovision" -newer "$PROFILE_DIR" -mtime -7 2>/dev/null || \
           find "$PROFILE_DIR" -name "*.mobileprovision" 2>/dev/null)

if [ -z "$PROFILES" ]; then
    warn "未找到 Provisioning Profile"
    echo ""
    echo "  请先在 Xcode 中完成签名配置 (见上方说明)"
    echo "  或者手动下载: https://developer.apple.com → Profiles"
    echo ""
    read -r -p "  输入 .mobileprovision 文件路径 (可跳过): " MANUAL_PROFILE

    if [ -n "$MANUAL_PROFILE" ] && [ -f "$MANUAL_PROFILE" ]; then
        PROFILES="$MANUAL_PROFILE"
    else
        warn "跳过 Provisioning Profile (仅证书可用于自签)"
        PROFILE_BASE64=""
    fi
fi

if [ -n "$PROFILES" ]; then
    echo "  找到以下 Profile(s):"
    echo ""
    i=1
    PROFILE_ARRAY=()
    while IFS= read -r profile; do
        PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" /dev/stdin <<< \
            "$(security cms -D -i "$profile")" 2>/dev/null || echo "Unknown")
        PROFILE_BUNDLE=$(/usr/libexec/PlistBuddy -c "Print Entitlements:application-identifier" /dev/stdin <<< \
            "$(security cms -D -i "$profile")" 2>/dev/null | sed 's/.*\.//' || echo "Unknown")
        echo "    $i) $PROFILE_NAME (Bundle: $PROFILE_BUNDLE)"
        echo "       路径: $profile"
        PROFILE_ARRAY+=("$profile")
        ((i++))
    done <<< "$PROFILES"
    echo ""

    if [ $i -eq 2 ]; then
        SELECTED_PROFILE="${PROFILE_ARRAY[0]}"
        success "自动选择: $(basename "$SELECTED_PROFILE")"
    else
        read -r -p "  选择 Profile 编号 (1-${#PROFILE_ARRAY[@]}): " PROFILE_IDX
        SELECTED_PROFILE="${PROFILE_ARRAY[$((PROFILE_IDX-1))]}"
        success "已选择: $(basename "$SELECTED_PROFILE")"
    fi

    PROFILE_BASE64=$(base64 -i "$SELECTED_PROFILE")
    echo "$PROFILE_BASE64" > "$OUTPUT_DIR/profile-base64.txt"
    success "Provisioning Profile 已导出"
fi

# ─── Step 4: 输出结果 ─────────────────────────
step "4/4 输出 GitHub Secrets"

echo ""
echo -e "${BOLD}━━━━━━━━━━━ 复制以下值到 GitHub Secrets ━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BOLD}GitHub 仓库 → Settings → Secrets and variables → Actions${NC}"
echo -e "${BOLD}→ New repository secret${NC}"
echo ""

SEPARATOR="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "$SEPARATOR"
echo ""
echo -e "${BOLD}Secret 名称:${NC}   ${GREEN}APPLE_TEAM_ID${NC}"
echo -e "${BOLD}值:${NC}"
echo "  $TEAM_ID"
echo ""

echo "$SEPARATOR"
echo ""
echo -e "${BOLD}Secret 名称:${NC}   ${GREEN}BUILD_CERTIFICATE_BASE64${NC}"
echo -e "${BOLD}值:${NC}"
echo "  (见文件: $OUTPUT_DIR/cert-base64.txt)"
echo -e "  ${YELLOW}⚠️  内容过长，请复制文件内容而非此处显示${NC}"
echo ""

echo "$SEPARATOR"
echo ""
echo -e "${BOLD}Secret 名称:${NC}   ${GREEN}P12_PASSWORD${NC}"
echo -e "${BOLD}值:${NC}"
echo "  $P12_PASSWORD"
echo ""

if [ -n "${PROFILE_BASE64:-}" ]; then
    echo "$SEPARATOR"
    echo ""
    echo -e "${BOLD}Secret 名称:${NC}   ${GREEN}PROVISIONING_PROFILE_BASE64${NC}"
    echo -e "${BOLD}值:${NC}"
    echo "  (见文件: $OUTPUT_DIR/profile-base64.txt)"
    echo -e "  ${YELLOW}⚠️  内容过长，请复制文件内容而非此处显示${NC}"
    echo ""
fi

echo "$SEPARATOR"

# ─── 保存完整信息到文件 ─────────────────────
cat > "$OUTPUT_DIR/secrets.txt" << EOF
# GitHub Actions Secrets — iOS Build
# 生成时间: $(date)

APPLE_TEAM_ID=$TEAM_ID

BUILD_CERTIFICATE_BASE64=
# ↑ 使用文件 cert-base64.txt 的内容

P12_PASSWORD=$P12_PASSWORD

PROVISIONING_PROFILE_BASE64=
# ↑ 使用文件 profile-base64.txt 的内容
EOF

echo ""
echo -e "${BOLD}━━━━━━━━━━━ 输出文件 ━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  所有资产已保存到: ${CYAN}$OUTPUT_DIR${NC}"
ls -la "$OUTPUT_DIR"
echo ""
echo -e "  ${GREEN}secrets.txt${NC}      — 汇总信息"
echo -e "  ${GREEN}cert-base64.txt${NC}  — BUILD_CERTIFICATE_BASE64"
echo -e "  ${GREEN}profile-base64.txt${NC} — PROVISIONING_PROFILE_BASE64"
echo ""
echo -e "${BOLD}下一步:${NC}"
echo ""
echo "  1. 打开 GitHub 仓库 → Settings → Secrets → Actions"
echo "  2. 逐个添加这 4 个 Secrets"
echo "  3. 转到 Actions → Build iOS Apps → Run workflow"
echo "  4. 选择 export-ipa → 启动构建"
echo ""
echo -e "${GREEN}${BOLD}✅ 导出完成!${NC}"
echo ""
