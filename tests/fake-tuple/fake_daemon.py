"""A stand-in for the Tuple daemon's socket, for the sign-in path only.

The plugin sends `auth <code>` straight to `$XDG_RUNTIME_DIR/tuple-0` (an 8-byte
payload length, an 8-byte argument count, NUL-terminated arguments) instead of
running `tuple auth`, so the code never appears on a command line. This serves
that one request, using the fake client's state directory: `good-code` signs in
when a login is pending; anything else gets an error that quotes the code, so
tests can check the panel never shows it. Every request is appended to
`$FAKE_TUPLE_STATE/socket` for assertions.
"""

import os
import socket
import struct
import threading
from pathlib import Path


def serve(socket_path, state_dir):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    server.listen(4)

    def handle(conn):
        with conn:
            header = conn.recv(16)
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
            with open(Path(state_dir) / "socket", "a") as log:
                log.write(" ".join(args) + "\n")
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
