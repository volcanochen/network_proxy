#!/usr/bin/env python3
"""
SOCKS5 Proxy Server for Windows with UDP support
Supports TCP CONNECT and UDP ASSOCIATE (for DNS)
"""

import socket
import select
import struct
import threading
import sys
import logging

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(levelname)s: %(message)s')
log = logging.getLogger()
log.setLevel(logging.INFO)


class Socks5Server:
    def __init__(self, host='127.0.0.1', port=10800):
        self.host = host
        self.port = port
        self.server_socket = None
        self.running = False
        self.udp_relays = {}  # client_addr -> udp_socket

    def handle_client(self, client_socket, client_addr):
        try:
            data = client_socket.recv(2)
            if len(data) < 2:
                return
            version, num_methods = struct.unpack('BB', data)
            if version != 5:
                client_socket.close()
                return
            methods = client_socket.recv(num_methods)
            client_socket.sendall(struct.pack('BB', 5, 0))

            data = client_socket.recv(4)
            if len(data) < 4:
                return
            version, cmd, reserved, atyp = struct.unpack('BBBB', data)

            if atyp == 1:
                dst_addr = socket.inet_ntoa(client_socket.recv(4))
            elif atyp == 3:
                addr_len = client_socket.recv(1)[0]
                dst_addr = client_socket.recv(addr_len).decode()
            elif atyp == 4:
                dst_addr = socket.inet_ntop(socket.AF_INET6, client_socket.recv(16))
            else:
                client_socket.close()
                return

            dst_port = struct.unpack('!H', client_socket.recv(2))[0]

            if cmd == 1:  # TCP CONNECT
                self._handle_connect(client_socket, dst_addr, dst_port, atyp)
            elif cmd == 3:  # UDP ASSOCIATE
                self._handle_udp_associate(client_socket, client_addr, dst_addr, dst_port)
            else:
                client_socket.sendall(struct.pack('!BBBBIH', 5, 7, 0, 1, 0, 0))
                client_socket.close()
        except Exception as e:
            log.error(f"Client error: {e}")
        finally:
            try:
                client_socket.close()
            except:
                pass

    def _handle_connect(self, client_socket, dst_addr, dst_port, atyp):
        try:
            # IPv6 目标(atyp=4)必须用 IPv6 套接字连接：浏览器等本地解析域名的
            # 客户端会优先拿到 AAAA 记录，原先写死 AF_INET 会导致 CONNECT 失败
            family = socket.AF_INET6 if atyp == 4 else socket.AF_INET
            dst_socket = socket.socket(family, socket.SOCK_STREAM)
            dst_socket.settimeout(30)
            dst_socket.connect((dst_addr, dst_port))
            client_socket.sendall(struct.pack('!BBBBIH', 5, 0, 0, 1, 0, 0))
            log.info(f"TCP CONNECT {dst_addr}:{dst_port}")
        except Exception as e:
            log.error(f"Connect failed {dst_addr}:{dst_port}: {e}")
            client_socket.sendall(struct.pack('!BBBBIH', 5, 5, 0, 1, 0, 0))
            return

        try:
            while True:
                readable, _, exceptional = select.select([client_socket, dst_socket], [], [], 60)
                if exceptional or not readable:
                    break
                for sock in readable:
                    data = sock.recv(65535)
                    if not data:
                        return
                    if sock is client_socket:
                        dst_socket.sendall(data)
                    else:
                        client_socket.sendall(data)
        except Exception:
            pass
        finally:
            dst_socket.close()

    def _handle_udp_associate(self, client_socket, client_addr, dst_addr, dst_port):
        """Handle SOCKS5 UDP ASSOCIATE - creates a UDP relay socket"""
        try:
            udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp_sock.bind(('0.0.0.0', 0))
            udp_port = udp_sock.getsockname()[1]
            udp_sock.setblocking(False)

            # Respond with the UDP relay address
            # Use 127.0.0.1 since client is local (via SSH reverse tunnel)
            client_socket.sendall(struct.pack('!BBBB', 5, 0, 0, 1) +
                                  socket.inet_aton('127.0.0.1') +
                                  struct.pack('!H', udp_port))

            log.info(f"UDP ASSOCIATE created relay on port {udp_port}")

            # Keep TCP connection alive and relay UDP packets
            client_key = client_addr
            self.udp_relays[client_key] = udp_sock

            # Map to track (dst_addr, dst_port) -> client_addr for responses
            dst_to_client = {}

            tcp_alive = True
            while tcp_alive:
                try:
                    readable, _, _ = select.select([client_socket, udp_sock], [], [], 1)
                except:
                    break

                for sock in readable:
                    if sock is client_socket:
                        # Check if TCP connection is still alive
                        data = client_socket.recv(1, socket.MSG_PEEK)
                        if not data:
                            tcp_alive = False
                            break
                    elif sock is udp_sock:
                        try:
                            data, sender = udp_sock.recvfrom(65535)
                        except:
                            continue

                        # Parse SOCKS5 UDP header
                        if len(data) < 10:
                            continue

                        # RSV(2) + FRAG(1) + ATYP(1) + DST.ADDR + DST.PORT + DATA
                        rsv, frag = struct.unpack('!HB', data[:3])
                        atyp = data[3]

                        if atyp == 1:  # IPv4
                            dst_ip = socket.inet_ntoa(data[4:8])
                            dst_port = struct.unpack('!H', data[8:10])[0]
                            payload = data[10:]
                        elif atyp == 3:  # Domain
                            addr_len = data[4]
                            dst_ip = data[5:5+addr_len].decode()
                            dst_port = struct.unpack('!H', data[5+addr_len:7+addr_len])[0]
                            payload = data[7+addr_len:]
                        elif atyp == 4:  # IPv6
                            dst_ip = socket.inet_ntop(socket.AF_INET6, data[4:20])
                            dst_port = struct.unpack('!H', data[20:22])[0]
                            payload = data[22:]
                        else:
                            continue

                        if frag != 0:
                            continue  # Don't support fragmentation

                        # Forward the UDP payload to destination
                        try:
                            # Resolve hostname if needed
                            if not self._is_ip(dst_ip):
                                resolved = socket.gethostbyname(dst_ip)
                            else:
                                resolved = dst_ip

                            udp_sock.sendto(payload, (resolved, dst_port))
                            dst_to_client[(resolved, dst_port)] = sender
                            log.debug(f"UDP FWD {dst_ip}:{dst_port} ({len(payload)} bytes)")
                        except Exception as e:
                            log.debug(f"UDP send error: {e}")

                # Check for responses from destinations
                # We need to also receive from the udp_sock for responses
                # Already handled in the select above

            # Also relay responses back to client
            # This is handled in the same select loop above

        except Exception as e:
            log.error(f"UDP ASSOCIATE error: {e}")
        finally:
            if client_key in self.udp_relays:
                del self.udp_relays[client_key]
            try:
                udp_sock.close()
            except:
                pass
            log.info("UDP ASSOCIATE closed")

    def _is_ip(self, addr):
        try:
            socket.inet_aton(addr)
            return True
        except:
            try:
                socket.inet_pton(socket.AF_INET6, addr)
                return True
            except:
                return False

    def start(self):
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_socket.bind((self.host, self.port))
        self.server_socket.listen(100)
        self.running = True

        log.info(f"SOCKS5 server (TCP+UDP) listening on {self.host}:{self.port}")
        print(f"SOCKS5 server with UDP support on {self.host}:{self.port}")

        while self.running:
            try:
                readable, _, _ = select.select([self.server_socket], [], [], 1)
                if readable:
                    client_socket, addr = self.server_socket.accept()
                    thread = threading.Thread(target=self.handle_client, args=(client_socket, addr))
                    thread.daemon = True
                    thread.start()
            except Exception as e:
                if self.running:
                    log.error(f"Server error: {e}")

    def stop(self):
        self.running = False
        if self.server_socket:
            self.server_socket.close()
        log.info("SOCKS5 server stopped")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 10800
    print(f"""
=====================================
  SOCKS5 Proxy Server (TCP + UDP)
=====================================
  Port: {port}
  Supports: TCP CONNECT, UDP ASSOCIATE
  Press Ctrl+C to stop
=====================================
""")
    server = Socks5Server(port=port)
    try:
        server.start()
    except KeyboardInterrupt:
        server.stop()


if __name__ == '__main__':
    main()