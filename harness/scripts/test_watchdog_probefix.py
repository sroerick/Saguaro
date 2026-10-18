#!/usr/bin/env python3
"""Regression test: a probe that cannot RUN must never be read as "down".

Covers the 2026-10-18 incident (al hit its RLIMIT_NPROC of 128 because 38
stuck `pp-local sync` children had piled up; `localgroup status` could not be
spawned, the watchdog called that "no autolith session answering" and tried to
restart a HEALTHY agent every 5 min).

Run:  /home/al/saguaro-live/harness/venv/bin/python \
          /home/al/saguaro-live/harness/scripts/test_watchdog_probefix.py [path/to/watchdog.py]

Safe by construction: START is redirected to /bin/true and push/ntfy/incident/
alert are stubbed, so this file cannot restart a session or page anyone.
"""
import importlib.util
import sys
from pathlib import Path

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else
              "/home/al/saguaro-live/harness/watchdog.py")
H = str(TARGET.parent)
sys.path.insert(0, H)          # so `import bridge` / `heartbeat` resolve
spec = importlib.util.spec_from_file_location("wd_under_test", TARGET)
W = importlib.util.module_from_spec(spec)
sys.modules["wd_under_test"] = W
spec.loader.exec_module(W)

print("testing %s" % TARGET)

# --- test isolation: this file must be incapable of affecting the live box --
W.START = "/bin/true"                      # no start-sessions.sh, ever
W.push = lambda *a, **k: None
W.ntfy = lambda *a, **k: "stub"
W.incident = lambda kind, note: None
pages = []
W.alert = lambda msg, kind="alert", critical=False: pages.append((kind, msg))
W.canary_due = lambda: False               # no canary pings from the test
W.STATUS_RETRY_SECS = 0

real_run = W.subprocess.run
real_recover = W.recover_and_alert
real_alive = W.bridge_alive
real_session_exists = W.bridge_session_exists
real_status = W.bridge.status_records


def boom(*a, **k):
    raise BlockingIOError(35, "Resource temporarily unavailable")


# --- 1: sh() must never raise; it degrades and records the failure ----------
W.subprocess.run = boom
r = W.sh(["/bin/true"])
print("1) sh rc=%s probes_ok=%s fail=%r" % (r.returncode, W.probes_ok(), W._SH_FAIL))
assert r.returncode == 127 and not W.probes_ok(), "1) FAILED: sh did not degrade"

# --- 2: an unrunnable status probe retries, then reports UNKNOWN ------------
calls = {"n": 0}


def bad_status():
    calls["n"] += 1
    raise BlockingIOError(35, "Resource temporarily unavailable")


W.bridge.status_records = bad_status
try:
    W.status_confirmed()
    raise AssertionError("2) FAILED: expected StatusUnknown")
except W.StatusUnknown as e:
    print("2) StatusUnknown after %d attempt(s): %s" % (calls["n"], e))
assert calls["n"] == W.STATUS_ATTEMPTS, "2) FAILED: wrong retry count"

# --- 3: main() with an unusable probe must PAGE, never repair --------------
restarts = []
W.recover_and_alert = lambda reason: restarts.append(reason)
W._SH_FAIL = None
W.main()
print("3) restarts=%r pages=%r" % (restarts, [k for k, _ in pages]))
assert restarts == [], "3) FAILED: repaired despite an unrunnable probe"
assert len(pages) == 1 and pages[0][0] == "probe-failed", "3) FAILED: no page"

# --- 3b: the page is debounced (no spam every 5 min) ----------------------
before = len(pages)
W._SH_FAIL = None
W.main()
print("3b) pages after a second blind cycle: %d (was %d)" % (len(pages), before))
assert len(pages) == before, "3b) FAILED: page not debounced"

# --- 4: a genuine empty status still repairs (the CLI ran, no session) ----
W.bridge.status_records = lambda: []
W._SH_FAIL = None
W.main()
print("4) restarts=%r" % (restarts,))
assert restarts == ["no autolith session answering"], "4) FAILED: empty status no longer repairs"

# --- 5: a failed probe blocks recover_and_alert and restart_bridge --------
W.recover_and_alert = real_recover
W._SH_FAIL = None
W.subprocess.run = boom
W.sh(["/bin/true"])                      # probe fails -> _SH_FAIL set
W.recover_and_alert("test: must be refused")
W.restart_bridge("test: must be refused")
print("5) recover_and_alert + restart_bridge refused with _SH_FAIL=%r" % (W._SH_FAIL,))
assert len(pages) == before, "5) FAILED: a page was emitted"

# --- 6: healthy probes + dead bridge still repair (no over-blocking) ------
W.subprocess.run = real_run
W._SH_FAIL = None
W.bridge_alive = lambda: False
W.bridge_session_exists = lambda: False
W.bridge.status_records = lambda: [{"session": "T", "conversation": "C",
                                    "pid": None, "idle": True, "active": False}]
rest = []
W.recover_and_alert = lambda reason: rest.append(reason)
W.main()
print("6) restarts=%r (expected ['xmpp-bridge tmux session gone'])" % (rest,))
assert rest == ["xmpp-bridge tmux session gone"], "6) FAILED: real outage no longer repairs"

# --- 7: live READ-ONLY sanity: the patched probe helpers work on the box ---
W.bridge_alive = real_alive
W.bridge_session_exists = real_session_exists
W.bridge.status_records = real_status
W.recover_and_alert = real_recover
W._SH_FAIL = None
recs = W.status_confirmed()
print("7) live status probe: %d session(s), probes_ok=%s, session=%s"
      % (len(recs), W.probes_ok(), recs[0].get("session") if recs else None))
assert recs and W.probes_ok(), "7) FAILED: live status probe unusable"
assert len(pages) == before, "7) FAILED: a page was emitted"

# cleanup: drop the debounce marker this test wrote
try:
    W.STATUS_UNKNOWN_MARK.unlink()
    print("cleanup) removed", W.STATUS_UNKNOWN_MARK)
except OSError as e:
    print("cleanup) nothing to remove (%s)" % e)

print("ALL TESTS PASSED")
