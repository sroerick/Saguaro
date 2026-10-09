#!/bin/sh
# Restart the CL bridge. Kill the session and reap its transport, then let
# start-sessions.sh respawn it -- so the command line (stderr -> bridge.err),
# the remain-on-exit option and the session-up probe live in ONE place. The
# old duplicate here had already drifted: it respawned WITHOUT the stderr
# capture, so a bridge restarted by hand lost its crash output.
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$(id -u)" = "0" ]; then
  su - al -c "tmux kill-session -t xmpp-bridge" 2>/dev/null
else
  tmux kill-session -t xmpp-bridge 2>/dev/null
fi
sleep 2
pkill -f "openssl s_client -quiet -starttls xmpp" 2>/dev/null
sleep 2
if [ "$(id -u)" = "0" ]; then
  su - al -c "OPENCLIWSP_DIR='$DIR' BRIDGE_CONFIG='$DIR/config.toml' /bin/sh '$DIR/start-sessions.sh'"
else
  OPENCLIWSP_DIR="$DIR" BRIDGE_CONFIG="$DIR/config.toml" /bin/sh "$DIR/start-sessions.sh"
fi
