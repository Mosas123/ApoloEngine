#!/usr/bin/env python3
"""Serve the RTL fixture playlists to an iPhone on the same Wi-Fi."""
import http.server
import os
import socket

PORT = 8765
ROOT = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)


def lan_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


if __name__ == "__main__":
    ip = lan_ip()
    print(f"Fixtures on http://{ip}:{PORT}/stripped.m3u8")
    print(f"          http://{ip}:{PORT}/fixed.m3u8")
    print(f"          http://{ip}:{PORT}/original.m3u8")
    print("Ctrl+C to stop. The harness needs local HTTP allowed (ATS).")
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
