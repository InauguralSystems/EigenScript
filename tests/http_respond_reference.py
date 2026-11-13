"""Byte oracle transcribed from #2351's Decision before the C implementation.

No runtime output is used as an expectation. ``calls`` describes successful
http_respond calls; refusals are atomic, so callers omit refused calls.
"""

PHRASES = {
    200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
    301: "Moved Permanently", 302: "Found", 303: "See Other",
    304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
    405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict",
    410: "Gone", 413: "Payload Too Large", 415: "Unsupported Media Type",
    422: "Unprocessable Content", 429: "Too Many Requests",
    431: "Request Header Fields Too Large", 500: "Internal Server Error",
    502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
}


def response_bytes(calls, body, method="GET", cors_lines=(), registered=()):
    """Apply Several calls, then emit What is sent, in its specified order."""
    status, headers, cookies = 200, {}, []
    for call in calls:
        if "status" in call:
            status = int(call["status"])
        for name, value in call.get("headers", {}).items():
            key = name.lower()
            spelling = headers[key][0] if key in headers else name
            headers[key] = (spelling, value)
        cookies.extend(call.get("cookies", []))
    payload = body.encode("utf-8")
    lines = [f"HTTP/1.1 {status} {PHRASES.get(status, '')}"]
    consumed = {"content-type", "content-length", "cache-control", "connection"}

    def value(name, default):
        return headers.get(name.lower(), (name, default))[1]

    if status not in (204, 304):
        inferred = "application/json" if payload[:1] in (b"{", b"[") else "text/plain"
        lines += ["Content-Type: " + value("Content-Type", inferred),
                  "Content-Length: " + str(len(payload))]
    lines.append("Cache-Control: " + value("Cache-Control", "no-cache"))
    for name, default in cors_lines:
        lines.append(name + ": " + value(name, default))
        consumed.add(name.lower())
    lines.append("Connection: close")
    for name, default in registered:
        lines.append(name + ": " + value(name, default))
        consumed.add(name.lower())
    for key, (name, val) in headers.items():
        if key not in consumed:
            lines.append(name + ": " + val)
    lines.extend("Set-Cookie: " + cookie for cookie in cookies)
    result = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")
    if status not in (204, 304) and method != "HEAD":
        result += payload
    return result
