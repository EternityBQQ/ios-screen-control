#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ScreenCapture — 一键部署脚本
# 生成证书 → 拉取镜像 → 启动服务 → 输出访问地址
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║   ScreenCapture — 三端实时屏幕共享 部署脚本  ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

success() { echo -e "  ${GREEN}✅${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠️${NC}  $1"; }
fail()    { echo -e "  ${RED}❌${NC} $1"; exit 1; }
info()    { echo -e "  ${CYAN}ℹ️${NC}  $1"; }
step()    { echo ""; echo -e "${BOLD}▶ $1${NC}"; echo "──────────────────────────────────────────────"; }

# ─── 配置 ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"

HTTP_PORT="${HTTP_PORT:-8082}"
HTTPS_PORT="${HTTPS_PORT:-8444}"
RTMP_PORT="${RTMP_PORT:-1935}"
API_PORT="${API_PORT:-8081}"

SERVER_IP="${SERVER_IP:-}"

# ─── 主流程 ────────────────────────────────────
banner

# ---- Step 1: 环境检查 ----
step "1/5 检查环境依赖"

command -v docker >/dev/null 2>&1 || fail "需要 Docker，请先安装: https://docs.docker.com/get-docker/"
success "Docker 已就绪"

docker compose version >/dev/null 2>&1 && COMPOSE="docker compose" || {
    command -v docker-compose >/dev/null 2>&1 && COMPOSE="docker-compose" || fail "需要 Docker Compose"
}
success "Docker Compose 已就绪 ($COMPOSE)"

# ---- Step 2: 生成 HTTPS 证书 ----
step "2/5 生成 HTTPS 证书"

mkdir -p "$SERVER_DIR/certs"

if [ -f "$SERVER_DIR/certs/server.crt" ] && [ -f "$SERVER_DIR/certs/server.key" ]; then
    success "证书已存在，跳过生成"
else
    # 尝试获取公网 IP 作为 CN
    CN="localhost"
    if [ -n "$SERVER_IP" ]; then
        CN="$SERVER_IP"
    else
        PUBLIC_IP=$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo "")
        [ -n "$PUBLIC_IP" ] && CN="$PUBLIC_IP"
    fi

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SERVER_DIR/certs/server.key" \
        -out "$SERVER_DIR/certs/server.crt" \
        -subj "/CN=$CN" 2>/dev/null
    success "证书已生成 (CN=$CN)"
fi

# ---- Step 3: 写入 docker-compose 端口配置 ----
step "3/5 写入端口配置"

# 用环境变量渲染 docker-compose.yml (用 envsubst 或直接 sed)
cat > "$SERVER_DIR/docker-compose.yml" << DOCKEREOF
services:
  media-server:
    image: tiangolo/nginx-rtmp:latest
    ports:
      - "${RTMP_PORT}:1935"
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./www:/usr/share/nginx/html:ro
      - hls_data:/tmp/hls
    restart: unless-stopped

  api:
    image: python:3.11-alpine
    ports:
      - "${API_PORT}:8081"
    command: python /app/server.py
    volumes:
      - ./server.py:/app/server.py:ro
    restart: unless-stopped

volumes:
  hls_data:
DOCKEREOF
success "docker-compose.yml 已写入"

# ---- Step 4: 创建必要目录 ----
step "4/5 准备静态文件目录"

mkdir -p "$SERVER_DIR/www/ota"
touch "$SERVER_DIR/certs/.gitkeep"
success "目录就绪"

# ---- Step 5: 启动服务 ----
step "5/5 启动 Docker 服务"

cd "$SERVER_DIR"
$COMPOSE down --remove-orphans 2>/dev/null || true
$COMPOSE up -d --pull always 2>&1 | tail -3

# 等 containers 就绪
info "等待服务启动..."
for i in $(seq 1 15); do
    if curl -s "http://localhost:${API_PORT}/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
echo ""

# ---- 验证 ----
echo ""
echo -e "${BOLD}━━━━━━━━━━━ 服务健康检查 ━━━━━━━━━━━${NC}"
echo ""

check() {
    local name="$1" url="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
        success "$name — HTTP $code"
    else
        warn "$name — HTTP $code (可能需要再等几秒)"
    fi
}

check "API 健康检查"  "http://localhost:${API_PORT}/health"
check "设备列表"      "http://localhost:${API_PORT}/streams"
check "HTTP 观看页"   "http://localhost:${HTTP_PORT}/"
check "HTTPS OTA 页"  "https://localhost:${HTTPS_PORT}/ota/"

# ---- 输出访问地址 ----
# 尝试获取本机 IP
detect_ip() {
    if [ -n "$SERVER_IP" ]; then
        echo "$SERVER_IP"
    else
        hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
    fi
}
LOCAL_IP=$(detect_ip)

echo ""
echo -e "${BOLD}━━━━━━━━━━━ 访问地址 ━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}浏览器观看:${NC}  ${GREEN}http://${LOCAL_IP}:${HTTP_PORT}/?key=iphone${NC}"
echo -e "  ${BOLD}iOS 原生播放:${NC} ${GREEN}http://${LOCAL_IP}:${HTTP_PORT}/hls/iphone.m3u8${NC}"
echo -e "  ${BOLD}VLC/ffplay:${NC}   ${GREEN}rtmp://${LOCAL_IP}:${RTMP_PORT}/live/iphone${NC}"
echo ""
echo -e "  ${BOLD}iOS OTA 安装:${NC} ${GREEN}https://${LOCAL_IP}:${HTTPS_PORT}/ota/${NC}"
echo -e "  ${BOLD}API 设备列表:${NC} ${GREEN}http://${LOCAL_IP}:${API_PORT}/streams${NC}"
echo ""

# ─── iOS 推流 URL ─────────────────────────────
echo -e "${BOLD}━━━━━━━━━━━ iOS 端配置 ━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}RTMP 推流地址:${NC}"
echo -e "  ${GREEN}rtmp://${LOCAL_IP}:${RTMP_PORT}/live/iphone${NC}"
echo ""
echo -e "  ${YELLOW}将此地址填入 ScreenCapture App 中保存${NC}"
echo ""

# ─── OTA 安装提示 ─────────────────────────────
echo -e "${BOLD}━━━━━━━━━━━ OTA 安装 ━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. 将 ScreenCapture.ipa 放入 ${CYAN}server/www/ota/${NC}"
echo -e "  2. 在 ${CYAN}server/www/ota/index.html${NC} 和 ${CYAN}manifest.plist${NC}"
echo -e "     中把 ${YELLOW}YOUR_SERVER${NC} 替换为 ${GREEN}${LOCAL_IP}${NC}"
echo -e "  3. iPhone Safari 打开:"
echo -e "     ${GREEN}https://${LOCAL_IP}:${HTTPS_PORT}/ota/${NC}"
echo ""

echo -e "${GREEN}${BOLD}✅ 部署完成!${NC}"
echo ""
echo -e "  停止服务: ${CYAN}cd server && $COMPOSE down${NC}"
echo -e "  查看日志: ${CYAN}cd server && $COMPOSE logs -f${NC}"
echo ""
