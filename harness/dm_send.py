#!/usr/bin/env python3
"""One-shot: send a direct (chat) message to one JID, as the configured jid.

Usage: dm_send.py TO_JID TEXT [TEXT...]
  e.g. dm_send.py hollis@chat.wyo.town "ping"

Reads BRIDGE_CONFIG (default: harness config.toml beside this script) for
[bridge] jid + password_file. No allowlist here - that gate is inbound only.
Resource is randomized so the one-shot client coexists with the live bridge.
Slixmpp one-shot under asyncio.run, clean disconnect.
"""
import asyncio
import os
import sys
import tomllib
import uuid
from pathlib import Path

import slixmpp

CFG = tomllib.loads(Path(
    os.environ.get("BRIDGE_CONFIG",
                   str(Path(__file__).resolve().parent / "config.toml"))).read_text())
B = CFG["bridge"]
TO = sys.argv[1] if len(sys.argv) > 1 else ""
TEXT = "\n".join(sys.argv[2:]).strip()
sent = False


class Sender(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(B["jid"], Path(B["password_file"]).read_text().strip())
        self.done = asyncio.Event()
        self.add_event_handler("session_start", self.on_start)

    async def on_start(self, ev):
        global sent
        if not TO or not TEXT:
            print("usage: dm_send.py TO_JID TEXT...")
            self.done.set()
            return
        try:
            self.send_message(mto=TO, mbody=TEXT, mtype="chat")
            print("dm sent to %s" % TO)
            sent = True
        except Exception as e:
            print("failed: %s: %s" % (type(e).__name__, e))
        finally:
            self.done.set()


async def main():
    sender = Sender()
    sender.connect()
    try:
        await asyncio.wait_for(sender.done.wait(), timeout=45)
        await asyncio.sleep(0.5)          # give the stanza a moment to flush
    except asyncio.TimeoutError:
        print("timed out waiting for session")
    finally:
        try:
            d = sender.disconnect()
            if asyncio.iscoroutine(d):
                await asyncio.wait_for(d, timeout=5)
        except Exception:
            pass
        await asyncio.sleep(0.3)          # let the socket close quietly
    return sent


sys.exit(0 if asyncio.run(main()) else 1)