#!/usr/bin/env python3
"""B6: one loopback POST; answer the exact received X-Number header bytes."""
import pathlib
import socket
import sys

url_file, log_file = map(pathlib.Path, sys.argv[1:])
with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(65)
    url_file.write_text('http://127.0.0.1:%d/capture\n' % listener.getsockname()[1])
    with listener.accept()[0] as connection:
        connection.settimeout(60)
        request = b''
        while b'\r\n\r\n' not in request:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError('HTTP request ended before its headers')
            request += chunk
            log_file.write_bytes(request)
        headers, body = request.split(b'\r\n\r\n', 1)
        fields = {}
        for line in headers.split(b'\r\n')[1:]:
            key, value = line.split(b':', 1)
            fields[key.lower()] = value.lstrip(b' \t')
        size = int(fields.get(b'content-length', b'0'))
        while len(body) < size:
            chunk = connection.recv(min(65536, size - len(body)))
            if not chunk:
                raise RuntimeError('HTTP request ended before Content-Length')
            body += chunk
            log_file.write_bytes(headers + b'\r\n\r\n' + body)
        log_file.write_bytes(headers + b'\r\n\r\n' + body)
        answer = fields.get(b'x-number', b'MISSING')
        connection.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ' +
                           str(len(answer)).encode('ascii') + b'\r\n\r\n' + answer)
