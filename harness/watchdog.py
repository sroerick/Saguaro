#!/usr/bin/env python3
"""Liveness watchdog for the Autolith agent (cron, every 5 min).

Checks, in order:
  1. An autolith session answers `localgroup status`.
  2. The xmpp-bridge tmux session is alive.
  3. The bridge python process is not stuck in a CPU spin (a leaked
     slixmpp/asyncio loop burns a full core after ~2 days uptime; a fresh
     bridge uses ~1%).
Anything down -> run start-sessions.sh, wait, re-check, push an XMPP alert.

Then, if a turn looks HUNG — active turn AND the image process used ~0 CPU
over a 6s sample AND holds no internet sockets AND the durable conversation
log hasn't flushed in 10+ min (log flushes only at provider response end) —
do the kill+resume drill and push an alert. Conversation history survives.

Finally, when [bridge] canary = "on" and the cadence ([bridge] canary_secs)
has elapsed, run the end-to-end canary (canary.py): wake, connect, deliver
one message into the canary room. Alerts the owner on failure.

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

# --- bridge CPU-spin guard (added 2026-09-19) ------------------------------
# Signature observed 2026-09-19: bridge python (2.5 days uptime) advancing
# exactly 10 CPU-seconds per 10 wall-seconds while holding its one XMPP
# socket and logging nothing. One wedged loop = one full core on a 2-vCPU
# box, which starves the agent. Restarting the bridge clears it.
SPIN_SAMPLE_SECS = 10
SPIN_CPU_SECS = 8.0          # >= 80% of a core sustained across the sample
BRIDGE_RESTART_MIN_GAP = 3600  # never restart more than once an hour
BRIDGE_RESTART_MARK = Path.home() / ".cache" / "saguaro-bridge-restart"


def sh(cmd, timeout=90):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def agent_status():
    try:
        return bridge.status_records()
    except Exception as e:
        print("watchdog: status failed: %s" % e, flush=True)
        return []


def bridge_session_exists():
    """True when the tmux session exists at all (its pane may still hold a
    dead process's window)."""
    return sh(["/usr/bin/tmux", "has-session", "-t", "xmpp-bridge"]).returncode == 0


def bridge_alive():
    """The bridge service is genuinely serving: the tmux session exists AND
    its python process is running under the pane. A retained session whose
    command already exited is a dead window, not a running bridge — the
    exact failure mode that took gregor down on 2026-09-19."""
    return bridge_session_exists() and bridge_pid() is not None


def bridge_pid():
    """The bridge's python process id: pane leader -> child whose comm is
    python (ps truncates the command line, so match on comm, not args)."""
    leader = sh(["/usr/bin/tmux", "list-panes", "-t", "xmpp-bridge",
                 "-F", "#{pane_pid}"]).stdout.split()
    if not leader:
        return None
    for child in sh(["/usr/bin/pgrep", "-P", leader[0]]).stdout.split():
        comm = sh(["/bin/ps", "-o", "comm=", "-p", child]).stdout.strip()
        if comm.startswith("python"):
            return child
    return None


def cpu_seconds(pid):
    """Process CPU time from `ps -o time=` ([D-]HH:MM:SS.ss) as float seconds."""
    raw = sh(["/bin/ps", "-o", "time=", "-p", str(pid)]).stdout.strip()
    if not raw:
        return None
    days = 0
    if "-" in raw:
        d, raw = raw.split("-", 1)
        days = int(d)
    parts = raw.split(":")
    try:
        parts = [float(p) for p in parts]
    except ValueError:
        return None
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, s = parts
    return days * 86400 + h * 3600 + m * 60 + s


def bridge_spinning():
    """True when the bridge process is burning ~a full core right now."""
    pid = bridge_pid()
    if not pid:
        return False
    t1 = cpu_seconds(pid)
    if t1 is None:
        return False
    time.sleep(SPIN_SAMPLE_SECS)
    t2 = cpu_seconds(pid)
    if t2 is None:
        return False
    used = t2 - t1
    if used >= SPIN_CPU_SECS:
        print("watchdog: bridge pid %s used %.1fs CPU in %ds (spinning)"
              % (pid, used, SPIN_SAMPLE_SECS), flush=True)
        return True
    return False  # healthy: stay silent


def bridge_restart_recent():
    try:
        return (time.time() - BRIDGE_RESTART_MARK.stat().st_mtime) < BRIDGE_RESTART_MIN_GAP
    except OSError:
        return False


def restart_bridge(reason):
    print("watchdog: %s -> restarting xmpp-bridge" % reason, flush=True)
    sh(["/usr/bin/tmux", "kill-session", "-t", "xmpp-bridge"], timeout=30)
    time.sleep(2)
    sh(["/bin/sh", START], timeout=120)
    time.sleep(20)
    back = bridge_pid() is not None and bridge_alive()
    try:
        BRIDGE_RESTART_MARK.parent.mkdir(parents=True, exist_ok=True)
        BRIDGE_RESTART_MARK.touch()
    except OSError:
        pass
    if not back:
        try:
            push(B["allow"][0],
                 "watchdog: the XMPP bridge was spinning at ~100% CPU; I "
                 "restarted it but it is NOT back up — needs eyes.")
        except Exception as e:
            print("watchdog: push failed: %s" % e, flush=True)
    else:
        print("watchdog: bridge restarted cleanly (quiet; no push)", flush=True)


def canary_due():
    """True when the canary is enabled and its cadence has elapsed.
    The state file's mtime is the last green run."""
    if str(B.get("canary", "off")).lower() != "on":
        return False
    try:
        secs = float(B.get("canary_secs", 21600))
    except (TypeError, ValueError):
        secs = 21600.0
    mark = Path.home() / ".cache" / "saguaro-canary"
    try:
        return (time.time() - mark.stat().st_mtime) >= secs
    except OSError:
        return True


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
        if bridge_session_exists():
            # Session present but no bridge python process: the pane holds a
            # dead window. Respawn it rather than treating this as healthy.
            if bridge_restart_recent():
                print("watchdog: bridge process dead under live session; "
                      "restart is recent — skipping this cycle", flush=True)
            else:
                restart_bridge(
                    "bridge python process is dead under a live tmux session")
        else:
            recover_and_alert("xmpp-bridge tmux session gone")
        return

    # bridge CPU-spin guard: cheap liveness first, then the 10s CPU sample.
    if bridge_pid() and not bridge_restart_recent() and bridge_spinning():
        restart_bridge("xmpp-bridge is spinning at ~100% CPU (leak)")
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

    if canary_due():
        try:
            import canary   # lazy: a broken canary must not break the watchdog
            code = canary.main()
            if code:
                print("watchdog: canary exited %s" % code, flush=True)
        except Exception as e:
            print("watchdog: canary run failed: %s" % e, flush=True)

    # healthy: stay silent


if __name__ == "__main__":
    main()
