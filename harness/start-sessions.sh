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
# 2026-09-19 (agora repair): AUTOLITH_COMPACTION_THRESHOLD=95 for alagent.
# The standing conversation T6LyTXx sits at ~223K/272K tokens; the automatic
# compaction (at the default 80% = ~218K) fails with
# "Compaction produced no summary text." -> agent-loop-error -> image exits
# 70 -> watchdog restarts -> next turn compacts again -> crash loop (hourly,
# every heartbeat). Raising the threshold lets normal turns run without a
# compaction attempt until ~258K. REVERT once the conversation is reset or
# the upstream compaction bug is fixed.
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
RESUME=""; [ -n "$CONV" ] && RESUME="resume $CONV"

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
