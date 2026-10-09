#!/bin/sh
# reap-openssl: safety net for the orphaned-XMPP-transport CPU leak.
#
# SBCL has no TLS, so bridge.lisp (and the one-shot say.lisp sender used by
# canary/heartbeat) spawn `/usr/bin/openssl s_client -quiet -starttls xmpp`
# as a byte-pipe CHILD. When that sbcl parent exits -- a bridge reconnect, or
# a one-shot sender finishing -- the openssl child is reparented to PID 1 and
# then busy-spins at 30-90% CPU forever. Enough of them melt the 2-vCPU box
# (2026-10-09: 22 orphans -> load 20).
#
# A live transport always has its sbcl parent (ppid = an sbcl pid), so any
# matching transport with ppid 1 is by definition already orphaned and safe to
# reap. Run every 5 min from cron.
ps -axo pid,ppid,command \
  | awk '$2 == 1 && /openssl s_client -quiet -starttls xmpp/ { print $1 }' \
  | while read -r p; do
      [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
    done
exit 0
