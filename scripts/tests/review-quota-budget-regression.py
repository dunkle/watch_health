"""Regression for R05: success refunds must never refund paid-attempt allowance.

All calls use an ephemeral loopback gateway and a fake upstream. The configured
attempt budget is explicit and independent of the successful-result allowance.
No provider credentials or paid external request is used. Nonzero means the
cost-protection invariant has regressed.
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
    expected_attempt_budget = fixture.config.attempt_limit
    statuses = [fixture.request()[0] for _ in range(10)]
    actual_attempts = len(fixture.calls)
    if actual_attempts > expected_attempt_budget:
        print(
            "FAIL QUOTA-R01: no independent paid-attempt budget; "
            f"configured daily attempt limit={expected_attempt_budget}, "
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
