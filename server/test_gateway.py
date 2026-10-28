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
            if self.mode == "malformed":
                return {"secret": "provider key"}
            return {"choices": [{"message": {"content": "A tentative interpretation"}}], "private_debug": "hidden"}

        self.config = Configuration("https://provider.example/v1/chat/completions", "upstream-test-key", "test-model",
                                    {TOKEN: "user_1"}, str(Path(self.temp.name) / "quota.sqlite3"), daily_limit=2)
        self.server = Gateway(("127.0.0.1", 0), self.config, upstream)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

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
        self.mode = "failure"
        for _ in range(3):
            status, result = self.request()
            self.assertEqual(status, 502)
            self.assertNotIn("secret", json.dumps(result))
        self.mode = "success"
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.request()[0], 200)

    def test_bad_provider_response_does_not_consume_quota(self):
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
            quota = Quota(path, 1)
            now = datetime(2026, 10, 28, tzinfo=timezone.utc)
            request = quota.reserve("account", now)
            quota.finish(request, False)
            self.assertIsNotNone(quota.reserve("account", now))
            quota.reserve("account", now + timedelta(days=31))
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM requests").fetchone()[0], 1)


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
