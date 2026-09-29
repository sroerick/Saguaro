#!/bin/sh
# Restart the CL bridge. Works when run as al directly or via root (su path).
# Al-native path needs no password; the su path is kept for root callers.
if [ "$(id -u)" = "0" ]; then
  su - al -c "tmux kill-session -t xmpp-bridge" 2>/dev/null
else
  tmux kill-session -t xmpp-bridge 2>/dev/null
fi
sleep 2
pkill -f "openssl s_client -quiet -starttls xmpp" 2>/dev/null
sleep 2
if [ "$(id -u)" = "0" ]; then
  su - al -c "cd /home/al/saguaro-live/harness && tmux new-session -d -s xmpp-bridge \"sbcl --script /home/al/saguaro-live/harness/bridge.lisp\""
else
  cd /home/al/saguaro-live/harness && tmux new-session -d -s xmpp-bridge "sbcl --script /home/al/saguaro-live/harness/bridge.lisp"
fi
