#!/usr/bin/env python3
"""
개발용 no-cache HTTP 서버.
python3 -m http.server 대체용.
모든 응답에 Cache-Control: no-store 헤더 붙여서 브라우저/PWA 캐시 방지.

사용:
  ./scripts/dev-server.py          # 포트 8000
  ./scripts/dev-server.py 9000     # 포트 9000
"""
import http.server
import socketserver
import sys
import os
from urllib.parse import unquote, urlsplit


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        # SPA/PWA 편의: CORS 없음 (동일 origin이라 필요 없음)
        super().end_headers()

    def send_head(self):
        # .env, .git 같은 점 파일과 *.env 파일은 서빙하지 않는다 (키 유출 방지)
        parts = [p for p in unquote(urlsplit(self.path).path).split("/") if p]
        if any(p.startswith(".") or p.endswith(".env") for p in parts):
            self.send_error(404, "Not found")
            return None
        return super().send_head()

    def log_message(self, format, *args):
        # 조용하게 (403/404 등만 로그)
        code = str(args[1]) if len(args) > 1 else ""
        if code and (code.startswith("4") or code.startswith("5")):
            super().log_message(format, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    # 스크립트 위치와 무관하게 프로젝트 루트에서 서빙
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)

    socketserver.TCPServer.allow_reuse_address = True
    # 같은 네트워크의 다른 기기에서 접근하지 못하도록 로컬 전용으로 바인딩
    with socketserver.TCPServer(("127.0.0.1", port), NoCacheHandler) as httpd:
        print(f"dev-server: http://localhost:{port}/ (no-cache) — root: {root}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n중단됨.")


if __name__ == "__main__":
    main()
