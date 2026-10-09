#!/usr/bin/env python3
"""Offline handoff extractor for an over-limit Autolith conversation.

Reads the .sexp conversation directly (no provider call: the provider call is
exactly what returns HTTP 400 on this conversation). Reuses the parsers in
bridge.py, which heartbeat.py already uses successfully.

Usage: python3 gregor_handoff.py <CONV_ID> <OUT_PATH> [MAX_CHARS]
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bridge  # noqa: E402

CONV = sys.argv[1] if len(sys.argv) > 1 else "K3CL8Cm"
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else f"HANDOFF-{CONV}.md")
MAX_CHARS = int(sys.argv[3]) if len(sys.argv) > 3 else 60000


def item_text(item, role):
    out = []
    for c in item.get("content") or []:
        if not isinstance(c, dict):
            continue
        if c.get("type") in ("output_text", "input_text", "text"):
            if c.get("text"):
                out.append(c["text"])
    return "\n".join(out).strip()


recs = bridge.all_records(CONV)
assistant, user, aborts = [], [], []
for r in recs:
    t = r["type"]
    if t == "PROVIDER-ITEM":
        for s in r["strings"]:
            if not s.startswith("{"):
                continue
            try:
                item = json.loads(s)
            except ValueError:
                continue
            if item.get("type") != "message":
                continue
            role = item.get("role")
            txt = item_text(item, role)
            if not txt:
                continue
            if role == "assistant":
                assistant.append((r["seq"], txt))
            elif role == "user":
                user.append((r["seq"], txt))
    elif t == "MESSAGE":
        for s in r["strings"]:
            s = s.strip()
            if s:
                user.append((r["seq"], s))
    elif t == "TURN-ABORTED":
        aborts.append((r["seq"], "; ".join(r["strings"])[:200]))

# --- assemble newest-last, truncating oldest-first --------------------------
def tail_join(items, budget):
    """Take items from the newest end until the char budget is spent."""
    kept, used = [], 0
    for seq, txt in reversed(items):
        if used + len(txt) > budget:
            break
        kept.append((seq, txt))
        used += len(txt)
    return list(reversed(kept)), used


a_kept, a_used = tail_join(assistant, int(MAX_CHARS * 0.75))
u_kept, u_used = tail_join(user, int(MAX_CHARS * 0.25))

parts = []
parts.append("# HANDOFF from Autolith conversation %s (hwre/hwre box, gregor)\n" % CONV)
parts.append("Extracted offline %s by the operator harness (agora).\n" % __import__("time").strftime("%Y-%m-%d %H:%M UTC", __import__("time").gmtime()))
parts.append("Why this file exists: conversation %s grew past the model's real\n"
             "context ceiling (524,288 tokens; the last provider payload was 526,664),\n"
             "so EVERY turn returned HTTP 400 and no work could continue. Autolith's own\n"
             "token meter read ~220K/272K because the provider's reported count undercounts\n"
             "the true count ~2.4x, so the compaction guard never fired in time.\n" % CONV)
parts.append("Total records parsed: %d (assistant texts: %d, owner texts: %d)\n"
             % (len(recs), len(assistant), len(user)))
parts.append("\n---\n\n## Last %d assistant messages (oldest first; seq = record number)\n" % len(a_kept))
for seq, txt in a_kept:
    parts.append("\n### [seq %d]\n%s\n" % (seq, txt))
parts.append("\n---\n\n## Last %d owner/user messages (oldest first)\n" % len(u_kept))
for seq, txt in u_kept:
    parts.append("\n### [seq %d]\n%s\n" % (seq, txt))
if aborts:
    parts.append("\n---\n\n## Final turn-abort records (last %d)\n" % min(10, len(aborts)))
    for seq, txt in aborts[-10:]:
        parts.append("- [seq %d] %s\n" % (seq, txt))

OUT.write_text("".join(parts), encoding="utf-8")
print("wrote %s  (%d bytes; assistant %d chars, owner %d chars)"
      % (OUT, OUT.stat().st_size, a_used, u_used))
