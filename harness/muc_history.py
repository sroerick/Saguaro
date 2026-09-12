#!/usr/bin/env python3
"""One-shot: print recent history of a configured MUC room — the REAL room
view, straight from the XMPP server (not any mirror/branch/worker copy).

Usage: muc_history.py ROOM_JID [MAX_STANZAS]
  e.g. muc_history.py ops-test@conference.chat.example.net 50

ROOM_JID must be listed under [bridge] mucs in config.toml. Prints
"[HH:MM] nick: body" in arrival order. Slixmpp 1.17: one-shot under asyncio.run, clean disconnect.
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
MAXST = int(sys.argv[2]) if len(sys.argv) > 2 else 30
ok = False


class Reader(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(B["jid"], Path(B["password_file"]).read_text().strip())
        self.register_plugin("xep_0045")
        self.done = asyncio.Event()
        self.add_event_handler("session_start", self.on_start)

    async def on_start(self, ev):
        global ok
        try:
            if ROOM not in MUCS:
                print("room %s not in config.toml mucs: %s"
                      % (ROOM, ", ".join(MUCS)))
                return
            res = await self.plugin["xep_0045"].join_muc_wait(
                ROOM, NICK, maxstanzas=MAXST, timeout=15)
            hist = list(res[3]) if isinstance(res, tuple) and len(res) > 3 else []
            shown = 0
            for m in hist:
                body = (m["body"] or "").strip()
                if not body:
                    continue
                ts = "--:--"
                if m["delay"]["stamp"]:
                    ts = m["delay"]["stamp"].strftime("%H:%M")
                print("[%s] %s: %s" % (ts, m["from"].resource, body))
                shown += 1
            print("== %s: %d history message(s) (maxstanzas=%d)"
                  % (ROOM, shown, MAXST))
            ok = True
        except Exception as e:
            print("failed: %s: %s" % (type(e).__name__, e))
        finally:
            self.done.set()


async def main():
    reader = Reader()
    reader.connect()
    try:
        await asyncio.wait_for(reader.done.wait(), timeout=45)
        await asyncio.sleep(0.5)
    except asyncio.TimeoutError:
        print("timed out waiting for session")
    finally:
        try:
            d = reader.disconnect()
            if asyncio.iscoroutine(d):
                await asyncio.wait_for(d, timeout=5)
        except Exception:
            pass
        await asyncio.sleep(0.3)          # let the socket close quietly
    return ok


sys.exit(0 if asyncio.run(main()) else 1)
