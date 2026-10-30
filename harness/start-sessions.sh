#!/bin/sh
# Start (or leave running) the Autolith agent + XMPP bridge tmux sessions.
# Idempotent: safe at boot and by hand.
#
# Reads the standing conversation id from config.toml ([autolith] conv).
# Env overrides:
#   OPENCLIWSP_DIR  bridge checkout (default: this script's directory)
#   BRIDGE_CONFIG   config path     (default: $OPENCLIWSP_DIR/config.toml)
#   AUTOLITH_BIN    agent CLI       (default: $HOME/.local/bin/autolith)
#
# tmux session names are the documented constants: alagent (the agent TUI)
# and xmpp-bridge (this gateway). watchdog.py checks for both.
#
# 2026-09-19 compaction-crash history:
# The standing conversation (T6LyTXx) hit the 272K-token ceiling; autolith
# auto-compaction failed with "Compaction produced no summary text." ->
# agent-loop-error -> image exits 70 -> watchdog restart loop (hourly alerts).
# Interim "agora repair" raised AUTOLITH_COMPACTION_THRESHOLD=95 to steal time.
# Proper fix (2026-09-19): autolith upgraded 0.46.1 -> 0.50.0 (compaction
# hardened in 0.48.0) AND the standing conversation was rotated to a fresh id
# in config.toml. The override was briefly removed, then RESTORED at 95
# (85480f8) when compaction still failed. The agent model was pinned to
# hf:zai-org/GLM-5.3-Flash (preferences.sexp) after the model behind
# syn:large:text flipped to DeepSeek-V4.1-Flash, which returns EMPTY assistant
# messages on huge summarize calls; GLM-5.3-Flash returns text reliably on
# identical contexts.
#
# 2026-09-24 threshold 95 -> 80 (A2WnCgc death):
# autolith 0.50.0 assumes a 272K window for GLM-5.3-Flash, and the compaction
# trigger compares provider-REPORTED total_tokens against window*thr/100
# (agent/should-compact-p, configuration-compaction-token-limit). On this
# provider the reported total undercounts the provider's own real count ~2.1x:
# the ledger said 262,059 (input 246,043 + output 16,016) while the next
# provider call - the compaction upload itself - was rejected at 550,034
# input tokens vs the TRUE 524,288 window. At 95 the trigger (272K*0.95 =
# ~258K est) maps to ~550K real, past the ceiling, so compaction died every
# time and manual compaction died with it. At 80 the trigger is ~218K est
# (~457K real, ~13% headroom).
# Do NOT set AUTOLITH_CONTEXT_WINDOW=524288 at this threshold: the trigger is
# window*thr on REPORTED totals, so 524288*0.80 = 419K est maps to ~880K real
# for the compaction upload - death either way. If the true window is ever
# set, drop the threshold to ~40 to keep the trigger at ~210-230K est.
# 2026-09-30 threshold 80 -> 60 (K3CL8Cm death: 36h of SILENT failure):
# Same provider undercount as the 9/24 note below, but worse. The agent's own
# meter read 220K/272K while the very next provider payload was 526,664 tokens
# against the model's TRUE 524,288 window, so EVERY turn returned HTTP 400,
# nothing was recorded and nothing was delivered for 36 h -- with no crash, no
# restart loop, and heartbeat/canary both reporting healthy. 220K reported x
# ~2.4 = 526K real. At 80 the trigger (217.6K reported) maps to ~521K real:
# already past the ceiling, and the compaction upload itself 400s, so
# compaction can never recover the conversation. At 60 the trigger is 163.2K
  # reported ~= 390K real, i.e. ~134K (26%) headroom.
  # 2026-10-11 (revised same day): AUTOLITH_CONTEXT_WINDOW=524288 + threshold 80.
  # The "meter undercounts ~2.1-2.4x" story line 43+ is RETIRED. glm's own usage
  # series in E-5WjMcb is self-consistent turn to turn (65,703 -> 71,391 -> 83,688
  # prompt tokens, deltas matching turn growth, cached tokens itemized), so its
  # usage report ~= its own validation count; if glm really validated at ~2.2x its
  # reports, EVERYTHING would have 400ed long before the wall - it didn't. The
  # 550,034/526,664 rejections are better explained by (a) the OLD compaction path
  # re-uploading the full history: 0.62.1's agent-compact-conversation docstring
  # says the native-checkpoint integration exists to avoid "a second upload of the
  # full pre-compaction history" - 246K prompt re-uploaded whole is exactly the
  # 550K glm rejected; and (b) cross-model metering: the trigger reads the NEWEST
  # usage record (store.lisp conversation-append-provider-metadata + :provider
  # record projection both overwrite conversation-last-total-tokens), and in the
  # manual /model hop era that newest record was often KIMI-reported, whose counts
  # (e.g. 2,289,191 input in one kimi record here) are not comparable to glm's.
  # With compaction now kimi's job (in-image borrow, compact-model.lisp), glm
  # never issues compaction requests, so the trigger only sets WHEN to compact:
  # 80% of the true window = floor(524288*0.80) = 419,430 reported, ~105K margin
  # under glm's own validation wall. Caveat: until the next glm response, the
  # meter may be kimi-stamped (one small extra compaction possible, self-
  # correcting). Applied live in-image 10-11 (env setf + configuration-set;
  # verified 524288/80/419430) and here for restarts. The watchdog proactive
  # guard stays retired (COMPACT_RESCUE_ENABLED=False) - the in-image trigger
  # governs.
DIR="${OPENCLIWSP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CFG="${BRIDGE_CONFIG:-$DIR/config.toml}"
export BRIDGE_CONFIG="$CFG"
PY="$DIR/venv/bin/python"; [ -x "$PY" ] || PY=python3
AL="${AUTOLITH_BIN:-$HOME/.local/bin/autolith}"
# Shell execution under --permissions full needs the cl-exec-sandbox
# process-group helper (0.50.0 ships no prebuilt one, and the upstream
# helper's setpgid(0,0) is EPERM here: every Autolith-spawned process is
# already a session leader, pgid == pid). Local build in ~/.local/libexec
# skips setpgid when already its own group leader. Re-asserted 2026-09-20:
# the 0659f26 export was lost in the 6b34e1e comment rewrite and the live
# session came up without it (every shell.run failed until set by hand).
SB_HELPER="$HOME/.local/libexec/cl-exec-sandbox-process-group"
if [ -x "$SB_HELPER" ]; then
  export CL_EXEC_SANDBOX_PROCESS_GROUP_HELPER="$SB_HELPER"
fi

# First boot on a fresh workspace: generate the persona file if there is none.
"$PY" "$DIR/scripts/gen_agents.py" 2>/dev/null || true

CONV="$("$PY" -c 'import os,sys,tomllib
b = tomllib.loads(open(os.environ["BRIDGE_CONFIG"]).read())["autolith"]
print(b.get("conv", ""))' 2>/dev/null)"
# Resume only when the standing conversation actually exists on disk. A
# fresh/rotated conv id in config.toml therefore starts a brand-new
# conversation (reset-friendly) instead of failing to resume a phantom.
RESUME=""
if [ -n "$CONV" ] && [ -d "$HOME/.local/share/autolith/conversations/$CONV" ]; then
  RESUME="resume $CONV"
fi

# Live-process guard (2026-09-19 fix). A tmux session whose command has
# already exited is a DEAD window, not a running service: tmux retains the
# pane and its last output, so `has-session` alone returns success and the
# classic `|| new-session` idempotence skips the respawn. gregor stayed down
# on 2026-09-19 for exactly this reason. Check for the actual process.
session_up() {   # $1 = tmux session name   $2 = pgrep pattern for its process
  tmux has-session -t "$1" 2>/dev/null || return 1
  pgrep -qf "$2" || return 1
  return 0
}

if ! session_up alagent "autolith"; then
  tmux kill-session -t alagent 2>/dev/null || true
  tmux new-session -d -s alagent \
    "CL_EXEC_SANDBOX_PROCESS_GROUP_HELPER=$SB_HELPER AUTOLITH_COMPACTION_THRESHOLD=80 AUTOLITH_CONTEXT_WINDOW=524288 $AL $RESUME --permissions full 2>&1"
fi

# Bridge engine (2026-09-27): the Common Lisp bridge is the default; set
# BRIDGE_ENGINE=python to fall back to bridge.py. Both keep the same tmux
# session name, log path, config file and turn-in-flight marker, so the
# watchdog/canary contracts are unchanged.
BRIDGE_ENGINE="${BRIDGE_ENGINE:-lisp}"
if [ "$BRIDGE_ENGINE" = "python" ]; then
  # bridge.py prints to stdout only; tee captures it into bridge.log
  BRIDGE_CMD="$PY $DIR/bridge.py 2>&1 | tee -a $DIR/bridge.log"
  BRIDGE_PAT="saguaro-live/harness/bridge.py"
else
  # bridge.lisp writes bridge.log itself (log-line) AND echoes to stdout for
  # the tmux pane, so DO NOT tee here: that would double every line. stderr
  # goes to bridge.err: SBCL's unhandled-error backtrace otherwise lands only
  # on the tmux pane, which dies with the session, so a bridge death left no
  # evidence at all (2026-10-09). stdout stays on the pane + bridge.log.
  [ -f "$DIR/bridge.err" ] && [ "$(wc -c < "$DIR/bridge.err")" -gt 1048576 ] \
    && mv -f "$DIR/bridge.err" "$DIR/bridge.err.1"
  # 2026-10-11: the ~768M default heap exhausted because the parse cache
  # retained the whole 49MB conversation every turn. Fixed in bridge.lisp
  # (records-for-file now PRUNES consumed records; the retained set stays
  # small), so the bridge is back on the DEFAULT heap. If it ever needs more:
  # al's login-class datasize cap is 1536M (>=1408M fails to allocate).
  # 2026-10-30: the default 805MB dynamic space was exhausted while
  # collecting a turn on a 93MB conversation. Parsing is now incremental
  # (rescan touches only the newest chunks), but keep headroom.
  BRIDGE_CMD="sbcl --dynamic-space-size 1024 --script $DIR/bridge.lisp 2>>$DIR/bridge.err"
  BRIDGE_PAT="bridge.lisp"
fi

if ! session_up xmpp-bridge "$BRIDGE_PAT"; then
  tmux kill-session -t xmpp-bridge 2>/dev/null || true
  tmux new-session -d -s xmpp-bridge "$BRIDGE_CMD"
  # keep the pane (and its final output) after the command exits, so a crash
  # can be read post-mortem instead of vanishing with the session
  tmux set-option -t xmpp-bridge remain-on-exit on 2>/dev/null || true
fi
