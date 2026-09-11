#!/usr/bin/env python3
"""Liveness watchdog for the Autolith agent (cron, every 5 min).

Checks, in order:
  1. An autolith session answers `localgroup status`.
  2. The xmpp-bridge tmux session is alive.
Anything down -> run start-sessions.sh, wait, re-check, push an XMPP alert.

Then, if a turn looks HUNG — active turn AND the image process used ~0 CPU
over a 6s sample AND holds no internet sockets AND the durable conversation
log hasn't flushed in 10+ min (log flushes only at provider response end) —
do the kill+resume drill and push an alert. Conversation history survives.

Silent exit when everything is healthy.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge
from heartbeat import push

A, B = bridge.A, bridge.B
START = B.get("start_script", str(Path(__file__).resolve().parent / "start-sessions.sh"))


def sh(cmd, timeout=90):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def agent_status():
    try:
        return bridge.status_records()
    except Exception as e:
        print("watchdog: status failed: %s" % e, flush=True)
        return []


def bridge_alive():
    return sh(["/usr/bin/tmux", "has-session", "-t", "xmpp-bridge"]).returncode == 0


def image_idle_dead(pid):
    """Observed hung-image signature: 0 CPU across 6s and no internet sockets."""
    t1 = sh(["/bin/ps", "-o", "time=", "-p", str(pid)]).stdout.strip()
    if not t1:
        return False  # process gone; other checks handle that
    time.sleep(6)
    t2 = sh(["/bin/ps", "-o", "time=", "-p", str(pid)]).stdout.strip()
    if t2 != t1:
        return False  # burning CPU: working
    out = sh(["/usr/bin/fstat", "-p", str(pid)]).stdout
    ext = [l for l in out.splitlines()
           if "internet" in l and "127.0.0.1" not in l and "::1" not in l]
    return not ext  # only the loopback attach channel counts as idle


def log_stale(rec):
    conv = rec.get("conversation")
    if not conv:
        return False
    d = Path.home() / ".local/share/autolith/conversations" / conv
    files = sorted(d.glob("*.sexp")) if d.is_dir() else []
    if not files:
        return False
    return (time.time() - files[-1].stat().st_mtime) > 600


def recover_and_alert(reason):
    print("watchdog: %s -> restarting" % reason, flush=True)
    sh(["/bin/sh", START], timeout=120)
    time.sleep(30)
    back = []
    if agent_status():
        back.append("agent")
    if bridge_alive():
        back.append("bridge")
    try:
        push(B["allow"][0], "watchdog: %s. Restarted; back online: %s."
             % (reason, ", ".join(back) or "nothing yet — needs eyes"))
    except Exception as e:
        print("watchdog: push failed: %s" % e, flush=True)


def main():
    recs = agent_status()
    if not recs:
        recover_and_alert("no autolith session answering")
        return
    if not bridge_alive():
        recover_and_alert("xmpp-bridge tmux session gone")
        return

    rec = recs[0]
    busy = rec.get("active") or not rec.get("idle")
    if busy and rec.get("pid") and image_idle_dead(rec["pid"]) and log_stale(rec):
        print("watchdog: turn looks hung (0 CPU, no sockets, stale log)",
              flush=True)
        sh([A["bin"], "localgroup", "kill", rec["session"]], timeout=120)
        time.sleep(2)
        sh(["/bin/sh", START], timeout=120)
        time.sleep(30)
        try:
            push(B["allow"][0],
                 "watchdog: the agent's turn was hung (no CPU/network for "
                 "10+ min), so I killed and resumed it. Conversation history "
                 "is intact — re-ask your question.")
        except Exception as e:
            print("watchdog: push failed: %s" % e, flush=True)
        return

    # healthy: stay silent


if __name__ == "__main__":
    main()
