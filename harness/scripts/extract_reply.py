#!/usr/bin/env python3
"""Print the assistant text of conversation CONV (last 8000 chars)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import bridge  # noqa: E402

conv = sys.argv[1]
recs = bridge.all_records(conv)
txt = bridge.reply_text(recs).strip()
print("=== conv %s: %d records, assistant text %d chars ===" % (conv, len(recs), len(txt)))
print(txt[-8000:])
