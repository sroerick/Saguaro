#!/usr/bin/env python3
"""End-to-end chat-path canary for the saguaro harness.

Proves the three hops that "the processes exist" checks cannot:
  1. wake    - an autolith session answers `localgroup status`.
  2. connect - the XMPP credentials still authenticate (a fresh one-shot
               client catches a rotated password even while the bridge's
               long-lived session lingers), AND the bridge process itself
               still holds its server connection.
  3. deliver - one message actually leaves through the XMPP stack into
               the configured canary room (a test MUC, never the owner).

Run by watchdog.py on the [bridge] canary cadence, or by hand:

    harness/venv/bin/python harness/canary.py

One log line per hop on success (goes to watchdog.log when cron-run);
exit 0. On failure: best-effort XMPP alert to the owner, exit 1.
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


def main():
    """Run all three hops. Returns the process exit code (0 = green)."""
    if str(B.get("canary", "off")).lower() != "on":
        print('canary: disabled (set [bridge] canary = "on" to arm)')
        return 2
    room = B.get("canary_muc") or ""
    nick = B.get("muc_nick", "agent") + "-canary"
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
    line = ("[canary] ok - chat path alive (wake+connect+deliver, %.1fs)"
            % (time.time() - t0))
    ok, detail = probe(room, nick, line)
    if not ok:
        fail("deliver: %s" % detail)
        return 1
    print("canary: %s" % detail, flush=True)

    mark = Path.home() / ".cache" / "saguaro-canary"
    try:
        mark.parent.mkdir(parents=True, exist_ok=True)
        mark.write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
