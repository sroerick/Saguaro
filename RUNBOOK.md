# RUNBOOK — your own saguaro

Zero to a long-running agent on your own box.

## 0. Prerequisites

- A Unix box you control (OpenBSD, Linux, macOS) with `tmux` and cron.
- Python 3.9+ with venv.
- An XMPP account for the agent. Register on any public server, or run
  your own (prosody is painless). You will also want one for yourself.
- A model-provider API key that autolith can use.

## 1. Install the engine (autolith)

The mind is a separate ISC-licensed project. See ENGINE_PIN for the
version saguaro is tested against.

    curl -fsSL https://sh.lambda-symbolics.com/autolith | sh

(inspect the installer before piping it to a shell), or on Nix:

    nix run github:lambda-symbolics/autolith

Verify it runs: `autolith --version`.

## 2. Create the agent's XMPP account

Register a JID for the agent (e.g. `myagent@example.net`). Put the
password in a file readable only by you:

    umask 077
    read -s PW && printf '%s' "$PW" > ~/myagent.password

The bridge reads the password from `password_file`; it never appears in
config.toml.

## 3. Configure

    cd saguaro
    python3 -m venv harness/venv
    harness/venv/bin/pip install --no-deps -r harness/requirements.txt  # why --no-deps: see note in requirements.txt
    cp harness/config.example.toml harness/config.toml && chmod 600 harness/config.toml

Fill in: the agent JID + password_file path, your JID as the owner, the
autolith session name, and (once the session has started once) the
conversation id the bridge should talk to. Every key is documented
inline in config.example.toml.

## 4. Generate the persona (optional but fun)

    harness/venv/bin/python harness/scripts/gen_agents.py

Reads persona.tmpl.md, asks a few questions, writes the agent's
AGENTS.md. Edit it in place afterwards; the generator will not overwrite.

## 5. Start

    harness/start-sessions.sh

Starts the autolith session in tmux (session name from config), then the
bridge in its own tmux session. Send your agent a message from your XMPP
client. It answers from the session you just started.

## 6. Keep it alive (cron)

    crontab -e   # paste harness/crontab.example, adjust paths

heartbeat.py nudges the session hourly so a long-running agent keeps its
rhythm; watchdog.py checks every five minutes and restarts the bridge or
the session if either died. With `[bridge] canary = "on"` the watchdog
also runs the end-to-end canary (canary.py) on the `canary_secs` cadence:
wake, connect, deliver one line into `canary_muc` (a test room -- never
the owner's DM), and alert you when any hop fails.

## 7. Optional: Pricklypear-backed memory (default: off)

Out of the box, the agent's persistent memory is autolith's native local
memory -- no habitat required. If you run a Pricklypear habitat and want
the agent's memories mirrored there as durable, history-tracked rows
visible to habitat-side agents:

1. Set `[memory] pp_mirror = "on"` in config.toml (plus pp_url/pp_user;
   pass the token via the PP_TOKEN environment variable, never in the
   file).
2. Install SBCL if you have not (the mirror is Common Lisp).
3. Point the graft drain at the mirror:

       NOPALES_HOME=$PWD/pp_mirror PP_TOKEN=... sbcl --script pp_mirror/graft-drain.lisp

   on the cron cadence from [memory] graft_cron. Writes are idempotent
   per memory id; losing connectivity never loses a memory, the drain
   catches up.

## 8. Upgrades

Bump the engine by re-running the installer (it updates in place). Check
ENGINE_PIN first; soak on a scratch session before flipping production.
The harness itself: `git pull` in this repo and restart the bridge
(watchdog will do it for you if you just kill it).

## 9. Secret rotation

Four kinds of secret live around a running saguaro: the XMPP password,
the habitat token (only if a PP surface is enabled), the model-provider
API key, and any service tokens the agent holds. None of them belong in
config.toml or in the repo. If one ever transited a chat, a log, or a
commit, rotate it now and skip the calendar.

XMPP password (the bridge's identity):

  1. Change it where the account lives (your XMPP server's admin
     interface, or re-register the account).
  2. Write the new password to the file `password_file` points at:

         umask 077; printf '%s' 'NEW-PASSWORD' > /path/to/xmpp.password

  3. Restart the bridge (kill the tmux session; the watchdog brings it
     back within five minutes). The heartbeat, watchdog alerts, and the
     canary all read the same file, so nothing else needs touching.
     The next canary run doubles as proof the new password works.

Habitat token (only if [pp] or [memory] is enabled):

  1. Revoke the old token in the habitat, issue a new one.
  2. Update the environment the bridge and the drains see: PP_TOKEN in
     the bridge tmux and on the graft-drain cron line (or `token_file`,
     0600). Never config.toml.
  3. Restart the bridge; the next drain run picks up the new value.

Model-provider API key:

  Rotate at the provider, update wherever autolith reads it (environment
  or its own credential store -- see the autolith docs), and restart the
  agent session.

Rules that keep rotation boring:

  - secret files 0600, owner-only; config.toml never holds a secret
  - restart the affected process after rotating, then confirm one green
    signal (the bridge's "online as" log line, a green canary) before
    trusting it
  - put long-lived tokens on a rotation calendar even when nothing
    leaked
