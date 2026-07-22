"""ScreenCapture 设备管理 API
nginx-rtmp 推流/断流时回调，维护在线设备列表
"""
import json
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

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
        """解析 nginx-rtmp 回调的 URL-encoded 表单数据"""
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode()
        if not raw:
            return {}
        # nginx-rtmp 发送 application/x-www-form-urlencoded
        parsed = parse_qs(raw)
        # parse_qs 返回 {key: [value]}，展开为 {key: value}
        return {k: v[0] if isinstance(v, list) and len(v) == 1 else v for k, v in parsed.items()}

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
