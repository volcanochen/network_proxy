#!/usr/bin/env python3
"""
http_relay.py —— HTTP CONNECT 代理转发器（部署在服务器侧，纯标准库）

作用：LM Studio 的守护进程(llmster)内置 Node 网络栈不支持 socks5h:// 环境变量，
只认 HTTP 代理。本脚本在服务器 127.0.0.1:10808 起一个 HTTP 代理（支持 CONNECT
与绝对 URI 两种形式），把流量转发进 SSH 反向隧道暴露的 SOCKS5 端口
（127.0.0.1:10800），由 Windows 本机代理解析域名并访问外网。

用法: python3 http_relay.py [监听端口=10808] [SOCKS端口=10800]
"""
import select
import socket
import struct
import sys
import threading

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 10808
SOCKS_HOST, SOCKS_PORT = "127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 10800


def socks5_connect(host: str, port: int) -> socket.socket:
    """向本地 SOCKS5 代理发起 CONNECT（域名交由代理端解析，即 socks5h 行为）。"""
    s = socket.create_connection((SOCKS_HOST, SOCKS_PORT), timeout=15)
    s.sendall(struct.pack("BBB", 5, 1, 0))  # VER=5, NMETHODS=1, method=NO AUTH
    resp = s.recv(2)
    if len(resp) < 2 or resp[0] != 5 or resp[1] != 0:
        raise OSError("socks5 auth failed")
    host_b = host.encode()
    # VER CMD RSV ATYP(域名=3) ADDR PORT
    s.sendall(struct.pack("!BBBB", 5, 1, 0, 3) + bytes([len(host_b)]) + host_b
              + struct.pack("!H", port))
    rep = s.recv(32)
    if len(rep) < 10 or rep[1] != 0:
        raise OSError(f"socks5 connect refused: {rep.hex() if rep else 'closed'}")
    return s


def pump(a: socket.socket, b: socket.socket):
    """双向并发转发：任一方向就绪即转发，另一端断开则收尾。"""
    try:
        socks = [a, b]
        while socks:
            readable, _, _ = select.select(socks, [], [], 300)
            for r in readable:
                try:
                    data = r.recv(65536)
                except OSError:
                    data = b""
                if not data:
                    other = b if r is a else a
                    for s in socks:
                        try:
                            s.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                    socks = []
                    break
                w = b if r is a else a
                try:
                    w.sendall(data)
                except OSError:
                    break
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except OSError:
                pass


def handle(client: socket.socket):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(4096)
            if not chunk:
                return
            buf += chunk
        first = buf.split(b"\r\n")[0].decode(errors="replace").split()
        method, target = first[0], first[1]

        if method.upper() == "CONNECT":
            host, _, port_s = target.rpartition(":")
            up = socks5_connect(host, int(port_s or 443))
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            pump(client, up)
        else:
            # 绝对 URI 形式的普通 HTTP 请求：解析目标后走 SOCKS，转发原始请求行
            rest = target.split("//", 1)[-1]
            authority, _, path = rest.partition("/")
            host, _, port_s = authority.rpartition(":")
            if not host:
                host, port_s = authority, "80"
            up = socks5_connect(host, int(port_s or 80))
            line = f"{method} /{path} HTTP/1.1".encode()
            up.sendall(line + b"\r\n" + buf.split(b"\r\n", 1)[1])
            pump(up, client)
            return
    except (OSError, ValueError) as e:
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            print(f"[relay] error: {e}", file=sys.stderr, flush=True)
        except OSError:
            pass
        try:
            client.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN_PORT))
    srv.listen(64)
    print(f"[relay] HTTP 127.0.0.1:{LISTEN_PORT} -> SOCKS5 {SOCKS_HOST}:{SOCKS_PORT}",
          flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
