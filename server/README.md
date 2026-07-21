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
