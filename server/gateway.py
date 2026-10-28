#!/usr/bin/env python3
"""Optional, operator-provisioned WatchMind AI quota gateway; no active free tier bundled."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import socket
import sqlite3
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 128 * 1024
MAX_RESPONSE = 128 * 1024
MAX_OUTPUT = 12_000


@dataclass(frozen=True)
class Configuration:
    upstream_url: str
    upstream_key: str
    model: str
    clients: dict[str, str]  # secret token -> operator-assigned opaque account ID
    database: str
    daily_limit: int = 3
    max_inflight: int = 8

    def validate(self):
        url = urllib.parse.urlsplit(self.upstream_url)
        if (url.scheme != "https" or not url.hostname or url.username or url.password
                or url.query or url.fragment or not url.path.endswith("/chat/completions")):
            raise ValueError("Upstream must be a fixed HTTPS chat/completions URL without credentials or query")
        if not self.upstream_key or not self.upstream_key.isascii() or any(c.isspace() for c in self.upstream_key):
            raise ValueError("Invalid upstream key")
        if not self.model or len(self.model) > 200 or not self.model.isascii() or any(c.isspace() for c in self.model):
            raise ValueError("Invalid model")
        if not isinstance(self.clients, dict) or not self.clients or len(self.clients) > 1000:
            raise ValueError("Provision between 1 and 1000 client credentials")
        for token, account in self.clients.items():
            if (not isinstance(token, str) or not 24 <= len(token) <= 512 or not token.isascii()
                    or any(c.isspace() for c in token)
                    or not isinstance(account, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", account)):
                raise ValueError("Use strong ASCII bearer tokens and opaque account IDs")
        if not 1 <= self.daily_limit <= 1000 or not 1 <= self.max_inflight <= 64:
            raise ValueError("Quota or concurrency out of range")
        return self

    @classmethod
    def from_environment(cls):
        return cls(
            upstream_url=os.environ["WATCHMIND_UPSTREAM_URL"],
            upstream_key=os.environ["WATCHMIND_UPSTREAM_KEY"],
            model=os.environ["WATCHMIND_MODEL"],
            clients=json.loads(os.environ["WATCHMIND_CLIENT_TOKENS_JSON"]),
            database=os.environ.get("WATCHMIND_QUOTA_DB", "./quota.sqlite3"),
            daily_limit=int(os.environ.get("WATCHMIND_DAILY_LIMIT", "3")),
            max_inflight=int(os.environ.get("WATCHMIND_MAX_INFLIGHT", "8")),
        ).validate()


class Quota:
    """Reservations survive process death; they fail closed until their UTC day ends."""
    def __init__(self, path: str, limit: int):
        self.path, self.limit = path, limit
        with self._db() as db:
            db.execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, account TEXT NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL)")
            db.execute("CREATE INDEX IF NOT EXISTS requests_account_day ON requests(account, day)")
        os.chmod(path, 0o600)

    @contextmanager
    def _db(self):
        db = sqlite3.connect(self.path, timeout=5)
        try:
            with db:
                yield db
        finally:
            db.close()

    def reserve(self, account: str, now=None):
        now = now or datetime.now(timezone.utc)
        day = now.astimezone(timezone.utc).date().isoformat()
        cutoff = (now.astimezone(timezone.utc).date() - timedelta(days=30)).isoformat()
        digest = hashlib.sha256(account.encode()).hexdigest()
        request_id = uuid.uuid4().hex
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM requests WHERE day < ?", (cutoff,))
            count = db.execute("SELECT COUNT(*) FROM requests WHERE account=? AND day=?", (digest, day)).fetchone()[0]
            if count >= self.limit:
                return None
            db.execute("INSERT INTO requests VALUES (?, ?, ?, 'reserved')", (request_id, digest, day))
        return request_id

    def finish(self, request_id: str, success: bool):
        with self._db() as db:
            if success:
                db.execute("UPDATE requests SET status='complete' WHERE id=?", (request_id,))
            else:
                db.execute("DELETE FROM requests WHERE id=? AND status='reserved'", (request_id,))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def upstream_call(config: Configuration, payload: dict) -> dict:
    """Never retry or follow redirects, and never include upstream errors in client responses."""
    request = urllib.request.Request(config.upstream_url, data=json.dumps(payload).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + config.upstream_key, "Content-Type": "application/json"})
    opener = urllib.request.build_opener(NoRedirect())
    deadline = time.monotonic() + 45
    with opener.open(request, timeout=10) as response:
        chunks = []
        total = 0
        while total <= MAX_RESPONSE:
            if time.monotonic() >= deadline:
                raise TimeoutError("Upstream deadline")
            piece = response.read1(min(16 * 1024, MAX_RESPONSE + 1 - total))
            if not piece:
                break
            total += len(piece)
            chunks.append(piece)
        data = b"".join(chunks)
    if len(data) > MAX_RESPONSE:
        raise ValueError("Response limit")
    return json.loads(data)


def validate_payload(value, model):
    allowed = {"model", "messages", "max_tokens", "temperature", "stream"}
    if not isinstance(value, dict) or set(value) - allowed or value.get("model") != model:
        raise ValueError("Unsupported request")
    messages = value.get("messages")
    if not isinstance(messages, list) or not 1 <= len(messages) <= 64:
        raise ValueError("Invalid messages")
    characters = 0
    for message in messages:
        if (not isinstance(message, dict) or set(message) != {"role", "content"}
                or message["role"] not in ("system", "user", "assistant")
                or not isinstance(message["content"], str)):
            raise ValueError("Invalid message")
        characters += len(message["content"])
    tokens = value.get("max_tokens", 1200)
    temperature = value.get("temperature", 0.3)
    if (characters > 28_000 or type(tokens) is not int or not 1 <= tokens <= 2000
            or type(temperature) not in (int, float) or not 0 <= temperature <= 1
            or value.get("stream", False) is not False):
        raise ValueError("Unsupported limits")
    return {"model": model, "messages": messages, "max_tokens": tokens, "temperature": temperature, "stream": False}


def normalize_response(value, model):
    try:
        choice = value["choices"][0]
        content = choice["message"]["content"]
        if choice.get("finish_reason") in ("length", "content_filter"):
            raise ValueError("Incomplete response")
    except (KeyError, IndexError, TypeError):
        raise ValueError("Invalid response") from None
    if not isinstance(content, str) or not content.strip() or len(content) > MAX_OUTPUT:
        raise ValueError("Invalid content")
    # Do not forward provider tracing, usage metadata, headers, or debug fields.
    return {"model": model, "choices": [{"message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]}


class Gateway(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, config: Configuration, upstream=upstream_call):
        self.config = config.validate()
        self.quota = Quota(config.database, config.daily_limit)
        self.upstream = upstream
        self.slots = threading.BoundedSemaphore(config.max_inflight)
        super().__init__(address, Handler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # The default implementation prints exceptions and may expose request contents.
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "WatchMindGateway"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        payload = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def fail(self, status, code):
        self.reply(status, {"error": {"code": code, "message": code}})

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
        else:
            self.fail(404, "not_found")

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.fail(404, "not_found")
            return
        auth_headers = self.headers.get_all("Authorization", [])
        header = auth_headers[0] if len(auth_headers) == 1 else ""
        supplied = header[7:] if header.startswith("Bearer ") else ""
        account = None
        if len(supplied) <= 512 and supplied.isascii():
            for token, candidate in self.server.config.clients.items():
                if hmac.compare_digest(supplied, token):
                    account = candidate
        if account is None:
            self.fail(401, "unauthorized")
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or len(lengths[0]) > 10 or not lengths[0].isdigit():
            self.fail(400, "invalid_length")
            return
        length = int(lengths[0])
        if not 0 < length <= MAX_BODY:
            self.fail(413, "request_too_large")
            return
        if self.headers.get_content_type() != "application/json":
            self.fail(415, "json_required")
            return
        try:
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError("Incomplete body")
            payload = validate_payload(json.loads(data), self.server.config.model)
        except (ValueError, UnicodeError, socket.timeout):
            self.fail(400, "invalid_request")
            return
        reservation = None
        success = False
        try:
            reservation = self.server.quota.reserve(account)
            if reservation is None:
                self.fail(429, "daily_quota_exhausted")
                return
            result = normalize_response(self.server.upstream(self.server.config, payload), self.server.config.model)
            # Charge once a valid result exists, including if the client disconnects.
            self.server.quota.finish(reservation, True)
            success = True
            self.reply(200, result)
        except (urllib.error.URLError, OSError, ValueError, TypeError, sqlite3.Error):
            self.fail(502, "analysis_unavailable")
        finally:
            if reservation and not success:
                try:
                    self.server.quota.finish(reservation, False)
                except sqlite3.Error:
                    # Fail closed: an unreleased reservation consumes one allowance.
                    pass


def main():
    # Run behind a TLS reverse proxy. Do not expose this stdlib HTTP listener publicly.
    os.umask(0o077)
    config = Configuration.from_environment()
    Path(config.database).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    server = Gateway(("127.0.0.1", int(os.environ.get("WATCHMIND_PORT", "8088"))), config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
