#!/usr/bin/env python3
"""Print the assistant text of conversation CONV (last 8000 chars)."""
import sys

sys.path.insert(0, "/home/al/saguaro-live/harness")
import bridge  # noqa: E402

conv = sys.argv[1]
recs = bridge.all_records(conv)
txt = bridge.reply_text(recs).strip()
print("=== conv %s: %d records, assistant text %d chars ===" % (conv, len(recs), len(txt)))
print(txt[-8000:])
