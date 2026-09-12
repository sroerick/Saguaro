#!/usr/bin/env python3
"""xmpp-bridge: OpenClaw-style XMPP gateway for a detached Autolith session.

Flow per 1:1 chat message from an allowed JID:
  autolith localgroup tell <sid> <text>
  -> poll localgroup status until the turn is no longer active
  -> parse the durable conversation log (~/.local/share/autolith/conversations/<id>/*.sexp)
  -> send the agent's new text back over XMPP (chunked)
"""
import asyncio, json, os, re, subprocess, tomllib
from pathlib import Path
import slixmpp

CFG_PATH = Path(os.environ.get("BRIDGE_CONFIG", str(Path(__file__).resolve().parent / "config.toml")))
cfg = tomllib.loads(CFG_PATH.read_text())
A = cfg["autolith"]; B = cfg["bridge"]


def run(cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout).stdout


# ---------------------------------------------------------------- status ----

RECORD_RE = re.compile(r"\(:LOCALGROUP-STATUS\b.*?:CREATED-AT\s+\d+\)", re.S)


def status_records():
    out = run([A["bin"], "localgroup", "status", "--sexp"])
    recs = []
    for m in RECORD_RE.finditer(out):
        block = m.group(0)

        def f(key):
            mm = re.search(key + r"\s+([^ \n)]+)", block)
            return mm.group(1).strip('"') if mm else None

        recs.append({
            "session": f(":SESSION-ID"),
            "conversation": f(":CONVERSATION-ID"),
            "pid": f(":PID"),
            "idle": f(":IDLE-P") == "T",
            "active": f(":ACTIVE-TURN-P") == "T",
        })
    return recs


# ---------------------------------------------------- conversation log ------

def conv_files(conv):
    d = Path(A.get("conversations_dir",
                   str(Path.home() / ".local/share/autolith/conversations")))
    return sorted((d / conv).glob("*.sexp"))


STRING_RE = re.compile(
    r'#A\(\(\d+\) BASE-CHAR \. "((?:[^"\\]|\\.)*)"\)'  # #A((n) BASE-CHAR . "...")
    r'|(?:^|\s):[A-Z-]+\s+"((?:[^"\\]|\\.)*)"')        # :KEY "plain string"

UNESCAPES = [("\\\\", "\\"), ('\\"', '"')]  # Lisp-level only: keep JSON \n escapes intact for json.loads


def unescape(s):
    for a, b in UNESCAPES:
        s = s.replace(a, b)
    return s


def parse_records(text):
    """Yield {seq, type, strings[]} for each top-level (:TYPE ...) record."""
    records = []
    for chunk in re.split(r"(?m)^\(:", text)[1:]:
        m = re.match(r"([A-Z-]+)", chunk)
        seqm = re.search(r":SEQ\s+(\d+)", chunk)
        if not m or not seqm:
            continue
        strings = [unescape(a or b) for a, b in STRING_RE.findall(chunk)]
        records.append({"seq": int(seqm.group(1)), "type": m.group(1),
                        "strings": strings})
    return records


def all_records(conv):
    recs = []
    seen = set()
    for path in conv_files(conv):
        for r in parse_records(path.read_text(errors="replace")):
            if r["seq"] not in seen:
                seen.add(r["seq"])
                recs.append(r)
    return sorted(recs, key=lambda r: r["seq"])


def reply_texts(new_records):
    """Assistant text messages from PROVIDER-ITEM records, in order.

    PROVIDER-ITEM records flush at each provider call end, so during a
    multi-tool turn this list grows as the agent narrates between calls.
    """
    texts = []
    for r in new_records:
        if r["type"] == "PROVIDER-ITEM":
            for s in r["strings"]:
                if not s.startswith("{"):
                    continue
                try:
                    item = json.loads(s)
                except ValueError:
                    continue
                if (item.get("type") == "message"
                        and item.get("role") == "assistant"):
                    for c in item.get("content") or []:
                        if c.get("type") == "output_text" and c.get("text"):
                            texts.append(c["text"])
    return texts


def reply_text(new_records):
    """End-of-turn text: all assistant texts joined, with the RESULT echo of
    a local lisp/slash USER-OPERATION as fallback."""
    texts = reply_texts(new_records)
    if not texts:
        uo = [r for r in new_records if r["type"] == "USER-OPERATION"]
        if uo and len(uo[-1]["strings"]) > 1:
            texts.append(uo[-1]["strings"][-1])
    return "\n\n".join(t for t in texts if t.strip())


def chunk_text(t, size=1400):
    chunks, buf = [], ""
    for para in t.split("\n\n"):
        while len(para) > size:
            chunks.append(para[:size])
            para = para[size:]
        if buf and len(buf) + len(para) + 2 > size:
            chunks.append(buf)
            buf = para
        else:
            buf = (buf + "\n\n" + para) if buf else para
    if buf:
        chunks.append(buf)
    return chunks


# ---------------------------------------------------------------- bridge ----

def pick_session():
    recs = status_records()
    want = A.get("session_id", "auto")
    if want != "auto":
        return next((r for r in recs if r["session"] == want), None)
    idle = [r for r in recs if r["idle"] and not r["active"]]
    return idle[0] if idle else (recs[0] if recs else None)


def allowed(msg):
    bare = msg["from"].bare
    allow = set(B.get("allow", []))
    dom = B.get("allow_domain") or ""
    return bare in allow or (dom and bare.endswith("@" + dom))


PANE = B.get("pane", "alagent")
PICKER_MARKER = "do not run the command"  # footer of the permission picker
BLOCKER_MARKER = "enter selects, esc cancels"  # footer of any blocking picker:
# permission picker, and the Lisp debugger after a bad eval/reader error


async def picker_watcher():
    """The agent TUI is unattended; a blocking picker freezes its turn
    forever. Permission pickers answer with the highlighted default
    ("auto": the model chooses full access or refusal); a Lisp debugger
    (e.g. after an unparseable tell) answers with the highlighted restart
    (abort-user-operation). Both footers match BLOCKER_MARKER. Every 45s."""
    while True:
        await asyncio.sleep(45)
        try:
            cap = run(["/usr/bin/tmux", "capture-pane", "-t", PANE, "-p"],
                      timeout=15)
            if BLOCKER_MARKER in cap or PICKER_MARKER in cap:
                run(["/usr/bin/tmux", "send-keys", "-t", PANE, "Enter"],
                    timeout=15)
                print("bridge: auto-answered blocking picker/debugger",
                      flush=True)
        except Exception as e:
            print("bridge: picker watcher error: %s" % e, flush=True)


async def recover_agent():
    """Kill the current agent session and relaunch via start-sessions.sh."""
    print("bridge: recovering agent (kill + resume)", flush=True)
    rec = pick_session()
    if rec and rec.get("session"):
        run([A["bin"], "localgroup", "kill", rec["session"]])
    await asyncio.sleep(2)
    run(["/bin/sh", B.get("start_script", str(Path(__file__).resolve().parent / "start-sessions.sh"))], timeout=120)
    for _ in range(20):
        await asyncio.sleep(3)
        recs = status_records()
        if recs:
            print("bridge: agent back as session %s" % recs[0]["session"],
                  flush=True)
            return recs[0]
    print("bridge: agent did not come back", flush=True)
    return None


class Bridge(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(B["jid"], Path(B["password_file"]).read_text().strip())
        self.register_plugin("xep_0085")
        self.register_plugin("xep_0045")
        self.register_plugin("xep_0203")
        self.mucs = [m for m in B.get("mucs", []) if m]
        self.muc_nick = B.get("muc_nick", "agent")
        self.muc_trigger = (B.get("muc_trigger") or self.muc_nick).lower()
        # explicit @mention only ("@gregor ...") — a bare nickname anywhere
        # in a room message must NOT trigger a response
        self.mention_re = re.compile(r"@" + re.escape(self.muc_trigger) + r"\b",
                                     re.I)
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("message", self.on_message)
        self.add_event_handler("groupchat_message", self.on_groupchat)
        self.lock = asyncio.Lock()

    async def on_start(self, e):
        self.send_presence()
        await self.get_roster()
        asyncio.ensure_future(picker_watcher())
        print("bridge online as", B["jid"], flush=True)
        for room in self.mucs:
            try:
                await self.plugin["xep_0045"].join_muc_wait(
                    room, self.muc_nick, timeout=15)
                print("bridge: joined MUC %s (address me as '@%s ...')"
                      % (room, self.muc_trigger), flush=True)
            except Exception as e:
                print("bridge: MUC join failed %s: %s: %s"
                      % (room, type(e).__name__, e), flush=True)

    def chat_state(self, to, state):
        m = self.make_message(mto=to, mtype="chat")
        m["chat_state"] = state
        m.send()

    def on_groupchat(self, msg):
        room = msg["from"].bare
        if room not in self.mucs:
            return
        nick = msg["from"].resource
        if not nick or nick == self.muc_nick:
            return
        if msg["delay"]["stamp"]:          # history replay on join
            return
        body = (msg["body"] or "").strip()
        if not body or not self.mention_re.search(body):
            return
        prompt = (self.mention_re.sub("", body).strip().lstrip(",;:")
                  .strip() or body)
        asyncio.ensure_future(self.muc_handle(room, prompt))

    async def muc_handle(self, room, prompt):
        async with self.lock:
            try:
                if prompt.lower() == "reset":
                    await self.reset_agent(room, mtype="groupchat")
                else:
                    await self.handle(room, prompt, mtype="groupchat")
            except Exception as e:
                self.send_message(mto=room,
                                  mbody=f"bridge error: {type(e).__name__}: {e}",
                                  mtype="groupchat")

    async def on_message(self, msg):
        if msg["type"] not in ("chat", "normal"):
            return
        body = (msg["body"] or "").strip()
        if not body or not allowed(msg):
            return
        reply_to = msg["from"]
        self.chat_state(reply_to, "composing")
        if body.lower() == "reset":
            async with self.lock:
                await self.reset_agent(reply_to)
            return
        async with self.lock:
            try:
                await self.handle(reply_to, body)
            except Exception as e:
                self.send_message(mto=reply_to,
                                  mbody=f"bridge error: {type(e).__name__}: {e}",
                                  mtype="chat")

    async def reset_agent(self, jid, mtype="chat"):
        self.send_message(mto=jid, mbody="restarting the agent "
                          "(kill + resume, ~60s)...", mtype=mtype)
        rec = await recover_agent()
        if rec:
            self.send_message(mto=jid, mbody="agent back online (session %s)"
                              % rec["session"], mtype=mtype)
        else:
            self.send_message(mto=jid,
                              mbody="restart failed to come back — needs eyes on the box",
                              mtype=mtype)

    async def handle(self, jid, body, mtype="chat"):
        if mtype == "groupchat":
            # the room never sees narration; tell the agent so it works
            # silently and produces one consolidated reply. MUST start with a
            # plain word: localgroup tell treats leading-paren input as a
            # local Lisp form, and an unparseable form hangs the turn in the
            # Lisp debugger.
            body = ("GROUP CHAT MESSAGE - do not narrate as you work. "
                    "Send one consolidated reply at the end.\n\n" + body)
        rec = pick_session()
        rec = pick_session()
        if not rec or not rec.get("conversation"):
            self.send_message(mto=jid, mbody="no autolith session available",
                              mtype=mtype)
            return
        conv = rec["conversation"]
        watermark = max((r["seq"] for r in all_records(conv)), default=0)
        run([A["bin"], "localgroup", "tell", rec["session"], body])
        poll = float(A.get("poll_secs", 1.5))
        limit = float(A.get("turn_timeout_secs", 900))
        maxchars = int(A.get("max_reply_chars", 8000))
        waited = 0.0
        pinged = False
        last_typing = 0.0
        delivered = 0
        stream = (mtype == "chat")  # MUC: hold everything, one reply at end

        def deliver(text):
            if mtype == "chat":
                self.chat_state(jid, "active")
            for c in chunk_text(text[:maxchars]):
                self.send_message(mto=jid, mbody=c, mtype=mtype)

        while waited < limit:
            await asyncio.sleep(poll)
            waited += poll
            if waited - last_typing >= 20:
                last_typing = waited
                self.chat_state(jid, "composing")
            # stream assistant narration/replies as records flush (DM only;
            # in MUC, narration between tool calls would dump the agent's
            # inner monologue into the room)
            if stream:
                new = [r for r in all_records(conv) if r["seq"] > watermark]
                texts = [x.strip() for x in reply_texts(new) if x.strip()]
                while delivered < len(texts):
                    deliver(texts[delivered])
                    delivered += 1
            cur = next((r for r in status_records()
                        if r["session"] == rec["session"]), None)
            if cur and cur["idle"] and not cur["active"]:
                break
            if not pinged and waited >= 300:
                pinged = True
                self.send_message(
                    mto=jid,
                    mbody="still working (%d min in; I keep waiting up to %d "
                          "min). If it seems stuck, send: reset"
                          % (int(waited // 60), int(limit // 60)),
                    mtype=mtype)
        # turn over: DM delivers any tail; MUC delivers the final message only
        new = [r for r in all_records(conv) if r["seq"] > watermark]
        texts = [x.strip() for x in reply_texts(new) if x.strip()]
        if stream:
            while delivered < len(texts):
                deliver(texts[delivered])
                delivered += 1
        if delivered == 0:
            cur = next((r for r in status_records()
                        if r["session"] == rec["session"]), None)
            if cur and (cur["active"] or not cur["idle"]):
                text = ("no reply after %d min and the turn is still running "
                        "(possibly hung). Send: reset — conversation history "
                        "is safe." % int(waited // 60))
            elif stream:
                text = reply_text(new) or "(no text output)"
            else:
                # MUC: last assistant message = the answer, not the narration
                text = texts[-1] if texts else "(no text output)"
            deliver(text)


if __name__ == "__main__":
    # slixmpp 1.17: no .process(); connect() schedules on the loop.
    bridge = Bridge()
    bridge.connect()
    bridge.loop.run_forever()
