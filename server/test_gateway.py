import concurrent.futures
import http.client
import json
import sqlite3
import tempfile
import socket
import time
import threading
import unittest
from datetime import datetime, timedelta, timezone
from dataclasses import replace
from pathlib import Path
from gateway import Configuration, Gateway, Quota, validate_payload, normalize_response, NoRedirect

TOKEN = "test-token-" + "a" * 32


def payload():
    return {"model": "test-model", "messages": [{"role": "user", "content": "private context"}], "max_tokens": 800, "stream": False}


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.calls = []
        self.mode = "success"

        def upstream(config, body):
            self.calls.append(body)
            if self.mode == "failure":
                raise ValueError("secret provider diagnostic")
            if self.mode == "timeout":
                raise TimeoutError("secret timeout diagnostic")
            if self.mode == "malformed":
                return {"secret": "provider key"}
            return {"choices": [{"message": {"content": "A tentative interpretation"}}], "private_debug": "hidden"}

        self.config = Configuration("https://provider.example/v1/chat/completions", "upstream-test-key", "test-model",
                                    {TOKEN: "user_1"}, str(Path(self.temp.name) / "quota.sqlite3"), daily_limit=2)
        self.server = Gateway(("127.0.0.1", 0), self.config, upstream)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

    def configure_limits(self, **limits):
        self.config = replace(self.config, **limits).validate()
        self.server.config = self.config
        self.server.quota = Quota(self.config.database, self.config.daily_limit, self.config.attempt_limit,
                                  self.config.account_rate_limit, self.config.global_daily_attempt_limit,
                                  self.config.breaker_failure_limit, self.config.breaker_cooldown_seconds)

    def tearDown(self):
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()
        self.temp.cleanup()

    def request(self, value=None, token=TOKEN, path="/v1/chat/completions", headers=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        body = json.dumps(value if value is not None else payload())
        all_headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
        all_headers.update(headers or {})
        conn.request("POST", path, body, all_headers)
        response = conn.getresponse()
        result = (response.status, json.loads(response.read()))
        conn.close()
        return result

    def test_quota_success_and_normalized_response(self):
        status, result = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(result["choices"][0]["message"]["content"], "A tentative interpretation")
        self.assertNotIn("private_debug", result)
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.request()[0], 429)
        self.assertEqual(len(self.calls), 2)

    def test_authentication_before_body_read_or_quota(self):
        self.assertEqual(self.request(token="wrong", headers={"Content-Length": "999999999"})[0], 401)
        self.assertEqual(len(self.calls), 0)
        self.assertEqual(self.request()[0], 200)

    def test_failure_releases_allowance_and_sanitizes_error(self):
        self.configure_limits(daily_attempt_limit=8, account_rate_limit=8, breaker_failure_limit=10)
        self.mode = "failure"
        for _ in range(3):
            status, result = self.request()
            self.assertEqual(status, 502)
            self.assertNotIn("secret", json.dumps(result))
        self.mode = "success"
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.request()[0], 200)

    def test_bad_provider_response_does_not_consume_quota(self):
        self.configure_limits(daily_attempt_limit=3)
        self.mode = "malformed"
        self.assertEqual(self.request()[0], 502)
        self.mode = "success"
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.request()[0], 200)

    def test_full_app_evidence_with_system_prompt_fits(self):
        body = payload()
        body["messages"] = [
            {"role": "system", "content": "s" * 2000},
            {"role": "user", "content": "e" * 24000},
        ]
        self.assertEqual(self.request(body)[0], 200)
        self.assertEqual(self.calls[0]["messages"], body["messages"])

    def test_rejects_model_override_unsupported_fields_and_stream(self):
        for key, value in [("model", "other"), ("stream", True), ("url", "https://evil.example"), ("max_tokens", 2001), ("temperature", float("nan"))]:
            body = payload()
            body[key] = value
            self.assertEqual(self.request(body)[0], 400, key)
        self.assertEqual(self.calls, [])

    def test_rejects_nonjson_and_excessive_declared_size(self):
        self.assertEqual(self.request(headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request(headers={"Content-Length": "200000"})[0], 413)
        self.assertEqual(self.calls, [])

    def test_concurrency_limit_rejects_excess_connections(self):
        self.server.slots = threading.BoundedSemaphore(1)
        occupying = socket.create_connection(self.server.server_address, timeout=2)
        try:
            deadline = time.monotonic() + 1
            while self.server.slots._value and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertEqual(self.server.slots._value, 0)
            other = socket.create_connection(self.server.server_address, timeout=2)
            try:
                self.assertIn(b"503 Service Unavailable", other.recv(256))
            finally:
                other.close()
        finally:
            occupying.close()

    def test_health_and_unknown_path(self):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        conn.request("GET", "/health")
        result = conn.getresponse()
        self.assertEqual(result.status, 200)
        self.assertEqual(json.loads(result.read()), {"status": "ok"})
        conn.close()
        self.assertEqual(self.request(path="/other")[0], 404)

    def test_unusable_outputs_cannot_refund_paid_attempts(self):
        self.mode = "malformed"
        self.assertEqual(self.request()[0], 502)
        self.assertEqual(self.request()[0], 502)
        status, body = self.request()
        self.assertEqual(status, 429)
        self.assertEqual(body["error"]["code"], "daily_attempt_budget_exhausted")
        self.assertEqual(len(self.calls), 2)
        # Restarting quota state with the same durable DB cannot reset the budget.
        self.configure_limits()
        self.assertEqual(self.request()[0], 429)
        self.assertEqual(len(self.calls), 2)

    def test_timeouts_also_spend_attempt_budget_without_leaking_details(self):
        self.mode = "timeout"
        for _ in range(2):
            status, result = self.request()
            self.assertEqual(status, 502)
            self.assertNotIn("secret", json.dumps(result))
        self.assertEqual(self.request()[0], 429)
        self.assertEqual(len(self.calls), 2)

    def test_explicit_extra_attempts_do_not_increase_success_allowance(self):
        self.configure_limits(daily_attempt_limit=4, account_rate_limit=4)
        self.mode = "malformed"
        self.assertEqual(self.request()[0], 502)
        self.mode = "success"
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.request()[0], 200)
        status, body = self.request()
        self.assertEqual(status, 429)
        self.assertEqual(body["error"]["code"], "daily_quota_exhausted")
        self.assertEqual(len(self.calls), 3)

    def test_account_rate_limit_is_enforced_before_upstream(self):
        self.configure_limits(daily_limit=10, daily_attempt_limit=10, account_rate_limit=1)
        self.assertEqual(self.request()[0], 200)
        status, body = self.request()
        self.assertEqual(status, 429)
        self.assertEqual(body["error"]["code"], "account_rate_limited")
        self.assertEqual(len(self.calls), 1)

    def test_failure_circuit_blocks_other_accounts_until_cooldown(self):
        self.configure_limits(daily_attempt_limit=10, breaker_failure_limit=1)
        self.mode = "failure"
        self.assertEqual(self.request()[0], 502)
        status, body = self.request()
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "provider_circuit_open")
        self.assertEqual(len(self.calls), 1)

    def test_revoked_token_cannot_spend_allowance(self):
        self.server.config = replace(self.config, clients={"replacement-token-" + "b" * 32: "user_1"})
        self.assertEqual(self.request()[0], 401)
        self.assertEqual(self.calls, [])


class QuotaTests(unittest.TestCase):
    def test_atomic_concurrent_reservations_and_crash_retention(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "quota.sqlite3")
            quota = Quota(path, 3)
            now = datetime(2026, 10, 28, tzinfo=timezone.utc)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: quota.reserve("opaque_user", now), range(12)))
            self.assertEqual(len([x for x in results if x]), 3)
            self.assertIsNone(Quota(path, 3).reserve("opaque_user", now))
            self.assertIsNotNone(quota.reserve("opaque_user", now + timedelta(days=1)))
            with sqlite3.connect(path) as db:
                rows = db.execute("SELECT account, status FROM requests").fetchall()
                self.assertTrue(all(account != "opaque_user" for account, _ in rows))

    def test_accounts_have_independent_limits(self):
        with tempfile.TemporaryDirectory() as temp:
            quota = Quota(str(Path(temp) / "quota.sqlite3"), 1)
            self.assertIsNotNone(quota.reserve("account_a"))
            self.assertIsNone(quota.reserve("account_a"))
            self.assertIsNotNone(quota.reserve("account_b"))

    def test_released_reservation_and_retention(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "quota.sqlite3")
            quota = Quota(path, 1, attempt_limit=2)
            now = datetime(2026, 10, 28, tzinfo=timezone.utc)
            request = quota.reserve("account", now)
            quota.finish(request, False)
            self.assertIsNotNone(quota.reserve("account", now))
            quota.reserve("account", now + timedelta(days=31))
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM requests").fetchone()[0], 1)

    def test_attempt_budget_is_atomic_and_conservative_on_crash_and_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "quota.sqlite3")
            quota = Quota(path, 10, attempt_limit=3, rate_limit=100)
            now = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: quota.reserve("account", now), range(12)))
            accepted = [r for r in results if r]
            self.assertEqual(len(accepted), 3)
            quota.finish(accepted[0], False, now)
            quota.finish(accepted[1], True, now)
            restarted = Quota(path, 10, attempt_limit=3, rate_limit=100)
            self.assertIsNone(restarted.reserve("account", now))
            self.assertIsNotNone(restarted.reserve("account", now + timedelta(days=1)))
            self.assertIsNotNone(restarted.reserve("other_account", now))

    def test_global_attempt_budget_is_shared_and_survives_refunds(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "quota.sqlite3")
            quota = Quota(path, 10, attempt_limit=10, rate_limit=100, global_limit=2)
            now = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
            a = quota.reserve("a", now)
            b = quota.reserve("b", now)
            quota.finish(a, False, now)
            quota.finish(b, False, now)
            self.assertEqual(quota.reserve_with_reason("c", now), (None, "service_attempt_budget_exhausted"))
            self.assertIsNotNone(quota.reserve("c", now + timedelta(days=1)))

    def test_global_budget_is_atomic_across_concurrent_accounts(self):
        with tempfile.TemporaryDirectory() as temp:
            quota = Quota(str(Path(temp) / "quota.sqlite3"), 10, attempt_limit=10, global_limit=3)
            now = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                requests = list(pool.map(lambda i: quota.reserve(f"account_{i}", now), range(12)))
            self.assertEqual(sum(r is not None for r in requests), 3)

    def test_sliding_rate_limit_crosses_utc_day_without_reset(self):
        with tempfile.TemporaryDirectory() as temp:
            quota = Quota(str(Path(temp) / "quota.sqlite3"), 10, attempt_limit=10, rate_limit=1)
            now = datetime(2026, 10, 28, 23, 59, 50, tzinfo=timezone.utc)
            request = quota.reserve("a", now)
            quota.finish(request, False, now)
            self.assertEqual(quota.reserve_with_reason("a", now + timedelta(seconds=20)), (None, "account_rate_limited"))
            self.assertIsNotNone(quota.reserve("a", now + timedelta(seconds=60)))

    def test_circuit_is_durable_idempotent_and_allows_cooldown_recovery(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "quota.sqlite3")
            quota = Quota(path, 10, attempt_limit=10, rate_limit=100, breaker_failures=2, breaker_seconds=60)
            now = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
            a, b, old_success = [quota.reserve("a", now) for _ in range(3)]
            quota.finish(a, False, now)
            quota.finish(a, False, now) # A duplicate completion cannot count as another failure.
            self.assertIsNotNone(quota.reserve("b", now))
            quota.finish(b, False, now)
            quota.finish(old_success, True, now) # Already-open circuit cannot be cleared by earlier in-flight work.
            restarted = Quota(path, 10, attempt_limit=10, rate_limit=100, breaker_failures=2, breaker_seconds=60)
            self.assertEqual(restarted.reserve_with_reason("c", now), (None, "provider_circuit_open"))
            self.assertIsNotNone(restarted.reserve("c", now + timedelta(seconds=60)))

    def test_old_schema_migrates_without_resetting_used_allowance(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "quota.sqlite3")
            now = datetime(2026, 10, 28, tzinfo=timezone.utc)
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE requests (id TEXT PRIMARY KEY, account TEXT NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL)")
                import hashlib
                db.execute("INSERT INTO requests VALUES (?,?,?,?)", ("legacy", hashlib.sha256(b"a").hexdigest(), "2026-10-28", "reserved"))
            quota = Quota(path, 1)
            self.assertIsNone(quota.reserve("a", now))
            self.assertIsNotNone(quota.reserve("a", now + timedelta(days=1)))


class ValidationTests(unittest.TestCase):
    def test_upstream_configuration_prohibits_insecure_or_credential_urls(self):
        for url in ["http://api.example/chat/completions", "https://key@api.example/chat/completions", "https://api.example/chat/completions?key=secret", "https://api.example/other"]:
            with self.assertRaises(ValueError):
                Configuration(url, "key", "model", {TOKEN: "id"}, "unused").validate()

    def test_no_redirect_and_response_limits(self):
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://other.example"))
        with self.assertRaises(ValueError):
            normalize_response({"choices": [{"message": {"content": "x" * 12001}}]}, "model")
        with self.assertRaises(ValueError):
            normalize_response({"choices": []}, "model")
        with self.assertRaises(ValueError):
            normalize_response({"choices": [{"message": {"content": "truncated"}, "finish_reason": "length"}]}, "model")
        body = payload()
        body["messages"][0]["content"] = "x" * 28001
        with self.assertRaises(ValueError):
            validate_payload(body, "test-model")


if __name__ == "__main__":
    unittest.main()
