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
import re
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
BRIDGE_RESTART_MIN_GAP = 600  # never restart more than once per 10 min
BRIDGE_RESTART_MARK = Path.home() / ".cache" / "saguaro-bridge-restart"
# The bridge's turn-in-flight marker (bridge.py turn_begin/turn_end). While the
# bridge is awaiting an agent turn, restarting it throws the answer away: the
# agent finishes the reply into a conversation nobody is polling, which is
# exactly the "he was typing, then nothing" report of 2026-09-23.
TURN_MARK = Path.home() / ".cache" / "saguaro-turn-active"
TURN_DEFER_SECS = float(A.get("turn_timeout_secs", 900)) + 600
# --- no-text turn guard (added 2026-10-09) ---------------------------------
# A turn can end with 0 assistant texts: at large context autolith runs a
# mid-turn compaction whose summarization call comes back with no visible
# text, raises PROVIDER-PROTOCOL-ERROR "Compaction produced no summary text."
# and aborts the turn before writing any record. The bridge still delivers
# "(no text output)" to the peer, but that is cryptic and the watchdog stayed
# silent (no crash, session idle, :5222 live). bridge.lisp writes NO_TEXT_MARK
# on such a turn; page the owner once per marker.
NO_TEXT_MARK = Path.home() / ".cache" / "saguaro-no-text-turn"
NO_TEXT_ALERTED = Path.home() / ".cache" / "saguaro-no-text-alerted"
NO_TEXT_MAX_AGE = 7200  # ignore a marker older than this (stale)


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


def bridge_connected():
    """The bridge holds a live TCP connection to the chat server (port 5222).

    Process-alive is not enough: a wedged slixmpp loop can keep the process
    up while its XMPP/TCP connection is gone. Two topologies exist now:
      - bridge.py (slixmpp): the python process owns the socket
      - bridge.lisp (CL): /usr/bin/openssl s_client is the TLS tunnel and
        owns the socket, as a CHILD of sbcl (2026-09-27)
    So check the process and all of its descendants."""
    pid = bridge_pid()
    if not pid:
        return False
    pids = [str(pid)] + sh(["/usr/bin/pgrep", "-P", str(pid)]).stdout.split()
    for p in pids:
        out = sh(["/usr/bin/fstat", "-p", p]).stdout
        if ":5222" in out:
            return True
    return False


def bridge_pid():
    """The bridge's python process id: pane leader -> child whose comm is
    python (ps truncates the command line, so match on comm, not args)."""
    leader = sh(["/usr/bin/tmux", "list-panes", "-t", "xmpp-bridge",
                 "-F", "#{pane_pid}"]).stdout.split()
    if not leader:
        return None
    for child in sh(["/usr/bin/pgrep", "-P", leader[0]]).stdout.split():
        comm = sh(["/bin/ps", "-o", "comm=", "-p", child]).stdout.strip()
        if comm.startswith("python") or comm.startswith("sbcl"):
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


def turn_in_flight():
    """True when the bridge is mid-turn and must not be restarted. A stale
    marker (older than the turn timeout + slack) means the waiter is gone, so
    repairs may proceed."""
    try:
        age = time.time() - TURN_MARK.stat().st_mtime
    except OSError:
        return False
    if age > TURN_DEFER_SECS:
        return False
    print("watchdog: bridge is mid-turn (%.0fs in) - deferring repair"
          % age, flush=True)
    return True


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


def capture_crash(tag):
    """Preserve WHY the bridge died: the tmux pane (SBCL's unhandled-error
    backtrace / exit message, kept alive by remain-on-exit) plus the tail of
    bridge.err, into a timestamped crash-<ts>.log beside the harness. Never
    raises - a failed capture must not break the repair."""
    try:
        here = Path(__file__).resolve().parent
        stamp = time.strftime("%Y%m%d-%H%M%S")
        out = ["=== crash %s (%s) ===" % (stamp, tag)]
        cap = sh(["/usr/bin/tmux", "capture-pane", "-p", "-S", "-300",
                  "-t", "xmpp-bridge"], timeout=20)
        out.append("--- tmux pane (tail) ---")
        out.append(cap.stdout or "(no pane output / session gone)")
        err = here / "bridge.err"
        if err.exists():
            lines = err.read_text(errors="replace").splitlines()[-200:]
            out.append("--- bridge.err (tail) ---")
            out.extend(lines or ["(empty)"])
        (here / ("crash-%s.log" % stamp)).write_text("\n".join(out) + "\n")
        print("watchdog: crash captured to crash-%s.log" % stamp, flush=True)
    except Exception as e:
        print("watchdog: crash capture failed: %s" % e, flush=True)


# --- proactive compaction guard (added 2026-10-10) ------------------------
# A standing conversation on a reasoning model that cannot summarize itself
# aborts turns once it is large: autolith runs a mid-turn compaction, the
# summarization call comes back with no visible assistant text, and
# PROVIDER-PROTOCOL-ERROR "Compaction produced no summary text." aborts the
# turn BEFORE any record is written (0 assistant texts -> the bridge delivers
# "(no text output)"). Four occurrences on 2026-10-09/10 at ~163-171K on the
# 272K meter, model opencode/glm-5.3-flash. The manual recovery is a forced
# `(compact)`; glm does it reliably while the conversation is small and
# kimi-k3 does it at any size. So we compact PROACTIVELY, well below the
# failure zone, borrowing kimi only if the pinned model cannot.
COMPACT_AT_K = 120          # pane meter (K) at/above which we compact
# 2026-10-11: compaction is handled INSIDE the image now (compact-model.lisp
# borrows kimi for the compaction and restores the pinned provider). The
# external model-switching rescue below is RETIRED by default: it hand-switched
# models and its failure path sent C-c, which kills the whole app on autolith
# 0.62.1. Set this True only if the in-image swap is removed or broken.
COMPACT_RESCUE_ENABLED = False
COMPACT_DONE_K = 40         # a compaction "worked" once the meter is below this
COMPACT_MARK = Path.home() / ".cache" / "saguaro-compact-guard"
COMPACT_MIN_GAP = 900       # at most one guard cycle per 15 min
FALLBACK_MODEL = "opencode/kimi-k3"
PICKER_HINT = "pick the reasoning effort"


def _status_raw():
    return sh([A["bin"], "localgroup", "status", "--sexp"], timeout=30).stdout


def _status_field(raw, name):
    m = re.search(r":%s\s+\"?([^\s\")]+)" % re.escape(name), raw)
    return m.group(1) if m else None


def _pane():
    return sh(["/usr/bin/tmux", "capture-pane", "-p", "-t", "alagent"],
              timeout=20).stdout


def agent_ctx_k():
    """Context meter reading from the agent pane, in K (e.g. 171)."""
    m = re.search(r"ctx \[[^\]]*\]\s*(\d+)\s*K?\s*/", _pane())
    return int(m.group(1)) if m else None


def _wait_idle(timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if _status_field(_status_raw(), "STATE") == ":IDLE":
            return True
        time.sleep(4)
    return False


def _wait_ctx_below(target_k, timeout):
    end = time.time() + timeout
    while time.time() < end:
        k = agent_ctx_k()
        if k is not None and k <= target_k:
            return True
        time.sleep(5)
    return False


def _set_model(model, session):
    """Switch model via the agent and answer the reasoning-effort picker."""
    sh([A["bin"], "localgroup", "tell", session, "/model %s" % model],
       timeout=30)
    for _ in range(4):
        time.sleep(3)
        if PICKER_HINT in _pane():
            sh(["/usr/bin/tmux", "send-keys", "-t", "alagent", "Enter"],
               timeout=20)
        elif _status_field(_status_raw(), "STATE") == ":IDLE":
            break
    _wait_idle(30)


def _do_compact(session):
    """Tell the agent to compact and wait for the context meter to drop.

    The guard only ever calls this with the meter at/above COMPACT_AT_K, and the
    meter holds its value until the compaction finishes (it does not flash to 0
    mid-flight), so 'meter now below COMPACT_DONE_K' is a faithful success test.
    On failure/timeout, abort any wedged operation with C-c and let the caller
    escalate."""
    sh([A["bin"], "localgroup", "tell", session, "(compact)"], timeout=30)
    if _wait_ctx_below(COMPACT_DONE_K, 240):
        return True
    sh(["/usr/bin/tmux", "send-keys", "-t", "alagent", "C-c"], timeout=20)
    time.sleep(3)
    return False


def rescue_compact(session):
    """Free the standing conversation: force a compaction, borrowing kimi-k3
    (which can summarize any size) only if the pinned model cannot."""
    if not session or not _wait_idle(30):
        print("watchdog: rescue_compact: session not idle; skipping",
              flush=True)
        return False
    model = _status_field(_status_raw(), "MODEL")
    ok = _do_compact(session)
    if not ok:
        print("watchdog: rescue_compact: %s could not compact; trying %s"
              % (model, FALLBACK_MODEL), flush=True)
        _set_model(FALLBACK_MODEL, session)
        ok = _do_compact(session)
        if model and model != FALLBACK_MODEL:
            _set_model(model, session)
    print("watchdog: rescue_compact: %s (model %s)"
          % ("compacted" if ok else "FAILED", model), flush=True)
    return ok


def compact_guard_recent():
    try:
        return (time.time() - COMPACT_MARK.stat().st_mtime) < COMPACT_MIN_GAP
    except OSError:
        return False


def check_compact_guard(rec):
    """Proactively compact before the conversation reaches the size at which
    the model can no longer summarize it. Returns True if it compacted."""
    if not COMPACT_RESCUE_ENABLED:
        return False
    if compact_guard_recent():
        return False
    if rec.get("active") or not rec.get("idle"):
        return False
    k = agent_ctx_k()
    if k is None or k < COMPACT_AT_K:
        return False
    print("watchdog: context at %dK (>= %dK) - proactively compacting"
          % (k, COMPACT_AT_K), flush=True)
    try:
        COMPACT_MARK.parent.mkdir(parents=True, exist_ok=True)
        COMPACT_MARK.touch()
    except OSError:
        pass
    ok = rescue_compact(rec.get("session"))
    if not ok:
        try:
            push(B["allow"][0],
                 "watchdog: the agent's conversation reached %dK tokens and "
                 "could NOT be auto-compacted (the compaction bug). It needs "
                 "manual eyes - rotate the standing conversation or force a "
                 "compaction under another model." % k)
        except Exception as e:
            print("watchdog: push failed: %s" % e, flush=True)
    return ok


def check_no_text_turn(rec, auto_fixed=False):
    """Page the owner when the bridge reports a turn with no assistant text."""
    try:
        age = time.time() - NO_TEXT_MARK.stat().st_mtime
    except OSError:
        return
    if age > NO_TEXT_MAX_AGE:
        return
    try:
        if NO_TEXT_ALERTED.stat().st_mtime >= NO_TEXT_MARK.stat().st_mtime:
            return
    except OSError:
        pass
    try:
        NO_TEXT_ALERTED.touch()
    except OSError:
        pass
    if not auto_fixed and rec and COMPACT_RESCUE_ENABLED:
        k = agent_ctx_k()
        if k is not None and k >= COMPACT_AT_K:
            auto_fixed = rescue_compact(rec.get("session"))
    if auto_fixed:
        msg = ("the agent's last turn produced NO assistant text (%.0f min "
               "ago) - the known compaction failure at large context. I "
               "auto-compacted the conversation, so it is responsive again: "
               "just re-ask." % (age / 60.0))
    else:
        msg = ("the agent's last turn produced NO assistant text (%.0f min "
               "ago) - a compaction failure at large context (autolith: "
               "\"Compaction produced no summary text.\"), which aborts the "
               "turn before it writes anything. Compaction is now borrowed to "
               "kimi in-image; if this still happens, check "
               "/home/al/.cache/compact-model-swap.log, then re-ask or rotate "
               "the conversation." % (age / 60.0))
    try:
        push(B["allow"][0], msg)
    except Exception as e:
        print("watchdog: push failed: %s" % e, flush=True)


def bridge_restart_recent():
    try:
        return (time.time() - BRIDGE_RESTART_MARK.stat().st_mtime) < BRIDGE_RESTART_MIN_GAP
    except OSError:
        return False


def restart_bridge(reason):
    print("watchdog: %s -> restarting xmpp-bridge" % reason, flush=True)
    capture_crash(reason)
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
    if "bridge" in reason:
        capture_crash(reason)
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

    # Process alive but NOT holding its chat connection: wedged slixmpp.
    if bridge_pid() and not bridge_restart_recent() and not bridge_connected():
        if turn_in_flight():
            return
        restart_bridge("bridge process is alive but has no live :5222 connection")
        return

    # bridge CPU-spin guard: cheap liveness first, then the 10s CPU sample.
    if bridge_pid() and not bridge_restart_recent() and bridge_spinning():
        if turn_in_flight():
            return
        restart_bridge("xmpp-bridge is burning ~100% CPU during a turn "
                       "(heavy polling, not a leak)")
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

    # Proactively keep the conversation below the size at which the model can
    # no longer summarize it; then page about any 0-text turn (auto-fixed or not).
    compacted = check_compact_guard(rec)
    check_no_text_turn(rec, compacted)

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
