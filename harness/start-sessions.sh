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
    "CL_EXEC_SANDBOX_PROCESS_GROUP_HELPER=$SB_HELPER AUTOLITH_COMPACTION_THRESHOLD=80 $AL $RESUME --permissions full 2>&1"
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
  # the tmux pane, so DO NOT tee here: that would double every line.
  BRIDGE_CMD="sbcl --script $DIR/bridge.lisp"
  BRIDGE_PAT="sbcl --script $DIR/bridge.lisp"
fi

if ! session_up xmpp-bridge "$BRIDGE_PAT"; then
  tmux kill-session -t xmpp-bridge 2>/dev/null || true
  tmux new-session -d -s xmpp-bridge "$BRIDGE_CMD"
fi
