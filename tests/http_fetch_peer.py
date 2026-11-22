#!/usr/bin/env python3
"""Independent #2375 peer: receive request bytes and send specified bytes.

No HTTP library is involved on either side of this fixture. Import Peer from
suite rows, or run this script with --plan JSON for a manually driven peer.
"""
from dataclasses import dataclass
import argparse
import contextlib
import json
from pathlib import Path
import socket
import struct
import threading
import time
from http_readiness import pick_port


@dataclass
class Plan:
    wire: bytes = b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
    delay: float = 0
    hold: float = 0
    reset: bool = False
    piece: int = 0
    drip: float = 0
    drip_body: bool = False
    endless: bool = False
    echo_target: bool = False


class Peer:
    def __init__(self, plans=None, tls=None, repeat=False, record_path=None, responder=None):
        self.plans = list(plans or [Plan()])
        self.repeat, self.tls, self.responder = repeat, tls, responder
        self.record_count = 0
        self.record_file = Path(record_path).open("wb") if record_path is not None else None
        self.requests, self.accepted, self.errors = [], 0, []
        self.lock, self.stop = threading.Lock(), threading.Event()
        self.threads, self.sockets = [], []
        self.port = pick_port()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(('127.0.0.1', self.port))
        self.listener.listen(64)
        self.listener.settimeout(.1)

    @property
    def url(self):
        return ('https' if self.tls else 'http') + f'://127.0.0.1:{self.port}'

    def __enter__(self):
        self.acceptor = threading.Thread(target=self.accept, daemon=True)
        self.acceptor.start()
        return self

    def __exit__(self, *_):
        self.close()

    def accept(self):
        while not self.stop.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self.lock:
                index = self.accepted
                self.accepted += 1
                self.sockets.append(sock)
            thread = threading.Thread(target=self.exchange, args=(sock, index), daemon=True)
            with self.lock:
                self.threads.append(thread)
            thread.start()

    def exchange(self, sock, index):
        owned_sockets = [sock]
        try:
            sock.settimeout(25)
            if self.tls:
                sock = self.tls.wrap_socket(sock, server_side=True,do_handshake_on_connect=False)
                # Publish the actual SSL socket before a blocking handshake,
                # so cleanup can interrupt a stalled or planted-fault client.
                with self.lock:
                    self.sockets.append(sock)
                    owned_sockets.append(sock)
                try:
                    sock.do_handshake()
                except OSError:  # an untrusted TLS peer legitimately refuses
                    return
            wire = b''
            while b'\r\n\r\n' not in wire:
                data = sock.recv(65536)
                if not data:
                    return
                wire += data
                if len(wire) > 20000000:
                    raise AssertionError('fixture request head exceeds hard safety bound')
            head, body = wire.split(b'\r\n\r\n', 1)
            lines = head.split(b'\r\n')
            headers = []
            for line in lines[1:]:
                name, sep, value = line.partition(b':')
                if not sep:
                    raise AssertionError(f'fixture malformed request header: {line[:100]!r}')
                headers.append((name, value[1:] if value.startswith(b' ') else value))
            lengths = [int(v.strip()) for k, v in headers if k.lower() == b'content-length']
            length = lengths[0] if lengths else 0
            while len(body) < length:
                data = sock.recv(min(65536, length - len(body)))
                if not data:
                    raise AssertionError('fixture request body ended early')
                body += data
            record = {'line': lines[0], 'headers': headers, 'body': body[:length],
                      'wire': head + b'\r\n\r\n' + body[:length]}
            with self.lock:
                self.record_count += 1
                if self.record_file is not None:
                    # Every original request byte is retained on disk; no
                    # per-call objects accumulate during the RSS workload.
                    raw = record['wire']
                    self.record_file.write(struct.pack('!I',len(raw)))
                    self.record_file.write(raw)
                else:
                    self.requests.append(record)
            if not self.repeat and index >= len(self.plans):
                raise AssertionError(f'unexpected extra connection {index+1}')
            plan = self.plans[index % len(self.plans)]
            if self.stop.wait(plan.delay):
                return
            response = self.responder(record) if self.responder is not None else plan.wire
            if plan.echo_target:
                target = lines[0].split(b' ')[1]
                response = b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(target)).encode() + b'\r\n\r\n' + target
            if plan.drip_body:
                head, sep, payload = response.partition(b'\r\n\r\n')
                sock.sendall(head+sep)
                response = payload
            if plan.piece:
                for start in range(0, len(response), plan.piece):
                    sock.sendall(response[start:start+plan.piece])
                    if self.stop.wait(plan.drip):
                        return
            else:
                sock.sendall(response)
            if plan.endless:
                while not self.stop.is_set():
                    sock.sendall(b'1\r\nx\r\n')
                    if self.stop.wait(plan.drip):
                        return
            if plan.hold:
                self.stop.wait(plan.hold)
            if plan.reset:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass  # expected when the candidate aborts on a limit or its timeout
        except OSError as exc:
            if not self.stop.is_set():
                self.errors.append(str(exc))
        except Exception as exc:
            self.errors.append(str(exc))
        finally:
            with contextlib.suppress(OSError):
                sock.close()
            with self.lock:
                for owned in owned_sockets:
                    if owned in self.sockets:
                        self.sockets.remove(owned)
                current = threading.current_thread()
                if current in self.threads:
                    self.threads.remove(current)

    def close(self):
        self.stop.set()
        self.listener.close()
        self.acceptor.join(2)
        with self.lock:
            sockets, threads = list(self.sockets), list(self.threads)
        for sock in sockets:
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(OSError):
                sock.close()
        for thread in threads:
            thread.join(2)
        if self.record_file is not None:
            self.record_file.close()
        if any(t.is_alive() for t in [self.acceptor] + threads):
            raise AssertionError('fixture worker survived cleanup')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--plan', required=True)
    args = parser.parse_args()
    plans = [Plan(bytes.fromhex(p['wire'])) for p in json.loads(open(args.plan).read())]
    with Peer(plans) as peer:
        print(peer.port, flush=True)
        try:
            while peer.accepted < len(plans):
                time.sleep(.05)
            for thread in list(peer.threads):
                thread.join(25)
            print(json.dumps([{k: v.hex() if isinstance(v, bytes) else [(a.hex(), b.hex()) for a, b in v]
                               for k, v in row.items()} for row in peer.requests]))
        except KeyboardInterrupt:
            pass
