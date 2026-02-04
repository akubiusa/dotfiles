#!/usr/bin/env python3
"""
Discord Webhook モックサーバ

テスト用の簡易 HTTP サーバで、Discord Webhook API をシミュレートします。
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys


class MockDiscordHandler(BaseHTTPRequestHandler):
    """Discord Webhook リクエストを処理するハンドラ"""

    def do_POST(self):
        """POST リクエストを処理"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)

        try:
            payload = json.loads(post_data.decode('utf-8'))
            print(
                f"[MOCK SERVER] Received webhook: {payload.get('content', 'N/A')}",
                file=sys.stderr
            )

            # Discord の成功レスポンスをシミュレート
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode())
        except Exception as e:
            print(f"[MOCK SERVER] Error: {e}", file=sys.stderr)
            self.send_response(400)
            self.end_headers()

    def log_message(self, format, *args):
        """ログを stderr に出力してテストログと混ざらないようにする"""
        sys.stderr.write(f"[MOCK SERVER] {format % args}\n")


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('localhost', port), MockDiscordHandler)
    print(f"[MOCK SERVER] Starting on port {port}", file=sys.stderr)
    server.serve_forever()
