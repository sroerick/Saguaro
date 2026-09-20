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
# 2026-09-19 compaction-crash history (RESOLVED):
# The standing conversation hit the 272K-token ceiling; autolith auto-compaction
# (default 80%) failed with "Compaction produced no summary text." ->
# agent-loop-error -> image exits 70 -> watchdog restart loop (hourly alerts).
# Interim "agora repair" raised AUTOLITH_COMPACTION_THRESHOLD=95 to steal time.
# Proper fix (2026-09-19): autolith upgraded 0.46.1 -> 0.50.0 (compaction
# hardened in 0.48.0: "Harden conversation compaction, recovery, process
# handoff...") AND the standing conversation was rotated to a fresh id in
# config.toml. The threshold override is therefore REMOVED (default 80%.
# compaction is now healthy and the conversation starts small).
# 2026-09-19 compaction-crash history — STILL OPEN upstream:
# Conversations balloon quickly (the merge/deploy + heartbeat work injects large
# repo/git context; observed 0 -> ~221K/272K tokens in ~2h). Autolith auto-compaction
# fails with "Compaction produced no summary text." (agent/runtime.lisp
# agent-compact-conversation: the Synthetic/syn:large:text summarizer returns an
# empty summary -> provider-protocol-error -> image exits 70).
#
# 0.46.1 -> 0.50.0 was tried (changelog 0.48.0: "Harden conversation compaction"),
# but the bug reproduces identically on 0.50.0 with the synthetic provider
# (confirmed live 2026-09-19). WORKAROUND that actually holds: keep the compaction
# threshold above the normal operating range (95% = ~258K) so the broken compactor
# never fires during normal work, and rotate the standing conversation before it
# reaches ~258K. Without this override (default 80% = ~218K) the compactor fires
# mid-task and returns empty replies (gregor "goes down"). Real fix = upstream.
DIR="${OPENCLIWSP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CFG="${BRIDGE_CONFIG:-$DIR/config.toml}"
export BRIDGE_CONFIG="$CFG"
PY="$DIR/venv/bin/python"; [ -x "$PY" ] || PY=python3
AL="${AUTOLITH_BIN:-$HOME/.local/bin/autolith}"

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
    "AUTOLITH_COMPACTION_THRESHOLD=95 $AL $RESUME --permissions full 2>&1"
fi

if ! session_up xmpp-bridge "saguaro-live/harness/bridge.py"; then
  tmux kill-session -t xmpp-bridge 2>/dev/null || true
  tmux new-session -d -s xmpp-bridge \
    "$PY $DIR/bridge.py 2>&1 | tee -a $DIR/bridge.log"
fi
