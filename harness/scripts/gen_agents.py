#!/usr/bin/env python3
"""Generate the agent persona file (AGENTS.md) from persona.tmpl.md.

Fills {{OWNER}}, {{AGENT}}, {{HOST}} from config.toml (owner_name, muc_nick,
the jid's host). Refuses to overwrite: after first generation the file belongs
to the user; edit it in place and the generator leaves it alone.

Usage: gen_agents.py [output-path]
       output defaults to $AGENTS_MD, else ~/AGENTS.md
"""
import os
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CFG = Path(os.environ.get("BRIDGE_CONFIG", str(ROOT / "config.toml")))
OUT = Path(sys.argv[1] if len(sys.argv) > 1
           else os.environ.get("AGENTS_MD", str(Path.home() / "AGENTS.md")))


def main():
    if OUT.exists():
        print("gen_agents: %s exists; leaving it alone" % OUT)
        return 0
    if not CFG.exists():
        print("gen_agents: no config at %s (copy config.example.toml first)"
              % CFG)
        return 1
    b = tomllib.loads(CFG.read_text())["bridge"]
    text = (ROOT / "persona.tmpl.md").read_text()
    text = (text.replace("{{OWNER}}", b.get("owner_name", "the owner"))
                .replace("{{AGENT}}", b.get("muc_nick", "agent"))
                .replace("{{HOST}}", b["jid"].split("@")[-1]))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print("gen_agents: wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
