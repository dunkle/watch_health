"""Negative release audit: successful-result quota is not a paid-attempt budget.

Standalone and intentionally outside check.sh. All calls go to an ephemeral
loopback gateway with the existing fake upstream; no provider, real key, or paid
request is used. Expected production behavior is that a separate operator-paid
attempt budget bounds upstream executions even if accepted upstream work returns
an unusable result. The current gateway has only a refundable success quota, so
this audit deliberately exits 1. This blocks public free-tier operation, not
personal BYOK use of the app.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "server"))
from test_gateway import GatewayTests  # noqa: E402

fixture = GatewayTests()
fixture.setUp()
try:
    fixture.mode = "malformed"
    # The fake upstream records each accepted execution before returning invalid
    # content. A real provider can still bill for this executed work.
    expected_attempt_budget = fixture.config.daily_limit
    statuses = [fixture.request()[0] for _ in range(10)]
    actual_attempts = len(fixture.calls)
    if actual_attempts > expected_attempt_budget:
        print(
            "FAIL QUOTA-R01: no independent paid-attempt budget; "
            f"configured daily result limit={fixture.config.daily_limit}, "
            f"upstream executions={actual_attempts}, statuses={statuses}. "
            "Refunding unusable results permits repeated potentially billable work."
        )
        code = 1
    else:
        print(
            "PASS QUOTA-R01: upstream work is bounded despite unusable results; "
            f"executions={actual_attempts}, budget={expected_attempt_budget}"
        )
        code = 0
finally:
    fixture.tearDown()
raise SystemExit(code)
