#!/usr/bin/env python3
"""One-shot: post a message to a configured MUC room, as the configured muc_nick.

Usage: muc_send.py ROOM_JID TEXT [TEXT...]
  e.g. muc_send.py ops-test@conference.chat.example.net "hello room"

ROOM_JID must be listed under [bridge] mucs in config.toml (that list is
the authorization boundary). Slixmpp 1.17: one-shot under asyncio.run, clean disconnect.
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
MUCS = [m for m in B.get("mucs", []) if m]
NICK = B.get("muc_nick", "agent")
ROOM = sys.argv[1] if len(sys.argv) > 1 else ""
TEXT = "\n".join(sys.argv[2:]).strip()
sent = False


class Poster(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(B["jid"], Path(B["password_file"]).read_text().strip())
        self.register_plugin("xep_0045")
        self.done = asyncio.Event()
        self.add_event_handler("session_start", self.on_start)

    async def on_start(self, ev):
        global sent
        if not ROOM or not TEXT:
            print("usage: muc_send.py ROOM_JID TEXT...\n"
                  "configured rooms: %s" % ", ".join(MUCS))
            self.done.set()
            return
        if ROOM not in MUCS:
            print("room %s not in config.toml mucs: %s" % (ROOM, ", ".join(MUCS)))
            self.done.set()
            return
        try:
            await self.plugin["xep_0045"].join_muc_wait(ROOM, NICK, timeout=15)
            await asyncio.sleep(1)   # let the join presence settle
            self.send_message(mto=ROOM, mbody=TEXT, mtype="groupchat")
            print("sent to %s" % ROOM)
            sent = True
        except Exception as e:
            print("failed: %s: %s" % (type(e).__name__, e))
        finally:
            self.done.set()


async def main():
    poster = Poster()
    poster.connect()
    try:
        await asyncio.wait_for(poster.done.wait(), timeout=45)
        await asyncio.sleep(0.5)          # give the stanza a moment to flush
    except asyncio.TimeoutError:
        print("timed out waiting for session")
    finally:
        try:
            d = poster.disconnect()
            if asyncio.iscoroutine(d):
                await asyncio.wait_for(d, timeout=5)
        except Exception:
            pass
        await asyncio.sleep(0.3)          # let the socket close quietly
    return sent


sys.exit(0 if asyncio.run(main()) else 1)
