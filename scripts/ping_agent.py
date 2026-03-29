#!/usr/bin/env python3
import socket, struct, json, os, sys

def main():
    path = os.path.expanduser(os.environ.get("ARMADILLO_SOCKET_PATH", "~/.armadillo/a.sock"))
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
    except Exception as e:
        print(f"connect error: {e}")
        sys.exit(1)

    body = json.dumps({"type": "ping", "v": 1}, separators=(",", ":")).encode()
    s.sendall(struct.pack(">I", len(body)) + body)

    def recv_exact(n):
        buf = b""
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                break
            buf += chunk
        return buf

    hdr = recv_exact(4)
    if len(hdr) != 4:
        print("no header or short read")
        sys.exit(2)
    (length,) = struct.unpack(">I", hdr)
    payload = recv_exact(length)
    if len(payload) != length:
        print(f"short payload: got {len(payload)} expected {length}")
        sys.exit(3)
    try:
        print(payload.decode())
    except Exception:
        print(payload)

if __name__ == "__main__":
    main()


