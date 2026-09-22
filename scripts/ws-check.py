#!/usr/bin/env python3
"""Minimal gotty WebSocket check: handshake, webtty init, read terminal output.

    ws-check.py <host> <port> <user> <pass> [plain|tls] [seconds]

No dependencies. Exits 0 when the upgrade succeeds and base64 terminal output
arrives, which is the whole point: gotty carries a real TTY over WebSocket.
"""

import base64
import json
import os
import socket
import ssl
import sys
import time

host, port, user, password = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
use_tls = len(sys.argv) > 5 and sys.argv[5] in ("tls", "1", "yes")
seconds = float(sys.argv[6]) if len(sys.argv) > 6 else 6.0

raw = socket.create_connection((host, port), timeout=15)
sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host) if use_tls else raw


def send_text(payload: bytes):
    """Client frames must be masked (RFC 6455)."""
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    header = b"\x81"
    n = len(masked)
    if n < 126:
        header += bytes([0x80 | n])
    else:
        header += bytes([0x80 | 126]) + n.to_bytes(2, "big")
    sock.sendall(header + mask + masked)


key = base64.b64encode(os.urandom(16)).decode()
auth = base64.b64encode(f"{user}:{password}".encode()).decode()
sock.sendall(
    (
        "GET /ws HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Protocol: webtty\r\n"
        f"Authorization: Basic {auth}\r\n"
        "\r\n"
    ).encode()
)

buf = b""
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(4096)
    if not chunk:
        break
    buf += chunk
head, _, data = buf.partition(b"\r\n\r\n")
status = head.split(b"\r\n", 1)[0].decode()
negotiated = [l for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-protocol")]
print(f"handshake: {status}  {negotiated[0].decode() if negotiated else ''}")
if "101" not in status:
    print(head.decode(errors="replace"))
    sys.exit(1)

# webtty init (plain JSON, no type prefix) then collect output frames.
send_text(json.dumps({"Arguments": "", "AuthToken": f"{user}:{password}"}).encode())

output = b""
deadline = time.time() + seconds
sock.settimeout(0.5)
while time.time() < deadline:
    if len(data) < 2:
        try:
            data += sock.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        continue
    b1 = data[1]
    length = b1 & 0x7F
    offset = 2
    if length == 126:
        length = int.from_bytes(data[2:4], "big")
        offset = 4
    elif length == 127:
        length = int.from_bytes(data[2:10], "big")
        offset = 8
    if len(data) < offset + length:
        try:
            data += sock.recv(65536)
        except (socket.timeout, OSError):
            continue
        continue
    frame, data = data[offset : offset + length], data[offset + length :]
    if frame[:1] == b"1":  # webtty Output
        try:
            output += base64.b64decode(frame[1:])
        except Exception:  # noqa: BLE001
            pass

text = output.decode("utf-8", "replace")
print(f"terminal output: {len(output)} bytes")
print("sample:", repr(text[:120]))
sys.exit(0 if output else 1)
