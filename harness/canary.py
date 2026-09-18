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
import asyncio
import slixmpp
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge
from heartbeat import push

B = bridge.B
XMPP_C2S_PORT = "5222"   # slixmpp ClientXMPP default; revisit if the server moves


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
        if comm.startswith("python"):
            return child
    return None


def bridge_connected():
    """(ok, detail): the bridge process holds a TCP connection to the
    XMPP server. A tmux session can outlive a wedged client; the socket
    is the honest signal."""
    pid = bridge_pid()
    if not pid:
        return False, "bridge python process not found under tmux xmpp-bridge"
    out = bridge.run(["/usr/bin/fstat", "-p", pid], timeout=15)
    hits = [l for l in out.splitlines()
            if "internet" in l and ":" + XMPP_C2S_PORT in l]
    if not hits:
        return False, ("bridge pid %s holds no TCP connection to the XMPP "
                       "server (port %s)" % (pid, XMPP_C2S_PORT))
    return True, hits[0].split()[-1]


class Probe(slixmpp.ClientXMPP):
    """One-shot client: authenticate, join the canary room, post one
    line, disconnect. self.stage records how far it got."""

    def __init__(self, room, line, nick):
        pw = Path(B["password_file"]).read_text().strip()
        super().__init__(B["jid"], pw)
        self.register_plugin("xep_0045")
        self.room, self.line, self.nick = room, line, nick
        self.stage = "auth"
        self.done = asyncio.Event()
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("failed_auth", self.on_fail)
        # NOTE: no connection_failed handler on purpose - the server
        # occasionally answers the FIRST TLS handshake with a protocol
        # version alert, and slixmpp's connect loop retries successfully
        # ~1s later. Bailing out on that event would fail the canary on
        # a healthy path; the wait_for timeout is the real bound.

    def on_fail(self, e):
        if self.stage == "auth":
            self.stage = "auth failed (%s)" % type(e).__name__
        self.done.set()

    async def on_start(self, e):
        self.stage = "deliver"
        try:
            await self.plugin["xep_0045"].join_muc_wait(
                self.room, self.nick, timeout=15)
            await asyncio.sleep(0.5)   # let the join presence settle
            self.send_message(mto=self.room, mbody=self.line,
                              mtype="groupchat")
            await asyncio.sleep(1.0)   # let the stanza flush
        except Exception as e:
            self.stage = "deliver failed: %s: %s" % (type(e).__name__, e)
        self.done.set()


async def probe(room, nick, line):
    p = Probe(room, line, nick)
    p.connect()
    try:
        await asyncio.wait_for(p.done.wait(), timeout=45)
        await asyncio.sleep(0.3)   # let the socket close quietly
    except asyncio.TimeoutError:
        return False, "probe timed out at stage %s" % p.stage
    finally:
        try:
            d = p.disconnect()
            if asyncio.iscoroutine(d):
                await asyncio.wait_for(d, timeout=5)
        except Exception:
            pass
    if p.stage.startswith("auth"):
        return False, "XMPP %s (check password_file)" % p.stage
    if p.stage.startswith("deliver failed"):
        return False, p.stage
    return True, "delivered to %s as %s" % (room, nick)


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
    print("canary: wake ok (session %s)" % rec["session"], flush=True)

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
    ok, detail = asyncio.run(probe(room, nick, line))
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
