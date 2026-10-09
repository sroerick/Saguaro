#!/bin/sh
# Restart the CL bridge. Works when run as the deploy user directly or via
# root (the su path); paths derive from this script's own directory.
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
  su - al -c "cd '$DIR' && tmux new-session -d -s xmpp-bridge \"sbcl --script '$DIR/bridge.lisp'\""
else
  cd "$DIR" && tmux new-session -d -s xmpp-bridge "sbcl --script $DIR/bridge.lisp"
fi
