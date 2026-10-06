#!/usr/bin/env python3
"""Cost profile for an Autolith standing conversation.

Parses the durable conversation logs under
~/.local/share/autolith/conversations/<id>/*.sexp and sums the per-request
usage records (:PROVIDER ... :USAGE ...) the provider returned, attributed
to the user turn that was live when the request fired:

  heartbeat   turn opened by the "HEARTBEAT (automated ..." prompt
  roerick     turn opened by a bridge DM from the owner
  room        turn opened by an XMPP room message
  other       everything else (tells, resets, probes)

Usage:
  cost-profile.py [--days N] [--conv ID] [--all] [--since YYYY-MM-DD]

Default conversation comes from harness config.toml (conv = ...).
Cron (Mondays 15:20Z) appends the weekly profile to cost-profile.log.
Numbers are provider-reported tokens, not billed currency.
"""

import argparse
import re
import time
from pathlib import Path

HOME = Path.home()
CONVS = HOME / ".local/share/autolith/conversations"
CONFIG = HOME / "saguaro-live/harness/config.toml"
UT_OFFSET = 2208988800  # lisp universal-time (1900 epoch) -> unix epoch

HEARTBEAT_MARK = "HEARTBEAT (automated"
ROERICK_MARK = "DM from roerick"
MUC_MARK = "MUC "
WIRE_ROLE_USER = 'role\\":\\"user'  # escaped role inside the wire-json string

USAGE_RE = re.compile(
    r'\("(input_tokens|prompt_tokens|completion_tokens|output_tokens'
    r'|total_tokens|cached_tokens|reasoning_tokens)"\s+(-?\d+)\)')
TIME_RE = re.compile(r':TIME\s+(-?\d+)')
MODEL_RE = re.compile(r':MODEL\s+"([^"]+)"')


def split_forms(text):
    """Yield top-level sexp forms as raw strings (string/escape aware)."""
    depth = 0
    in_str = False
    esc = False
    start = None
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "(":
            if depth == 0:
                start = i
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and start is not None:
                yield text[start:i + 1]
                start = None


def classify(form):
    """Origin name if the form opens a user turn, else None.

    Only (:MESSAGE :ROLE :USER forms count as turn boundaries: the
    provider-item wire copies duplicate every tell, and tool-result
    outputs can quote user text, roles and markers verbatim.
    """
    if not form.startswith("(:MESSAGE"):
        return None
    if ":ROLE :USER" not in form[:200]:
        return None
    if HEARTBEAT_MARK in form:
        return "heartbeat"
    if MUC_MARK in form:
        return "room"
    return "roerick"


def form_day(form):
    m = TIME_RE.search(form)
    if not m:
        return None
    return time.strftime("%Y-%m-%d", time.gmtime(int(m.group(1)) - UT_OFFSET))


def profile_conv(conv, since_day=None):
    per = {}    # origin -> [requests, prompt, cached, completion, total]
    daily = {}  # day -> origin -> total tokens
    beats = {"total": 0, "in_window": 0}
    turns = {}
    first_day = None
    last_day = None
    model = "?"
    cur = "other"
    for path in sorted((CONVS / conv).glob("*.sexp")):
        text = path.read_text(errors="replace")
        for form in split_forms(text):
            if form.startswith("(:CONVERSATION"):
                m = MODEL_RE.search(form)
                if m:
                    model = m.group(1)
                continue
            origin = classify(form)
            if origin:
                cur = origin
                turns[origin] = turns.get(origin, 0) + 1
                beats["total"] += 1
                day = form_day(form)
                if day:
                    first_day = first_day or day
                    last_day = day
                    if since_day and day >= since_day:
                        beats["in_window"] += 1
                continue
            if not form.startswith("(:PROVIDER"):
                continue
            if ":USAGE" not in form:
                continue
            day = form_day(form)
            if day:
                first_day = first_day or day
                last_day = day
                if since_day and day < since_day:
                    continue
            u = {k: int(v) for k, v in USAGE_RE.findall(form)}
            prompt = u.get("input_tokens", u.get("prompt_tokens", 0))
            completion = u.get("output_tokens", u.get("completion_tokens", 0))
            total = u.get("total_tokens", prompt + completion)
            cached = u.get("cached_tokens", 0)
            slot = per.setdefault(cur, [0, 0, 0, 0, 0])
            slot[0] += 1
            slot[1] += prompt
            slot[2] += cached
            slot[3] += completion
            slot[4] += total
            if day:
                daily.setdefault(day, {}).setdefault(cur, 0)
                daily[day][cur] += total
    return {"conv": conv, "model": model, "per": per, "daily": daily,
            "beats": beats, "turns": turns,
            "first": first_day, "last": last_day}


def n(x):
    return "{:,}".format(x)


def print_report(r, days):
    per = r["per"]
    order = ["heartbeat", "roerick", "room", "other"]
    print("== cost-profile conv {} ({}) ==".format(r["conv"], r["model"]))
    print("   window {} .. {}".format(r["first"], r["last"]))
    print("   beats logged: {} ({} in requested window)".format(
        r["beats"]["total"], r["beats"]["in_window"]))
    print("   turns: " + ", ".join(
        "{} {}".format(k, v) for k, v in sorted(r["turns"].items())))
    print()
    print("   {:<10} {:>8} {:>13} {:>12} {:>12} {:>13}".format(
        "origin", "requests", "prompt_tok", "cached_tok", "compl_tok",
        "total_tok"))
    g = [0, 0, 0, 0, 0]
    for name in order + [k for k in per if k not in order]:
        if name not in per:
            continue
        s = per[name]
        for i in range(5):
            g[i] += s[i]
        print("   {:<10} {:>8} {:>13} {:>12} {:>12} {:>13}".format(
            name, n(s[0]), n(s[1]), n(s[2]), n(s[3]), n(s[4])))
    print("   {:<10} {:>8} {:>13} {:>12} {:>12} {:>13}".format(
        "TOTAL", n(g[0]), n(g[1]), n(g[2]), n(g[3]), n(g[4])))
    if g[1]:
        print("   cached fraction of prompt: {:.1f}%".format(
            100.0 * g[2] / g[1]))
    if r["beats"]["in_window"]:
        hb = per.get("heartbeat", [0, 0, 0, 0, 0])
        print("   avg heartbeat request: {} prompt tok over {} requests".format(
            n(hb[1] // max(hb[0], 1)), n(hb[0])))
    print()
    print("   daily totals (last {} day(s)):".format(days))
    for day in sorted(r["daily"])[-days:]:
        parts = r["daily"][day]
        line = ", ".join("{} {}".format(k, n(v))
                         for k, v in sorted(parts.items(),
                                            key=lambda kv: -kv[1]))
        print("     {}  {}".format(day, line))
    print()


def default_conv():
    try:
        text = CONFIG.read_text(errors="replace")
        m = re.search(r'^conv\s*=\s*"([^"]+)"', text, re.M)
        if m:
            return m.group(1)
    except OSError:
        pass
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--conv")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--since", help="YYYY-MM-DD window start (UTC)")
    args = ap.parse_args()

    since_day = args.since
    if not since_day and args.days:
        since_day = time.strftime(
            "%Y-%m-%d", time.gmtime(time.time() - 86400 * (args.days - 1)))

    if args.all:
        convs = sorted(p.name for p in CONVS.iterdir() if p.is_dir())
        for conv in convs:
            r = profile_conv(conv, since_day)
            tot = sum(s[4] for s in r["per"].values())
            req = sum(s[0] for s in r["per"].values())
            print("{:<10} {:>6} requests {:>12} total_tok  {}..{}".format(
                conv, n(req), n(tot), r["first"], r["last"]))
        return

    conv = args.conv or default_conv()
    if not conv:
        sys.exit("no conv given and none found in {}".format(CONFIG))
    r = profile_conv(conv, since_day)
    print_report(r, args.days)


if __name__ == "__main__":
    main()
