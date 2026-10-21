#!/usr/bin/env python3
"""Stand-in for the Mac input agent (greenfield-inserter), speaking the same HTTP API without inserting anything.

Accepted texts are printed as JSON lines and, with --log FILE, appended to that file, so a test can check exactly what arrived.
Simulate the refusal paths with --locked and --secure-input. Standard library only.

    python3 tools/stub-receiver/receiver.py --host 0.0.0.0 --port 47821 --key secret --log /tmp/received.jsonl
"""
import argparse
import collections
import json
import socket
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 262144
REMEMBERED_IDS = 100


def sanitize(text):
    """NFC, control characters (newlines and tabs included) removed, ends trimmed. Returns '' when nothing is left."""
    text = unicodedata.normalize("NFC", text)
    text = "".join(" " if ch in "\r\n\t" else ch for ch in text)
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Cc")
    return " ".join(text.split())


class State:
    def __init__(self, key=None, locked=False, secure_input=False, log=None, name=None, echo=True):
        self.key = key
        self.echo = echo
        self.locked = locked
        self.secure_input = secure_input
        self.log = log
        self.name = name or socket.gethostname()
        self.started = time.time()
        self.seen = collections.OrderedDict()
        self.lock = threading.Lock()

    def accept(self, request_id, text):
        """Returns (duplicate, ms). Records the text."""
        with self.lock:
            if request_id in self.seen:
                return True, 0
            self.seen[request_id] = text
            while len(self.seen) > REMEMBERED_IDS:
                self.seen.popitem(last=False)
        start = time.perf_counter()
        line = json.dumps({"id": request_id, "text": text, "at": round(time.time(), 3)}, ensure_ascii=False)
        if self.echo:
            print(line, flush=True)
        if self.log:
            with open(self.log, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        return False, int((time.perf_counter() - start) * 1000)


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        disable_nagle_algorithm = True

        def log_message(self, *_args):
            pass

        def reply(self, status, body):
            data = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            return state.key is None or self.headers.get("X-Dictation-Key") == state.key

        def do_GET(self):
            if self.path != "/status":
                return self.reply(404, {"ok": False, "error": "not_found"})
            if not self.authorized():
                return self.reply(401, {"ok": False, "error": "unauthorized"})
            self.reply(200, {"ok": True, "service": "greenfield-inserter-stub", "version": "stub", "name": state.name,
                             "uptime_s": int(time.time() - state.started), "secure_input": state.secure_input,
                             "screen_locked": state.locked, "accessibility": True, "inserted_count": len(state.seen)})

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if self.path != "/text":
                self.rfile.read(min(length, MAX_BODY))
                return self.reply(404, {"ok": False, "error": "not_found"})
            if not self.authorized():
                self.rfile.read(min(length, MAX_BODY))
                return self.reply(401, {"ok": False, "error": "unauthorized"})
            if length > MAX_BODY:
                self.close_connection = True
                return self.reply(413, {"ok": False, "error": "too_large"})
            body = self.rfile.read(length)
            try:
                payload = json.loads(body.decode("utf-8"))
                request_id, text = payload["id"], sanitize(payload["text"])
                if not isinstance(request_id, str) or not request_id or not text:
                    raise ValueError("empty")
            except (ValueError, KeyError, TypeError, UnicodeDecodeError):
                return self.reply(422, {"ok": False, "error": "bad_request"})
            if state.locked:
                return self.reply(423, {"ok": False, "error": "screen_locked"})
            if state.secure_input:
                return self.reply(409, {"ok": False, "error": "secure_input"})
            duplicate, ms = state.accept(request_id, text)
            result = {"ok": True, "status": "inserted", "id": request_id, "duplicate": duplicate}
            if not duplicate:
                result["ms"] = ms
            self.reply(200, result)

    return Handler


def make_server(host, port, state):
    return ThreadingHTTPServer((host, port), make_handler(state))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47821)
    parser.add_argument("--key", help="required X-Dictation-Key value (omit to accept any request)")
    parser.add_argument("--log", help="append accepted texts to this file as JSON lines")
    parser.add_argument("--name", help="name reported by /status")
    parser.add_argument("--locked", action="store_true", help="simulate a locked session (423)")
    parser.add_argument("--secure-input", action="store_true", help="simulate a focused password field (409)")
    args = parser.parse_args()
    state = State(key=args.key, locked=args.locked, secure_input=args.secure_input, log=args.log, name=args.name)
    server = make_server(args.host, args.port, state)
    print(f"stub receiver on http://{args.host}:{server.server_address[1]} (key {'set' if args.key else 'none'})",
          flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
