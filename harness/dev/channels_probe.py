"""Probe an Autolith build that has the channel interface (lho/channels).

Every check runs inside --root, which holds its own XDG directories, and
the build is named with --autolith. Nothing touches the real autolith
data or config.

    channels_probe.py cli --autolith PATH --root DIR
        version, world server start, status --sexp, a new detached channel,
        a tell as the person, the channel history on disk.

    channels_probe.py acp-pair --autolith PATH --root DIR [--channel ID]
        two ACP clients on one channel; the second does not prompt and the
        probe prints everything it receives. This is the check that decides
        whether one long-lived client can carry replies and proactive
        messages: it has to show the other client's user_message_chunk, the
        agent_message_chunk and the turn events.
"""

import argparse
import json
import os
import pathlib
import queue
import re
import subprocess
import sys
import threading
import time


XDG_VARIABLES = (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                 ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"))


def environment(root, autolith):
    root = pathlib.Path(root).resolve()
    env = dict(os.environ)
    for variable, child in XDG_VARIABLES:
        path = root / child
        path.mkdir(parents=True, exist_ok=True)
        env[variable] = str(path)
    return env


def run(argv, env, timeout=600):
    started = time.time()
    done = subprocess.run(argv, env=env, timeout=timeout, capture_output=True, text=True)
    return ("$ " + " ".join(argv), done.returncode, round(time.time() - started, 1),
            done.stdout, done.stderr)


def show(args, env, timeout=600):
    where, code, seconds, out, err = run(args, env, timeout)
    print(f"{where}\n  exit {code} in {seconds}s")
    for stream, text in (("out", out), ("err", err)):
        if text.strip():
            print(f"  {stream}: " + text.rstrip().replace("\n", "\n       "))
    return out


def channels(args, env):
    """Yield (canonical id, display id, status text) from `lg status --sexp`."""
    text = run([args.autolith, "lg", "status", "--sexp"], env, 120)[3]
    for record in re.split(r"\n(?= \()", text):
        canonical = re.search(r':CONVERSATION-ID "([^"]+)"', record)
        display = re.search(r':CONVERSATION-DISPLAY-ID #A\(\d+\) BASE-CHAR \. "([^"]+)"', record)
        if canonical:
            yield canonical.group(1), (display.group(1) if display else canonical.group(1)), record


def history(root):
    base = pathlib.Path(root).resolve() / "data" / "autolith" / "conversations"
    for directory in sorted(base.iterdir()) if base.exists() else []:
        chunks = sorted(directory.glob("*.sexp"))
        print(f"  channel {directory.name}: {len(chunks)} chunk(s)")
        for chunk in chunks[-1:]:
            lines = chunk.read_text(errors="replace").splitlines()
            print(f"    last record in {chunk.name}:")
            for line in lines[-12:]:
                print("      " + line[:300])


def mode_cli(args, env):
    show([args.autolith, "--version"], env)
    show([args.autolith, "lg", "status", "--sexp"], env, 60)
    show([args.autolith, "lg", "start"], env)
    show([args.autolith, "lg", "status", "--sexp"], env, 60)
    show([args.autolith, "--detached"], env)
    found = list(channels(args, env))
    for canonical, display, record in found:
        print(f"  channel {display} (canonical {canonical})")
        print("    " + record.strip().replace("\n", "\n    "))
    if not found:
        print("  no channel was opened")
        return 1
    canonical = args.channel or found[-1][0]
    show([args.autolith, "lg", "tell", canonical,
          "probe: reply with the single word PROBE-OK and nothing else."], env, 180)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        text = run([args.autolith, "lg", "status", "--sexp"], env, 60)[3]
        state = re.search(r":STATE (\S+)", text)
        active = re.search(r":ACTIVE-TURN-P (\S+)", text)
        waiting = re.search(r":WAITING-FOR-INPUT-P (\S+)", text)
        count = re.search(r":MESSAGE-COUNT (\d+)", text)
        print("  state %s active %s waiting %s messages %s" % tuple(
            group.group(1) if group else "?" for group in (state, active, waiting, count)))
        if waiting and waiting.group(1) == "T" and count and count.group(1) != "0":
            break
        time.sleep(5)
    history(args.root)
    return 0


class Client:
    """One ACP client over the agent's standard input and output."""

    def __init__(self, autolith, env, name):
        self.name = name
        self.process = subprocess.Popen([autolith, "acp"], env=env, text=True, bufsize=1,
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE)
        self.inbox = queue.Queue()
        self.identifier = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            line = line.strip()
            if line:
                try:
                    self.inbox.put(json.loads(line))
                except json.JSONDecodeError:
                    self.inbox.put({"raw": line})

    def request(self, method, params, timeout=240):
        self.identifier += 1
        identifier = self.identifier
        self.process.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.inbox.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if message.get("id") == identifier:
                return message
            print(f"  [{self.name}] <- " + json.dumps(message)[:600])
        return {"timeout": method}

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=15)
        except Exception:
            self.process.kill()


def mode_acp_pair(args, env):
    found = list(channels(args, env))
    canonical = args.channel or (found[-1][0] if found else None)
    if not canonical:
        print("no channel to attach; run the cli mode first")
        return 1
    print(f"== two ACP clients on {canonical}")
    params = {"protocolVersion": 1, "clientCapabilities": {},
              "clientInfo": {"name": "saguaro-probe", "version": "0"}}
    listener = Client(args.autolith, env, "B")
    print("  B initialize: " + json.dumps(listener.request("initialize", params, 120))[:300])
    print("  B session/load: " + json.dumps(listener.request(
        "session/load", {"sessionId": canonical, "cwd": str(pathlib.Path(args.root).resolve() / "work"),
                         "mcpServers": []}, 300))[:400])
    talker = Client(args.autolith, env, "A")
    print("  A initialize: " + json.dumps(talker.request("initialize", params, 120))[:300])
    print("  A session/load: " + json.dumps(talker.request(
        "session/load", {"sessionId": canonical, "cwd": str(pathlib.Path(args.root).resolve() / "work"),
                         "mcpServers": []}, 300))[:400])

    def prompt():
        time.sleep(2)
        answer = talker.request("session/prompt", {"sessionId": canonical, "prompt": [
            {"type": "text", "text": "Reply with the single word SECOND-OK and nothing else."}]}, 600)
        print("  A prompt: " + json.dumps(answer)[:800])

    threading.Thread(target=prompt, daemon=True).start()
    print("== what the client that did not prompt receives")
    deadline = time.time() + args.wait
    while time.time() < deadline:
        try:
            print("  [B] <- " + json.dumps(listener.inbox.get(timeout=1))[:900])
        except queue.Empty:
            pass
    listener.close()
    talker.close()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["cli", "acp-pair"])
    parser.add_argument("--autolith", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--channel")
    parser.add_argument("--wait", type=int, default=90)
    args = parser.parse_args()
    env = environment(args.root, args.autolith)
    return mode_cli(args, env) if args.mode == "cli" else mode_acp_pair(args, env)


if __name__ == "__main__":
    sys.exit(main())
