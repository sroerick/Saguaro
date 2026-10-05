#!/usr/bin/env python3
"""One-shot DM from the agent account to the owner (config allow[0]).

Usage: send-dm.py TEXT_FILE      (or text on stdin)
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, "/home/al/saguaro-live/harness")
import bridge  # noqa: E402
import slixmpp  # noqa: E402

B = bridge.B
TO = B["allow"][0]
if len(sys.argv) > 1:
    text = Path(sys.argv[1]).read_text().strip()
else:
    text = sys.stdin.read().strip()
if not text:
    sys.exit("send-dm: empty text")


class Send(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(B["jid"], Path(B["password_file"]).read_text().strip())
        self.add_event_handler("session_start", self.on_start)

    async def on_start(self, e):
        self.send_presence()
        chunks = bridge.chunk_text(text)
        for c in chunks:
            self.send_message(mto=TO, mbody=c, mtype="chat")
            await asyncio.sleep(0.5)
        await asyncio.sleep(1.5)
        print("send-dm: sent %d chunk(s) to %s" % (len(chunks), TO))
        self.disconnect()


s = Send()
s.connect()
s.loop.call_later(45, s.loop.stop)
s.loop.run_forever()
