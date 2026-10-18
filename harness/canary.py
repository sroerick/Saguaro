#!/usr/bin/env python3
"""End-to-end chat-path canary for the saguaro harness.

Verifies the full round trip in two phases across watchdog cycles (a
delivered stanza alone proves nothing - the 2026-10-09 outage showed a
"healthy" bridge delivering into a conversation nobody read):
  A. deliver - wake (an autolith session answers `localgroup status` with
     recent turn activity), connect (fresh one-shot XMPP credentials
     authenticate AND the bridge holds its server connection), then post a
     tokenized ping into the canary room. The @trigger mention makes the
     bridge enqueue it into the agent's conversation.
  B. verify  - on every watchdog cycle while the ping is outstanding,
     green-light only when the round trip is proven: the agent's reply in
     the canary room carries the token, or an assistant record landed in
     the conversation after the ping. No confirmation within the reply
     deadline (canary_reply_secs, never less than one full ping cadence +
     10 min - a busy agent's answer can legitimately take that long) pages
     the owner.

Run by watchdog.py on the [bridge] canary cadence, or by hand:

    harness/venv/bin/python harness/canary.py

One log line per hop (goes to watchdog.log when cron-run); exit 0 green.
On failure: best-effort XMPP alert to the owner, exit 1.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge
from heartbeat import push

B = bridge.B
XMPP_C2S_PORT = "5222"   # standard client-to-server port; revisit if the server moves

CANARY_PENDING = Path.home() / ".cache" / "saguaro-canary-pending"
PING_SECS = float(B.get("canary_secs", 21600))
REPLY_SECS = float(B.get("canary_reply_secs", 1800))
# 2026-10-18: the reply deadline must cover at least one full PING cadence plus
# slack. With canary_secs = 3600 and a 1800 s deadline the FIRST verification
# attempt could already be overdue (ping 15:52 -> next run 16:30 = 38 min), so
# one unverifiable check paged the owner about a healthy agent. Verification
# itself runs on every watchdog cycle while a ping is outstanding
# (watchdog.canary_due), so this is an outer bound, not the check interval.
REPLY_SECS = max(REPLY_SECS, PING_SECS + 600)


def bridge_pid():
    """The bridge's python process id. The tmux pane leader is a ksh
    wrapper; the client is its python child. Match on comm, not args:
    ps truncates the command line and would hide 'bridge.py'."""
    leader = bridge.run(["/usr/bin/tmux", "list-panes", "-t", "xmpp-bridge",
                         "-F", "#{pane_pid}"], timeout=15).strip()
    if not leader:
        return None
    for child in bridge.run(["/usr/bin/pgrep", "-P", leader.split()[0]],
                            timeout=15).split():
        comm = bridge.run(["/bin/ps", "-o", "comm=", "-p", child],
                          timeout=15).strip()
        if comm.startswith("python") or comm.startswith("sbcl"):
            return child
    return None


def newest_record_age(conv):
    """Seconds since the newest record in conversation CONV, or None."""
    if not conv:
        return None
    d = Path.home() / ".local/share/autolith/conversations" / conv
    if not d.is_dir():
        return None
    files = list(d.glob("*.sexp"))
    if not files:
        return None
    try:
        return time.time() - max(f.stat().st_mtime for f in files)
    except OSError:
        return None


def bridge_connected():
    """(ok, detail): the bridge process holds a TCP connection to the
    XMPP server. A tmux session can outlive a wedged client; the socket
    is the honest signal."""
    pid = bridge_pid()
    if not pid:
        return False, "bridge process not found under tmux xmpp-bridge"
    # the CL bridge's TLS socket belongs to its openssl s_client child
    pids = [str(pid)] + bridge.run(["/usr/bin/pgrep", "-P", str(pid)],
                                   timeout=15).split()
    out = ""
    for p in pids:
        out += bridge.run(["/usr/bin/fstat", "-p", p], timeout=15)
    hits = [l for l in out.splitlines()
            if "internet" in l and ":" + XMPP_C2S_PORT in l]
    if not hits:
        return False, ("bridge pid %s holds no TCP connection to the XMPP "
                       "server (port %s)" % (pid, XMPP_C2S_PORT))
    return True, hits[0].split()[-1]


def probe(room, nick, line):
    """One-shot deliver through the bridge's own xmpp stack (say.lisp):
    authenticate, bind, join the room, post one line, disconnect. Covers
    the old connect+deliver hops (fresh credentials every run, so a
    rotated password still fails loudly). The join nick is the configured
    muc_nick with a nick-say fallback on conflict with the live bridge."""
    say = Path(__file__).resolve().parent / "say.lisp"
    try:
        proc = subprocess.run(
            ["/usr/local/bin/sbcl", "--script", str(say), "muc", room, line],
            capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, "say.lisp muc timed out after 60s"
    out = " ".join((proc.stdout + " " + proc.stderr).split())
    if proc.returncode != 0:
        return False, "say.lisp muc failed (rc=%d): %s" % (proc.returncode, out)
    return True, "delivered to %s via say.lisp" % room


def fail(msg):
    print("canary: FAIL %s" % msg, flush=True)
    try:
        push(B.get("allow", ["owner@chat.example.net"])[0],
             "[canary] FAIL %s - the chat path needs eyes" % msg)
    except Exception as e:
        print("canary: alert push failed: %s" % e, flush=True)


def green(mark):
    try:
        mark.parent.mkdir(parents=True, exist_ok=True)
        mark.write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    except OSError:
        pass


def muc_history(room, max_n=30):
    """Recent (nick, body) messages from ROOM via say.lisp history, or [].
    say.lisp joins under muc_nick-say, so this never collides with the
    live bridge.

    2026-10-18: say the quiet part out loud. This used to return [] silently
    on a failed/timed-out say.lisp, which hid why phase B fell through to the
    conversation check (and a false FAIL looked like a broken chat path)."""
    say = Path(__file__).resolve().parent / "say.lisp"
    try:
        proc = subprocess.run(
            ["/usr/local/bin/sbcl", "--script", str(say), "history", room,
             str(max_n)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print("canary: MUC history timed out (60s) - using the conversation "
              "check for this pass", flush=True)
        return []
    except OSError as e:
        print("canary: MUC history could not run (%s) - using the "
              "conversation check for this pass" % e, flush=True)
        return []
    if proc.returncode != 0:
        print("canary: MUC history failed (rc=%d): %s"
              % (proc.returncode,
                 " ".join((proc.stderr or "").split())[:200]), flush=True)
        return []
    out = []
    for ln in (proc.stdout or "").splitlines():
        # lines look like "[19:30] gregor-say: body text ..."
        if not ln.startswith("[") or "]" not in ln:
            continue
        rest = ln[ln.index("]") + 2:]
        if ": " not in rest:
            continue
        nick, body = rest.split(": ", 1)
        out.append((nick.strip(), body))
    return out


def conversation_round_trip(conv, token):
    """(ok, detail): the tokenized ping reached the agent's conversation AND
    an assistant reply carrying the token landed after it.

    2026-10-18: anchor on the FIRST record mentioning the token - that is the
    ping. This used to take the LAST mention, but the reply almost always
    echoes the token, so `after` excluded the reply itself: every ping whose
    reply was the newest mention read as "no assistant reply after it yet"
    (and older tokens read green only by accident, when some later turn
    happened to quote them and another reply followed). The reply must also
    CARRY the token: in a busy conversation some assistant text always lands
    after a ping, so accepting any of it would green-light a ping nobody
    answered."""
    try:
        recs = bridge.all_records(conv)
    except Exception as e:
        return False, "conversation %s read failed: %s" % (conv, e)
    tok_seq = None
    for r in recs:
        if token in " ".join(r.get("strings", [])):
            tok_seq = r.get("seq")
            break
    if tok_seq is None:
        return False, "token %s never reached conversation %s" % (token, conv)
    after = [r for r in recs if r.get("seq", 0) > tok_seq]
    texts = bridge.reply_texts(after)
    if any(token in t for t in texts):
        return True, ("assistant reply carrying the token recorded after the "
                      "ping (seq %s)" % tok_seq)
    if texts:
        return False, ("ping %s (seq %s) is in conversation %s; an assistant "
                       "message landed after it but does not carry the token"
                       % (token, tok_seq, conv))
    return False, ("ping %s (seq %s) is in conversation %s but no assistant "
                   "reply after it yet" % (token, tok_seq, conv))


def main():
    """Run the canary (see module docstring). Returns the exit code."""
    if str(B.get("canary", "off")).lower() != "on":
        print('canary: disabled (set [bridge] canary = "on" to arm)')
        return 2
    room = B.get("canary_muc") or ""
    nick = B.get("muc_nick", "agent") + "-canary"
    bridge_nick = B.get("muc_nick", "agent")
    trigger = B.get("muc_trigger", "gregor")
    mark = Path.home() / ".cache" / "saguaro-canary"

    # ---- phase B: verify the round trip of a previous ping ----------------
    if CANARY_PENDING.exists():
        token = CANARY_PENDING.read_text().strip()
        age = time.time() - CANARY_PENDING.stat().st_mtime
        hist = muc_history(room) if room else []
        for n, body in hist:
            if token in body and n == bridge_nick:
                green(mark)
                CANARY_PENDING.unlink()
                print("canary: round-trip ok (%s replied in %s, %.0f min)"
                      % (bridge_nick, room, age / 60.0), flush=True)
                return 0
        recs = bridge.status_records()
        conv = recs[0].get("conversation") if recs else None
        if conv:
            ok, detail = conversation_round_trip(conv, token)
            if ok:
                green(mark)
                CANARY_PENDING.unlink()
                print("canary: round-trip ok (%s, %.0f min)"
                      % (detail, age / 60.0), flush=True)
                return 0
            if age > REPLY_SECS:
                fail("reply: %s (%.0f min old; canary room: no %s reply in "
                     "the last %d message(s))"
                     % (detail, age / 60.0, bridge_nick, len(hist)))
                CANARY_PENDING.unlink()
                return 1
            print("canary: reply pending (%.0f min): %s"
                  % (age / 60.0, detail), flush=True)
            return 0
        if age > REPLY_SECS:
            fail("reply: no conversation known and no reply to %s (%.0f min; "
                 "canary room: no %s reply in the last %d message(s))"
                 % (token, age / 60.0, bridge_nick, len(hist)))
            CANARY_PENDING.unlink()
            return 1
        print("canary: reply pending (no conversation known)", flush=True)
        return 0

    # ---- phase A: wake + connect + deliver a tokenized ping ---------------
    t0 = time.time()
    recs = bridge.status_records()
    if not recs:
        fail("wake: no autolith session answered status")
        return 1
    rec = recs[0]
    # 2026-09-30: status answering is NOT health. Require recent turn activity.
    age = newest_record_age(rec.get("conversation"))
    stale_h = float(B.get("stale_turn_hours", 5))
    if age is None:
        fail("wake: session %s answers status but conversation %s has no records "
             "on disk" % (rec["session"], rec.get("conversation")))
        return 1
    if age > stale_h * 3600:
        fail("wake: session %s answers status but conversation %s has had NO new "
             "records for %.1f h - the agent is not completing turns (provider "
             "400 / over-limit context?). Check the alagent pane."
             % (rec["session"], rec.get("conversation"), age / 3600.0))
        return 1
    print("canary: wake ok (session %s; newest record %.1f h old)"
          % (rec["session"], age / 3600.0), flush=True)

    ok, detail = bridge_connected()
    if not ok:
        fail("connect: %s" % detail)
        return 1
    print("canary: connect ok (%s)" % detail, flush=True)

    if not room:
        fail("deliver: no [bridge] canary_muc configured")
        return 1
    token = "canary-%d" % int(time.time())
    line = ("[canary] @%s round-trip test %s - reply with the token to "
            "confirm (wake+connect+deliver ok, %.1fs)"
            % (trigger, token, time.time() - t0))
    ok, detail = probe(room, nick, line)
    if not ok:
        fail("deliver: %s" % detail)
        return 1
    try:
        CANARY_PENDING.parent.mkdir(parents=True, exist_ok=True)
        CANARY_PENDING.write_text(token)
    except OSError as e:
        print("canary: pending write failed (%s); round trip unverified" % e,
              flush=True)
        return 1
    print("canary: %s; token %s - reply verified on the next run"
          % (detail, token), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
