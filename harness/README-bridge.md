# opencliwsp

An OpenClaw-style XMPP gateway for a detached Autolith agent session.
Built 2026-09-01 on the author's OpenBSD box so the owner can talk to an
always-on Lisp agent from any XMPP client, and the agent can talk back,
proactively, without becoming noisy.

    XMPP client (owner@...)
        |  1:1 chat + MUC rooms
        v
    bridge.py (slixmpp, tmux)  ---tell/poll--->  autolith localgroup (agent session)
        ^                                        (durable conversation logs on disk)
        |  kill+resume on hang
    watchdog.py (cron 5min)      heartbeat.py (cron hourly)

## What each piece does
- `bridge.py` - the gateway. Per allowed 1:1 message or MUC `nick: ...`
  message: `autolith localgroup tell <sid> <text>`, poll `localgroup status`
  until the turn ends, parse the new records in the durable conversation
  log, send the agent's text back chunked. Also: unattended
  permission-picker auto-answer (tmux), kill+resume recovery, `reset`
  command.
- `heartbeat.py` - hourly proactive check-in: prompts the agent; if the
  reply is non-trivial (not the "OK" sentinel), pushes it to the owner. The
  agent acts on its own agenda/memory; the owner only hears what is worth
  hearing.
- `watchdog.py` - liveness every 5 min; hung-turn signature (0% CPU over
  6s, no external sockets, conversation log not flushed 10+ min) triggers
  the kill+resume drill. Conversation history survives; the owner gets an
  alert.
- `muc_send.py`, `muc_history.py` - one-shot MUC post/history tools the
  agent itself shells out to.
- `start-sessions.sh` - idempotent boot/watchdog entrypoint (tmux
  sessions). Generates the persona file on first boot (see below).
- `scripts/gen_agents.py` + `persona.tmpl.md` - generate the agent's
  workspace persona file (AGENTS.md) from the template, filling
  owner/agent/host from bridge.toml. Refuses to overwrite: after first
  generation the file belongs to the user.
- `scripts/smoke.py` - commissioning diagnostic: tell the agent an
  expression, poll, print the reply.

## Setup
1. Python 3.11+; `python3 -m venv venv && venv/bin/pip install -r requirements.txt`
2. `cp config.example.toml bridge.toml` (chmod 600); create `xmpp.password` (0600)
3. Install the two cron lines from `crontab.example`
4. `./start-sessions.sh`  (boot: call it from rc.local or the user's profile)

The persona file lands at ~/AGENTS.md (override with AGENTS_MD) and is
yours to edit; the generator never rewrites it.

## Status
Works on the author's box. Deploys elsewhere with the config template +
gen_agents flow. No releases yet.

## License
MIT - see LICENSE (c) 2026 roerick.
