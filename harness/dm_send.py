#!/usr/bin/env python3
"""One-shot: send a single DM from the agent's XMPP account.

Usage: dm_send.py TO_JID BODY
       dm_send.py TO_JID -   (body on stdin)

Exits 0 if the stanza was handed to the stream; does NOT confirm delivery.
Same connection pattern as muc_history.py (random resource, safe while the
live bridge holds its own session).
"""
import asyncio
import os
import sys
import tomllib
from pathlib import Path

import slixmpp

CFG = tomllib.loads(Path(
    os.environ.get("BRIDGE_CONFIG",
                   str(Path(__file__).resolve().parent / "config.toml"))).read_text())
B = CFG["bridge"]
TO = sys.argv[1] if len(sys.argv) > 1 else ""
BODY = sys.argv[2] if len(sys.argv) > 2 else ""
if BODY == "-":
    BODY = sys.stdin.read()
ok = False


class Sender(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(B["jid"], Path(B["password_file"]).read_text().strip())
        self.done = asyncio.Event()
        self.add_event_handler("session_start", self.on_start)

    async def on_start(self, ev):
        global ok
        try:
            if "@" not in TO or not BODY.strip():
                print("usage: dm_send.py TO_JID BODY   (or '-' to read body on stdin)")
                return
            self.send_message(mto=TO, mbody=BODY, mtype="chat")
            await asyncio.sleep(1.5)          # let the stanza flush
            print("sent DM to %s (%d chars)" % (TO, len(BODY)))
            ok = True
        except Exception as e:
            print("failed: %s: %s" % (type(e).__name__, e))
        finally:
            self.done.set()


async def main():
    sender = Sender()
    sender.connect()
    try:
        await asyncio.wait_for(sender.done.wait(), timeout=30)
        await asyncio.sleep(0.5)
    except asyncio.TimeoutError:
        print("timed out waiting for session")
    finally:
        try:
            d = sender.disconnect()
            if asyncio.iscoroutine(d):
                await asyncio.wait_for(d, timeout=5)
        except Exception:
            pass
        await asyncio.sleep(0.3)              # let the socket close quietly
    return ok


sys.exit(0 if asyncio.run(main()) else 1)
