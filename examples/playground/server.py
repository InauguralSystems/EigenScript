#!/usr/bin/env python3
"""
EigenSpace Compilation Server
Hosts the compiler as a local API for the interactive playground.
"""

import http.server
import socketserver
import json
import subprocess
import os
import tempfile
import sys

PORT = 8080
# Adjust paths relative to where this script lives
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../"))
COMPILER_MODULE = "eigenscript.compiler.cli.compile"


class CompilerHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler that compiles EigenScript code to WebAssembly."""

    def do_GET(self):
        """Serve static files, redirecting / to /index.html"""
        if self.path == "/":
            self.path = "/index.html"
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        """Handle compilation requests."""
        if self.path == "/compile":
            content_length = int(self.headers["Content-Length"])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data)
            source_code = data.get("code", "")

            # Use a temp dir to avoid clutter
            with tempfile.TemporaryDirectory() as tmpdir:
                source_file = os.path.join(tmpdir, "main.eigs")
                wasm_file = os.path.join(tmpdir, "main.wasm")

                with open(source_file, "w") as f:
                    f.write(source_code)

                # Invoke your compiler via python -m
                cmd = [
                    sys.executable,
                    "-m",
                    COMPILER_MODULE,
                    source_file,
                    "--target",
                    "wasm32-unknown-unknown",
                    "--exec",
                    "-o",
                    wasm_file,
                ]

                print(f"🔨 Compiling: {' '.join(cmd)}")
                # Run compilation from Project Root so imports work
                result = subprocess.run(
                    cmd, capture_output=True, text=True, cwd=PROJECT_ROOT
                )

                if result.returncode != 0:
                    # Sanitize error message to remove sensitive system paths
                    error_msg = result.stderr + "\n" + result.stdout
                    # Replace temp directory paths with generic marker
                    error_msg = error_msg.replace(tmpdir, "<temp>")
                    # Replace project root path
                    error_msg = error_msg.replace(PROJECT_ROOT, "<project>")
                    self._send_json(400, {"error": error_msg})
                    print(f"❌ Compilation failed")
                else:
                    if os.path.exists(wasm_file):
                        with open(wasm_file, "rb") as f:
                            wasm_bytes = f.read()
                        self._send_binary(200, wasm_bytes)
                        print(
                            f"✅ Compilation successful! Generated {len(wasm_bytes)} bytes"
                        )
                    else:
                        self._send_json(
                            500,
                            {"error": "Compilation succeeded but WASM file not found"},
                        )
                        print(f"❌ WASM file not found after compilation")
        else:
            self.send_error(404)

    def _send_json(self, code, data):
        """Send a JSON response with CORS headers."""
        self.send_response(code)
        self.send_header("Content-type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def _send_binary(self, code, data):
        """Send a binary response with CORS headers."""
        self.send_response(code)
        self.send_header("Content-type", "application/wasm")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)


def main():
    """Start the EigenSpace compilation server."""
    print("=" * 60)
    print("🚀 EigenSpace Compilation Server")
    print("=" * 60)
    print(f"📍 Server running at http://localhost:{PORT}")
    print(f"📂 Project Root: {PROJECT_ROOT}")
    print()
    print("📋 Endpoints:")
    print(f"   • POST /compile - Compile EigenScript to WASM")
    print(f"   • GET  /        - Serve playground HTML")
    print()
    print("Press Ctrl+C to stop the server")
    print("=" * 60)

    # Change to the playground directory so static files are served correctly
    os.chdir(os.path.dirname(__file__))

    try:
        with socketserver.TCPServer(("", PORT), CompilerHandler) as httpd:
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n\n👋 Server stopped")
        sys.exit(0)


if __name__ == "__main__":
    main()
