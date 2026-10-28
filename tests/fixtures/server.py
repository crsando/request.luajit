#!/usr/bin/env python3

import argparse
import gzip
import json
import socket
import ssl
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "request-fixture/1.0"
    concurrency_lock = threading.Lock()
    concurrency_active = 0
    concurrency_maximum = 0

    def log_message(self, format_string, *args):
        del format_string, args

    def _body(self):
        length = int(self.headers.get("content-length", "0"))
        return self.rfile.read(length)

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for name, value in headers or []:
            self.send_header(name, value)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
            self.wfile.flush()

    def _json(self, value, status=200, headers=None):
        body = json.dumps(value, sort_keys=True).encode("utf-8")
        response_headers = [("content-type", "application/json")]
        response_headers.extend(headers or [])
        self._send(status, body, response_headers)

    def _chunked(self, chunks, trailers=None):
        self.send_response(200)
        self.send_header("transfer-encoding", "chunked")
        if trailers:
            self.send_header("trailer", ", ".join(name for name, _ in trailers))
        self.end_headers()

        if self.command == "HEAD":
            return
        for chunk in chunks:
            self.wfile.write(("%x\r\n" % len(chunk)).encode("ascii"))
            self.wfile.write(chunk)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
        self.wfile.write(b"0\r\n")
        for name, value in trailers or []:
            self.wfile.write(("%s: %s\r\n" % (name, value)).encode("ascii"))
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _dispatch(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

        if parsed.path == "/get":
            self._json({
                "method": self.command,
                "query": query,
                "connection": self.client_address[1],
            })
        elif parsed.path == "/echo":
            body = self._body()
            self._send(200, body, [
                ("x-method", self.command),
                ("x-request-content-type", self.headers.get("content-type", "")),
            ])
        elif parsed.path == "/request-headers":
            self._json({name.lower(): value for name, value in self.headers.items()})
        elif parsed.path == "/redirect":
            self._send(302, b"", [("location", "/final"), ("x-redirect", "yes")])
        elif parsed.path == "/redirect-loop":
            self._send(302, b"", [("location", "/redirect-loop")])
        elif parsed.path == "/redirect-file":
            self._send(302, b"", [("location", "file:///etc/passwd")])
        elif parsed.path == "/final":
            self._send(200, b"redirected", [("x-final", "yes")])
        elif parsed.path.startswith("/status/"):
            status = int(parsed.path.rsplit("/", 1)[1])
            self._send(status, ("status-%d" % status).encode("ascii"))
        elif parsed.path == "/duplicate-headers":
            self._send(200, b"headers", [("x-value", "one"), ("x-value", "two")])
        elif parsed.path == "/delay":
            time.sleep(float(query.get("seconds", ["0.1"])[0]))
            self._send(200, b"delayed")
        elif parsed.path == "/concurrency/reset":
            with self.concurrency_lock:
                type(self).concurrency_active = 0
                type(self).concurrency_maximum = 0
            self._send(200, b"reset")
        elif parsed.path == "/concurrency/delay":
            with self.concurrency_lock:
                type(self).concurrency_active += 1
                type(self).concurrency_maximum = max(
                    type(self).concurrency_maximum,
                    type(self).concurrency_active,
                )
            try:
                time.sleep(float(query.get("seconds", ["0.05"])[0]))
                self._send(200, b"delayed")
            finally:
                with self.concurrency_lock:
                    type(self).concurrency_active -= 1
        elif parsed.path == "/concurrency/max":
            with self.concurrency_lock:
                maximum = type(self).concurrency_maximum
            self._send(200, str(maximum).encode("ascii"))
        elif parsed.path == "/large":
            size = int(query.get("size", ["65536"])[0])
            self._send(200, b"x" * size)
        elif parsed.path == "/large-header":
            size = int(query.get("size", ["4096"])[0])
            self._send(200, b"header", [("x-large", "x" * size)])
        elif parsed.path == "/empty":
            self._send(204)
        elif parsed.path == "/gzip":
            body = gzip.compress(b"compressed response")
            self._send(200, body, [("content-encoding", "gzip")])
        elif parsed.path == "/chunked":
            self._chunked([b"chunk-", b"one", b"-two"])
        elif parsed.path == "/trailers":
            self._chunked([b"trailer-body"], [("x-trailer", "available")])
        elif parsed.path == "/informational":
            self.send_response_only(103)
            self.send_header("link", "</style.css>; rel=preload")
            self.end_headers()
            self._send(200, b"informational")
        elif parsed.path == "/close-early":
            self.send_response(200)
            self.send_header("content-length", "64")
            self.end_headers()
            self.wfile.write(b"short")
            self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
        elif parsed.path == "/cookie/set":
            self._send(200, b"set", [("set-cookie", "session=available; Path=/")])
        elif parsed.path == "/cookie/check":
            cookie = self.headers.get("cookie", "")
            self._send(200, cookie.encode("utf-8"))
        elif parsed.path == "/auth":
            authorization = self.headers.get("authorization", "")
            if authorization == "Basic dXNlcjpwYXNz":
                self._send(200, b"authorized")
            else:
                self._send(401, b"unauthorized", [("www-authenticate", "Basic")])
        elif parsed.path == "/connection":
            self._send(200, str(self.client_address[1]).encode("ascii"))
        elif parsed.path == "/shutdown":
            self._send(200, b"bye")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self._send(404, b"not-found")

    do_GET = _dispatch
    do_HEAD = _dispatch
    do_POST = _dispatch
    do_PUT = _dispatch
    do_PATCH = _dispatch
    do_DELETE = _dispatch
    do_PROPFIND = _dispatch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--client-ca")
    args = parser.parse_args()

    # socketserver's default listen backlog is 5. Linux keeps excess SYNs
    # waiting, but macOS resets them, which breaks the concurrent-requests
    # test (12 parallel connections) with "Connection reset by peer".
    class Server(ThreadingHTTPServer):
        request_queue_size = 128
        daemon_threads = True

    server = Server((args.host, args.port), Handler)
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        if args.client_ca:
            context.load_verify_locations(args.client_ca)
            context.verify_mode = ssl.CERT_REQUIRED
        server.socket = context.wrap_socket(server.socket, server_side=True)

    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
