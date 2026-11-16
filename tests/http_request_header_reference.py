"""Independent byte oracle transcribed from #2373 Decision, before C changes.

No server output supplies an expectation. The server's documented framing
search stops at NUL; line ends are CR LF, never either byte alone.
"""
import hashlib

TOKEN = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
LONG_NAME = b'x-' + b'n' * 62
NAMES = (b'origin', b'cookie', b'authorization', b'x-a', b'x-v', LONG_NAME)
NO_REQUEST = 'http_request_header: no request is being answered'


class Refusal(Exception):
    def __init__(self, kind, message):
        self.kind, self.message = kind, message


def request_headers(request):
    """Head including its empty line, or today's text if none was framed."""
    if request is None:
        return b''
    text = request.split(b'\0', 1)[0]
    end = text.find(b'\r\n\r\n')
    return text if end < 0 else text[:end + 4]


def request_header(request, name):
    # Bytes represent the language string's bytes, including non-UTF8 strings.
    if not isinstance(name, bytes):
        raise Refusal('type_mismatch', 'http_request_header: name must be a string')
    if not 1 <= len(name) <= 64 or any(c not in TOKEN for c in name):
        raise Refusal('value', 'http_request_header: invalid header name')
    if request is None:
        raise Refusal('value', NO_REQUEST)
    text = request.split(b'\0', 1)[0]
    end = text.find(b'\r\n\r\n')
    if end < 0:
        return []
    # The first complete CR LF line is always the request line.
    lines = text[:end + 2].split(b'\r\n')[1:-1]
    values = []
    for line in lines:
        key, colon, value = line.partition(b':')
        if colon and key and all(c in TOKEN for c in key) and key.lower() == name.lower():
            values.append(value.strip(b' \t'))
    return values


def describe(name, values):
    parts = [name, str(len(values)).encode()]
    for value in values:
        parts.extend((str(len(value)).encode(), hashlib.sha256(value).hexdigest().encode()))
    return b' '.join(parts) + b'\n'


def answer(request):
    result = b''.join(describe(name, request_header(request, name)) for name in NAMES)
    head = request_headers(request)
    return result + b'head ' + str(len(head)).encode() + b' ' + hashlib.sha256(head).hexdigest().encode() + b'\n'
