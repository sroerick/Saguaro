#!/usr/bin/env python3
"""Regression test: canary reply verification (2026-10-18 false FAILs).

Two defects covered:
 1. conversation_round_trip() anchored on the LAST record mentioning the
    token; the reply usually ECHOES the token, so `after` excluded the reply
    itself -> "no assistant reply after it yet" FAILs for healthy pings (and
    accidental greens when a later turn quoted an older token, then replied).
 2. The reply deadline (canary_reply_secs, 1800 s) was shorter than the ping
    cadence (canary_secs, 3600 s), so the FIRST - and possibly only -
    verification attempt could already be overdue (ping 15:52 -> check 16:30
    = 38 min) and a single unverifiable check paged the owner.
Also checks watchdog.canary_due() now verifies every cycle while a ping is
outstanding.

Run: venv/bin/python harness/scripts/test_canary_replycheck.py [canary.py]
Read-only: makes no pings, touches no markers.
"""
import importlib.util
import sys
from pathlib import Path

H = Path("/home/al/saguaro-live/harness")
CAND = Path(sys.argv[1]) if len(sys.argv) > 1 else H / "canary.py"
sys.path.insert(0, str(CAND.parent))
sys.path.insert(0, str(H))      # bridge.py / heartbeat.py live in the harness
spec = importlib.util.spec_from_file_location("canary_under_test", CAND)
C = importlib.util.module_from_spec(spec)
sys.modules["canary_under_test"] = C
spec.loader.exec_module(C)
print("testing %s" % CAND)


def ping(seq, tok):
    return {"seq": seq, "type": "MESSAGE",
            "strings": ["[canary] round-trip test %s - reply with the token"
                        % tok]}


def reply(seq, tok):
    return {"seq": seq, "type": "PROVIDER-ITEM",
            "strings": ['{"type":"message","role":"assistant","content":'
                        '[{"type":"output_text","text":"%s"}]}' % tok]}


TOK = "canary-TESTTOKEN"
real_all = C.bridge.all_records

# 1: ping, then a reply that ECHOES the token -> True
C.bridge.all_records = lambda conv: [ping(10, TOK), reply(11, TOK)]
ok, detail = C.conversation_round_trip("X", TOK)
print("1) ping + echoing reply: %s (%s)" % (ok, detail))
assert ok, "1) FAILED: healthy round trip not detected"

# 2: ping only -> False
C.bridge.all_records = lambda conv: [ping(10, TOK)]
ok, detail = C.conversation_round_trip("X", TOK)
print("2) ping, no reply: %s (%s)" % (ok, detail))
assert not ok, "2) FAILED: unreplied ping passed"

# 3: the OLD last-mention logic on case 1 -> False  (proves the bug)
recs = [ping(10, TOK), reply(11, TOK)]
last = None
for r in recs:
    if TOK in " ".join(r["strings"]):
        last = r["seq"]
old_after = [r for r in recs if r["seq"] > last]
print("3) old logic on case 1: %d record(s) after the last mention -> %s"
      % (len(old_after), bool(C.bridge.reply_texts(old_after))))
assert not C.bridge.reply_texts(old_after), "3) FAILED: bug not reproduced"

# 4: an unrelated later reply must NOT rescue an unreplied ping
C.bridge.all_records = lambda conv: [ping(10, TOK), reply(20, "canary-OTHER")]
ok, detail = C.conversation_round_trip("X", TOK)
print("4) ping + unrelated later reply: %s (%s)" % (ok, detail))
assert not ok, "4) FAILED: unrelated reply accepted"

# 5: live conversation - pings whose replies CARRY the token must verify True
C.bridge.all_records = real_all
recs = C.bridge.status_records()
conv = recs[0].get("conversation") if recs else None
print("5) live conversation %s" % conv)
for token in ["canary-1792338723", "canary-1792336815"]:
    ok, detail = C.conversation_round_trip(conv, token)
    print("   %s -> %s (%s)" % (token, ok, detail))
    assert ok, "5) FAILED: %s has a token reply but did not verify" % token
# informational: the newest ping may still be mid-turn (its own reply not yet
# written) - a false green for it under the old any-assistant-text rule is
# exactly what the token requirement fixes.
info = C.conversation_round_trip(conv, "canary-1792341314")
print("   (info) newest ping canary-1792341314 -> %s (%s)" % info)

# 6: a token that never reached the conversation -> False
ok, detail = C.conversation_round_trip(conv, "canary-DEADBEEF")
print("6) unknown token: %s (%s)" % (ok, detail))
assert not ok, "6) FAILED: unknown token verified"

# 7: deadline coherence
print("7) PING_SECS=%.0f REPLY_SECS=%.0f" % (C.PING_SECS, C.REPLY_SECS))
assert C.REPLY_SECS >= C.PING_SECS + 600, \
    "7) FAILED: deadline shorter than one ping cadence"

# 8: watchdog.canary_due() is True while a ping is outstanding
wspec = importlib.util.spec_from_file_location(
    "wd_under_test", CAND.parent / "watchdog.py")
W = importlib.util.module_from_spec(wspec)
sys.modules["wd_under_test"] = W
wspec.loader.exec_module(W)


class FakePending:
    def exists(self):
        return True


g = W.canary_due.__globals__
g["CANARY_PENDING_MARK"] = FakePending()
g["B"] = {"canary": "on", "canary_secs": "3600"}
print("8) canary_due with an outstanding ping: %s" % W.canary_due())
assert W.canary_due() is True, "8) FAILED: outstanding ping not verified each cycle"

# 9: phase B end-to-end on an ANSWERED ping (temp marker, stubbed green/fail)
import tempfile

tmp = Path(tempfile.mkdtemp()) / "saguaro-canary-pending"
tmp.write_text("canary-1792338723")
C.CANARY_PENDING = tmp
C.muc_history = lambda room, max_n=30: []      # force the conversation path
greens = []
C.green = lambda mark: greens.append(mark)
C.fail = lambda msg: (_ for _ in ()).throw(
    AssertionError("9) FAILED: phase B paged the owner: %s" % msg))
rc = C.main()
print("9) phase B (answered ping): rc=%s greens=%d marker_gone=%s"
      % (rc, len(greens), not tmp.exists()))
assert rc == 0 and greens and not tmp.exists(), "9) FAILED: phase B did not green"

# 10: phase B on an UNANSWERED ping stays pending, does not page
tmp2 = Path(tempfile.mkdtemp()) / "saguaro-canary-pending"
tmp2.write_text("canary-DEADBEEF")
C.CANARY_PENDING = tmp2
rc = C.main()
print("10) phase B (unanswered ping): rc=%s greens=%d marker_kept=%s"
      % (rc, len(greens), tmp2.exists()))
assert rc == 0 and len(greens) == 1 and tmp2.exists(), \
    "10) FAILED: unanswered ping did not stay pending"

print("ALL TESTS PASSED")
