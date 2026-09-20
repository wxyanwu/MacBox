#!/usr/bin/env python3
"""Loopback-only EPG acceptance fixture. Never use real account credentials."""
import argparse
import base64
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import time
from urllib.parse import urlsplit, parse_qs
from xml.sax.saxutils import escape

MEDIA = Path(__file__).resolve().parents[1] / "Docs/DemoSource/assets/media/demo-landscape.mp4"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Request URLs may contain test credentials; never log them.

    def send_bytes(self, body, kind="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        now = int(time.time())
        start = now // 60 * 60
        base = f"http://127.0.0.1:{self.server.server_port}"
        if url.path in ("/live.m3u", "/no-epg.m3u"):
            header = '#EXTM3U' + (f' url-tvg="{base}/epg.xml"' if url.path == "/live.m3u" else "")
            lines = [header]
            for channel in range(1, 4):
                lines += [f'#EXTINF:-1 tvg-id="{channel}" group-title="EPG Acceptance",Fixture {channel}',
                          f'{base}/media.mp4']
            return self.send_bytes(("\n".join(lines) + "\n").encode(), "audio/x-mpegurl")
        if url.path == "/epg.xml":
            if self.server.epg_failure:
                return self.send_bytes(b"EPG fixture unavailable", status=503)
            def stamp(value):
                return datetime.fromtimestamp(value, timezone(timedelta(hours=8))).strftime("%Y%m%d%H%M%S %z")
            rows = ['<?xml version="1.0" encoding="UTF-8"?><tv>']
            for channel in range(1, 3):
                rows.append(f'<channel id="{channel}"><display-name>Fixture {channel}</display-name></channel>')
                for index in range(-1, 10):
                    begin = start + index * 60
                    rows.append(f'<programme channel="{channel}" start="{stamp(begin)}" stop="{stamp(begin+60)}">'
                                f'<title>{escape(f"XMLTV {channel} · minute {begin // 60}")}</title></programme>')
            rows.append("</tv>")
            return self.send_bytes("".join(rows).encode(), "application/xml")
        if url.path == "/player_api.php":
            action = query.get("action", [""])[0]
            if not action:
                value = {"user_info": {"auth": 1, "status": "Active", "allowed_output_formats": ["ts", "m3u8"]},
                         "server_info": {"timezone": "Asia/Shanghai"}}
            elif action == "get_live_categories":
                value = [{"category_id": "epg", "category_name": "EPG Acceptance", "parent_id": 0}]
            elif action == "get_live_streams":
                value = [{"stream_id": str(i), "name": f"Native Fixture {i}", "num": i,
                          "category_id": "epg", "stream_type": "live", "epg_channel_id": f"xml-{i}"} for i in range(1, 13)]
            elif action == "get_short_epg":
                if self.server.epg_delay:
                    time.sleep(self.server.epg_delay)
                if self.server.epg_failure:
                    return self.send_bytes(b"EPG fixture unavailable", status=503)
                user = query.get("username", ["fixture"])[0]
                stream = query.get("stream_id", ["1"])[0]
                rows = []
                if user != "empty" and stream != "3":
                    for index in range(4):
                        begin = start + index * 60
                        title = f"Native {stream} · minute {begin // 60}"
                        rows.append({"start_timestamp": str(begin), "stop_timestamp": begin+60,
                                     "title": base64.b64encode(title.encode()).decode()})
                value = {"epg_listings": rows}
            elif action.startswith("get_"):
                value = []
            else:
                return self.send_bytes(b"{}", status=404)
            return self.send_bytes(json.dumps(value).encode())
        if url.path == "/media.mp4" or url.path.startswith("/live/"):
            if not MEDIA.is_file():
                return self.send_bytes(b"Fixture media missing", status=404)
            return self.send_bytes(MEDIA.read_bytes(), "video/mp4")
        return self.send_bytes(b"Not found", status=404)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--epg-delay", type=float, default=0, help="Delay EPG only; media/catalog remain immediate")
    parser.add_argument("--epg-failure", action="store_true", help="Return 503 for EPG only")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.epg_delay = max(0, min(60, args.epg_delay))
    server.epg_failure = args.epg_failure
    print(f"Local fixture: http://127.0.0.1:{args.port}/live.m3u", flush=True)
    print("Xtream: same base address; use fixture/fixture, or empty/fixture for empty EPG.", flush=True)
    print("Programme boundaries occur every minute. Media is a short finite smoke-test clip, not a live stream.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
