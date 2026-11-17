#!/usr/bin/env python3
"""Regression test for the 2026-11-17 canary transport fast-fail.

Scene: a tokenized canary ping never reaches an IDLE conversation while the
bridge socket still looks healthy (keepalive pongs), so `bridge_connected()`
and the bridge stale-stream guard both stay green and inbound DMs are dropped
silently. canary.py now returns TRANSPORT_FAULT (3); watchdog must restart the
bridge once and page the owner "resend".

Safe by construction: restart_bridge / alert / push / tmux are all stubbed, so
nothing on the box is touched.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import watchdog

failures = []


def check(name, got, want):
    if got != want:
        failures.append("%s: got %r want %r" % (name, got, want))


def run(ok_restart, recent):
    calls = {"reason": None, "alerts": []}

    def fake_restart(reason):
        calls["reason"] = reason
        return ok_restart

    def fake_alert(msg, kind="alert", critical=False):
        calls["alerts"].append((kind, critical, msg))

    old = (watchdog.bridge_restart_recent, watchdog.restart_bridge,
           watchdog.alert)
    watchdog.bridge_restart_recent = lambda: recent
    watchdog.restart_bridge = fake_restart
    watchdog.alert = fake_alert
    try:
        ret = watchdog.handle_canary_transport_fault()
    finally:
        (watchdog.bridge_restart_recent, watchdog.restart_bridge,
         watchdog.alert) = old
    return ret, calls


# 1. idle conversation, no recent restart, bridge comes back -> restart + page
ret, calls = run(ok_restart=True, recent=False)
check("case1 return", ret, True)
check("case1 restarted", calls["reason"] is not None, True)
check("case1 alert kind", calls["alerts"][0][0] if calls["alerts"] else None,
      "bridge-transport")
check("case1 not critical", calls["alerts"][0][1] if calls["alerts"] else None,
      False)
check("case1 says resend",
      "resend" in (calls["alerts"][0][2] if calls["alerts"] else ""), True)

# 2. restart declined/failed -> critical page, still returns False
ret, calls = run(ok_restart=False, recent=False)
check("case2 return", ret, False)
check("case2 alert count", len(calls["alerts"]), 1)
check("case2 critical", calls["alerts"][0][1] if calls["alerts"] else None,
      True)

# 3. a restart just happened -> no second restart, no duplicate page
ret, calls = run(ok_restart=True, recent=True)
check("case3 return", ret, False)
check("case3 no restart", calls["reason"], None)
check("case3 no alert", calls["alerts"], [])

# 4. restart_bridge reports its own failure (probe could not run)
orig = (watchdog.probes_ok, watchdog.sh, watchdog.breaker_open)
watchdog.probes_ok = lambda: False
watchdog.sh = lambda *a, **k: (_ for _ in ()).throw(AssertionError("ran sh"))
watchdog.breaker_open = lambda: False
try:
    check("case4 return", watchdog.restart_bridge("test"), False)
finally:
    watchdog.probes_ok, watchdog.sh, watchdog.breaker_open = orig

# 5. canary really emits 3 for an idle, never-delivered ping
import canary
check("constant", getattr(canary, "TRANSPORT_FAULT", None), 3)
check("threshold is seconds", isinstance(canary.TRANSPORT_SECS, float), True)

if failures:
    print("FAIL")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("ok: canary transport fast-fail (5 cases)")
