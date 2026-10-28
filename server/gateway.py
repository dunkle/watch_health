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
    # None deliberately means no more paid attempts than the successful-result allowance.
    daily_attempt_limit: int | None = None
    account_rate_limit: int = 3
    global_daily_attempt_limit: int = 1000
    breaker_failure_limit: int = 5
    breaker_cooldown_seconds: int = 60

    @property
    def attempt_limit(self):
        return self.daily_limit if self.daily_attempt_limit is None else self.daily_attempt_limit

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
        limits = [(self.daily_limit, 1, 1000), (self.max_inflight, 1, 64),
                  (self.attempt_limit, 1, 10000), (self.account_rate_limit, 1, 1000),
                  (self.global_daily_attempt_limit, 1, 1000000),
                  (self.breaker_failure_limit, 1, 1000), (self.breaker_cooldown_seconds, 1, 3600)]
        if any(type(value) is not int or not lower <= value <= upper for value, lower, upper in limits):
            raise ValueError("Quota, rate, circuit, or concurrency out of range")
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
            daily_attempt_limit=int(os.environ["WATCHMIND_DAILY_ATTEMPT_LIMIT"]) if "WATCHMIND_DAILY_ATTEMPT_LIMIT" in os.environ else None,
            account_rate_limit=int(os.environ.get("WATCHMIND_ACCOUNT_RATE_LIMIT", "3")),
            global_daily_attempt_limit=int(os.environ.get("WATCHMIND_GLOBAL_DAILY_ATTEMPT_LIMIT", "1000")),
            breaker_failure_limit=int(os.environ.get("WATCHMIND_BREAKER_FAILURE_LIMIT", "5")),
            breaker_cooldown_seconds=int(os.environ.get("WATCHMIND_BREAKER_COOLDOWN_SECONDS", "60")),
        ).validate()


class Quota:
    """Durable result/attempt budgets, rate limiting, and a provider circuit breaker.

    Every accepted attempt is charged before upstream execution. Failure refunds only
    the result allowance, never the attempt budget. Reservations survive process death.
    """
    def __init__(self, path: str, limit: int, attempt_limit: int | None = None,
                 rate_limit: int = 3, global_limit: int = 1000,
                 breaker_failures: int = 5, breaker_seconds: int = 60):
        self.path, self.limit = path, limit
        self.attempt_limit = limit if attempt_limit is None else attempt_limit
        self.rate_limit, self.global_limit = rate_limit, global_limit
        self.breaker_failures, self.breaker_seconds = breaker_failures, breaker_seconds
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, account TEXT NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL, started_at REAL NOT NULL DEFAULT 0)")
            # Existing successful/reserved records conservatively count as spent attempts.
            if "started_at" not in {row[1] for row in db.execute("PRAGMA table_info(requests)")}:
                db.execute("ALTER TABLE requests ADD COLUMN started_at REAL NOT NULL DEFAULT 0")
            db.execute("CREATE INDEX IF NOT EXISTS requests_account_day ON requests(account, day)")
            db.execute("CREATE INDEX IF NOT EXISTS requests_day ON requests(day)")
            db.execute("CREATE INDEX IF NOT EXISTS requests_account_time ON requests(account, started_at)")
            db.execute("CREATE TABLE IF NOT EXISTS circuit (id INTEGER PRIMARY KEY CHECK(id=1), failures INTEGER NOT NULL, open_until REAL NOT NULL)")
            db.execute("INSERT OR IGNORE INTO circuit VALUES (1, 0, 0)")
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
        return self.reserve_with_reason(account, now)[0]

    def reserve_with_reason(self, account: str, now=None):
        now = now or datetime.now(timezone.utc)
        if now.tzinfo is None:
            raise ValueError("An aware UTC-compatible time is required")
        timestamp = now.timestamp()
        day = now.astimezone(timezone.utc).date().isoformat()
        cutoff = (now.astimezone(timezone.utc).date() - timedelta(days=30)).isoformat()
        digest = hashlib.sha256(account.encode()).hexdigest()
        request_id = uuid.uuid4().hex
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM requests WHERE day < ?", (cutoff,))
            failures, open_until = db.execute("SELECT failures, open_until FROM circuit WHERE id=1").fetchone()
            if open_until > timestamp:
                return None, "provider_circuit_open"
            if open_until:
                db.execute("UPDATE circuit SET failures=0, open_until=0 WHERE id=1")
            successes, attempts = db.execute(
                "SELECT COALESCE(SUM(CASE WHEN status IN ('reserved','complete') THEN 1 ELSE 0 END),0), COUNT(*) FROM requests WHERE account=? AND day=?",
                (digest, day)).fetchone()
            if successes >= self.limit:
                return None, "daily_quota_exhausted"
            if attempts >= self.attempt_limit:
                return None, "daily_attempt_budget_exhausted"
            global_attempts = db.execute("SELECT COUNT(*) FROM requests WHERE day=?", (day,)).fetchone()[0]
            if global_attempts >= self.global_limit:
                return None, "service_attempt_budget_exhausted"
            recent = db.execute("SELECT COUNT(*) FROM requests WHERE account=? AND started_at>?", (digest, timestamp - 60)).fetchone()[0]
            if recent >= self.rate_limit:
                return None, "account_rate_limited"
            db.execute("INSERT INTO requests(id,account,day,status,started_at) VALUES (?, ?, ?, 'reserved', ?)",
                       (request_id, digest, day, timestamp))
        return request_id, None

    def finish(self, request_id: str, success: bool, now=None):
        now = now or datetime.now(timezone.utc)
        timestamp = now.timestamp()
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT status FROM requests WHERE id=?", (request_id,)).fetchone()
            if row is None or row[0] != "reserved":
                return # Completion is idempotent, even across process retries.
            db.execute("UPDATE requests SET status=? WHERE id=?", ("complete" if success else "failed", request_id))
            if success:
                # An older in-flight success must not reopen an already-open circuit.
                db.execute("UPDATE circuit SET failures=0 WHERE id=1 AND open_until<=?", (timestamp,))
            else:
                failures, open_until = db.execute("SELECT failures, open_until FROM circuit WHERE id=1").fetchone()
                failures += 1
                if failures >= self.breaker_failures:
                    open_until = max(open_until, timestamp + self.breaker_seconds)
                db.execute("UPDATE circuit SET failures=?, open_until=? WHERE id=1", (failures, open_until))


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
        self.quota = Quota(config.database, config.daily_limit, config.attempt_limit,
                           config.account_rate_limit, config.global_daily_attempt_limit,
                           config.breaker_failure_limit, config.breaker_cooldown_seconds)
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
            reservation, denied = self.server.quota.reserve_with_reason(account)
            if reservation is None:
                self.fail(503 if denied == "provider_circuit_open" else 429, denied)
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
                    # Fail closed: a reservation consumes both result and paid-attempt allowances.
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
