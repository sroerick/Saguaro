#!/usr/bin/env python3
"""OpenClaw-style heartbeat for an Autolith agent.

Cron (user al) runs this hourly. Flow:
  1. If the agent session is mid-turn (likely the owner is talking to it), skip.
  2. Otherwise send the HEARTBEAT prompt via `localgroup tell`.
  3. Wait (bounded) for the turn to finish.
  4. Extract the agent's reply with the same parser as bridge.py.
  5. If the reply is non-trivial (not the "nothing to report" sentinel),
     push it to the owner over XMPP via a one-shot slixmpp client.

So the agent can act proactively, but the owner only hears from it when
there is something worth hearing. Log: heartbeat.log
"""
import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge  # config (A, B) + parsers (status_records, all_records, reply_text)

import slixmpp

A, B = bridge.A, bridge.B

HEARTBEAT_PROMPT = (
    "HEARTBEAT (automated hourly check-in; this is not {owner} typing). "
    "Check your agenda, memory and papercuts for anything that needs doing "
    "or is worth reporting to {owner}. If there is nothing worth saying, "
    "reply with exactly: OK  (no other text, no markdown). Otherwise act "
    "within your permissions, and reply with a short report addressed to "
    "{owner}."
).format(owner=B.get("owner_name", "the owner"))
SKIP_SENTINELS = {"ok", "ok.", "ok!", "ok..", "..."}


def agent_idle(session):
    cur = next((r for r in bridge.status_records()
                if r["session"] == session), None)
    return bool(cur and cur["idle"] and not cur["active"])


class Push(slixmpp.ClientXMPP):
    """One-shot client: connect, send, disconnect."""

    def __init__(self, to, body):
        pw = Path(B["password_file"]).read_text().strip()
        super().__init__(B["jid"], pw)
        self.to, self.body = to, body
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("failed_auth", lambda e: self.loop.stop())
        self.add_event_handler("connection_failed", lambda e: self.loop.stop())

    async def on_start(self, e):
        self.send_presence()
        for chunk in bridge.chunk_text("[heartbeat] " + self.body):
            self.send_message(mto=self.to, mbody=chunk, mtype="chat")
            await asyncio.sleep(0.4)
        await asyncio.sleep(1.0)  # let the stanza flush
        self.disconnect()
        self.loop.stop()


def push(to, body, timeout=60):
    # slixmpp schedules connect() on its own event loop; run THAT loop
    # (same pattern as bridge.py), not a fresh one.
    p = Push(to, body)
    p.connect()
    p.loop.call_later(timeout, p.loop.stop)
    p.loop.run_forever()
    p.loop.close()


def main():
    rec = bridge.pick_session()
    if not rec or not rec.get("conversation"):
        print("heartbeat: no autolith session available", flush=True)
        return
    if rec.get("active") or not rec.get("idle"):
        print("heartbeat: session busy, skipping cycle", flush=True)
        return

    # agent-wake unread check: one line on the wake prompt when the PP
    # inbox (log/inbox) holds unread rows from the owner.
    prompt = HEARTBEAT_PROMPT
    if bridge.PP_ON:
        try:
            n = int(str(bridge.pp_eval('(inbox/unread %s)'
                                       % bridge.pp_lisp_str("gregor")) or 0))
            if n > 0:
                prompt += ("\n[inbox: %d unread from %s in the PP inbox "
                           "(log/inbox); read them with (inbox/rows) via "
                           "the PP API, handle what needs handling, then "
                           "(inbox/mark-read gregor).]"
                           % (n, B.get("owner_name", "the owner")))
        except Exception:
            pass

    session, conv = rec["session"], rec["conversation"]
    watermark = max((r["seq"] for r in bridge.all_records(conv)), default=0)
    print("heartbeat: telling session %s" % session, flush=True)
    bridge.run([A["bin"], "localgroup", "tell", session, prompt])

    deadline = time.monotonic() + float(A.get("turn_timeout_secs", 900))
    while time.monotonic() < deadline:
        time.sleep(float(A.get("poll_secs", 1.5)))
        if agent_idle(session):
            break

    new = [r for r in bridge.all_records(conv) if r["seq"] > watermark]
    text = bridge.reply_text(new).strip()
    if not text or text.lower().rstrip(".! ") in SKIP_SENTINELS:
        print("heartbeat: nothing to report", flush=True)
        return

    to = B.get("allow", ["owner@chat.example.net"])[0]
    text = text[: int(A.get("max_reply_chars", 8000))]
    print("heartbeat: pushing %d chars to %s" % (len(text), to), flush=True)
    push(to, text)
    # Absorb the announce into the PP inbox (kind announce) + ntfy ping,
    # so the durable feed matches what the phone/XMPP push just carried.
    if bridge.PP_ON:
        try:
            bridge.pp_eval('(inbox/announce %s)' % bridge.pp_lisp_str(text))
        except Exception as e:
            print("heartbeat: inbox announce failed: %s" % e, flush=True)


if __name__ == "__main__":
    main()
