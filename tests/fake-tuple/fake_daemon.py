"""A stand-in for the Tuple daemon's socket: sign-in, and the HTTP API the
plugin uses for calls, joins and favorites.

The plugin sends `auth <code>` straight to `$XDG_RUNTIME_DIR/tuple-0` (an 8-byte
payload length, an 8-byte argument count, NUL-terminated arguments) instead of
running `tuple auth`, so the code never appears on a command line. This serves
that one request, using the fake client's state directory: `good-code` signs in
when a login is pending; anything else gets an error that quotes the code, so
tests can check the panel never shows it.

The JSON commands are HTTP requests on the same socket. Calls and joins put the
fake client in a call; contact 1012 and room slug `gone` answer with errors.
Every request is appended to `$FAKE_TUPLE_STATE/socket` for assertions, as
`auth <code>` or `METHOD path body`.
"""

import json

import os
import re
import socket
import struct
import threading
from pathlib import Path


def serve(socket_path, state_dir):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    server.listen(4)

    def log(line):
        with open(Path(state_dir) / "socket", "a") as f:
            f.write(line + "\n")

    def http(conn, data):
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        length = int((re.search(rb"(?i)content-length:\s*(\d+)", head) or [0, b"0"])[1])
        while len(body) < length:
            body += conn.recv(4096)
        method, path = head.split(b" ")[:2]
        method, path, body = method.decode(), path.decode(), body.decode()
        log(f"{method} {path} {body}".rstrip())
        status, answer = 200, {}
        if method == "POST" and path in ("/call", "/call/join"):
            if json.loads(body).get("user_id") == 1012:
                status, answer = 409, {"error": "Edsger Dijkstra declined"}
            else:
                (Path(state_dir) / "in_call").touch()
                answer = {"id": "00000000-0000-4000-8000-000000001001"}
        elif method == "GET" and path.startswith("/rooms/"):
            slug = path.split("/")[2]
            if slug == "gone":
                status, answer = 404, None
            else:
                answer = {"id": "room-id-" + slug, "slug": slug}
        payload = b"" if answer is None else json.dumps(answer).encode()
        conn.sendall(f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n"
                     f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)

    def handle(conn):
        with conn:
            header = conn.recv(16)
            if header.split(b" ")[0] in (b"GET", b"POST", b"DELETE"):
                http(conn, header)
                return
            if len(header) < 16:
                return
            length, _argc = struct.unpack("<QQ", header)
            payload = b""
            while len(payload) < length:
                chunk = conn.recv(length - len(payload))
                if not chunk:
                    break
                payload += chunk
            args = [a.decode() for a in payload.split(b"\0") if a]
            log(" ".join(args))
            if args[:1] != ["auth"] or len(args) != 2:
                reply = "error: unknown request\n"
            elif not (Path(state_dir) / "login_pending").exists():
                reply = "error: no auth session, run 'tuple login' first\n"
            elif args[1] == "good-code":
                (Path(state_dir) / "login_pending").unlink()
                (Path(state_dir) / "logged_in").touch()
                reply = "logged in\n"
            else:
                reply = f"error: invalid authorization code {args[1]}\n"
            conn.sendall(reply.encode())

    def loop():
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            handle(conn)

    threading.Thread(target=loop, daemon=True).start()
    return server
