# saguaro

An always-on personal AI agent on your own box, in an evening.

saguaro is the runnable distribution of an autolith-based agent: the Lisp
image (autolith, the mind) plus the Python keep-alive harness (the body) --
an XMPP bridge, heartbeat, watchdog, and boot scripts. Your agent runs
detached in tmux, talks to you from any XMPP client, initiates messages on
its own schedule, and survives crashes and reboots without hand-holding.

    XMPP client (you@anywhere)
        | 1:1 chat + MUC rooms
        v
    harness/bridge.py (slixmpp)  <-->  autolith session (SBCL, tmux)
        ^                                    |
    heartbeat.py / watchdog.py         model provider (API)
        (cron: keep it alive)

## What's in the box

| piece       | what                                                   |
|-------------|--------------------------------------------------------|
| harness/    | XMPP bridge + heartbeat + watchdog + boot (Python, MIT)|
| pp_mirror/  | optional Pricklypear-backed memory store (ISC, vendored nopalito) |
| RUNBOOK.md  | zero-to-agent install and wiring                       |
| ENGINE_PIN  | autolith version this release is tested against        |

By default saguaro ships with **no Pricklypear dependency**: the agent's
persistent memory is autolith's native local memory. If you run a
Pricklypear habitat and want the agent's memories to live there too --
durable rows, history, visible to habitat-side agents -- flip one config
key (RUNBOOK section 7).

## Run yours

Short version; details in RUNBOOK.md:

    curl -fsSL https://sh.lambda-symbolics.com/autolith | sh   # the engine
    python3 -m venv harness/venv && harness/venv/bin/pip install -r harness/requirements.txt
    cp harness/config.example.toml harness/config.toml         # fill in JID + password
    harness/start-sessions.sh                                  # tmux + bridge
    crontab harness/crontab.example                            # heartbeat + watchdog

## License

- `harness/` and top level: MIT (c) 2026 roerick
- `pp_mirror/`: ISC, vendored from the Pricklypear repo -- see pp_mirror/VENDORED.md
- The autolith engine is ISC (c) Lambda Symbolics OUE; it is not included
  in this repo -- see ENGINE_PIN.
