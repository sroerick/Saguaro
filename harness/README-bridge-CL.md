# bridge.lisp — the Common Lisp gateway (2026-09-27)

Replaces `harness/bridge.py` for the standing autolith session. Zero-dependency
`sbcl --script`, same house pattern as `glochid.lisp`: no quicklisp; TLS via
`openssl s_client -starttls xmpp` as a byte pipe (SBCL has no TLS); HTTP via
curl.

```sh
sbcl --script harness/bridge.lisp            # BRIDGE_CONFIG overrides config path
BRIDGE_ENGINE=python start-sessions.sh       # roll back to bridge.py
```

External contracts are unchanged, so `watchdog.py` / `canary.py` /
`start-sessions.sh` keep working: tmux session `xmpp-bridge`, log
`harness/bridge.log`, config `harness/config.toml`, turn marker
`~/.cache/saguaro-turn-active`.

## Senders (say.lisp, 2026-10-09)

One-shot dm/muc/history tools for the agent's hands, reusing this file's
xmpp stack instead of a second slixmpp implementation:

    sbcl --script harness/say.lisp dm TO_JID BODY|-        one-shot DM ('-' body on stdin)
    sbcl --script harness/say.lisp muc ROOM_JID TEXT...    post to a configured room
    sbcl --script harness/say.lisp history ROOM_JID [MAX]  real room history (default 30)

Same CLIs as the Python trio they replace (`dm_send.py` / `muc_send.py` /
`muc_history.py`, scheduled for deletion after the zero-Python soak).
Mechanics: say.lisp loads bridge.lisp as a library — `SAGUARO_NO_MAIN=1`
goes up before the load so `(main)` never runs — binds a RANDOM per-shot
resource (the live bridge holds the configured one; a second bind on it
would kick the bridge off the server), sends, and closes. Room joins wait
for real self-presence (status 110, nickname conflict retried as
`nick-say`); history is the delay-stamped replay collected during the
join window. Rooms must be listed under `[bridge] mucs` — that list stays
the authorization boundary. Exit 0 = stanza handed to the stream
(delivery not confirmed), 1 = failure.

Zero-Python soak (started 10-09): the recurring Python senders ride this
stack too — heartbeat.py's owner push and canary.py's deliver hop call
`say.lisp dm` / `say.lisp muc` instead of their own slixmpp clients.
slixmpp now remains only in bridge.py (the BRIDGE_ENGINE=python
fallback). The canary is armed (10-09, roerick ok'd): the watchdog runs
it hourly ([bridge] canary_secs = 3600) and pages the owner on failure.

## Why it exists (the three silent-turn bugs)

1. **Time-based wait.** bridge.py gave up at `turn_timeout_secs` (900s); real
   turns run 30–60+ min, so the answer landed in the conversation log with
   nobody polling, and the next turn's fresh watermark consumed it
   undelivered ("How did it go" three times in bridge.log). Now: wait on
   PROGRESS — the turn is over when autolith is idle *and* the log has been
   quiet for `stall_secs`; `turn_timeout_secs` is only a hard cap.
2. **Volatile watermark.** Watermarks and undelivered ("parked") texts now
   persist in `~/.cache/saguaro-bridge-state.sexp`. A restart re-delivers
   instead of consuming; a turn orphaned by a bridge death is reaped and
   delivered as "picking up where I left off".
3. **Swallowed delivery errors.** `pp_say` retries with backoff and parks the
   text in the state file on final failure, where the main loop retries it. A
   habitat 502 window can no longer eat a reply.

## Gotchas (each cost real debugging time)

- Read autolith `.sexp` records in `bridge-sexp-read` (a package that `:use`s
  CL), **never KEYWORD**: `#A((n) BASE-CHAR ...)` needs the real
  `CL:BASE-CHAR`, and `:BASE-CHAR` is not a valid array element type.
- Build HOME-relative paths with `home-path`, not `merge-pathnames`: HOME has
  no trailing slash, so `merge-pathnames` treats it as a FILE name and
  `.cache/x` became `/home/.cache/x/al`.
- We WRITE to `sb-ext:process-input` (the child's stdin) and READ from
  `process-output`. Swapping them yields "descriptor N is not a character
  output stream" at the first send.
- Incremental parsing must resume at the READ offset (which includes the
  unparsed tail) and read bytes exactly — `read-line`/`write-line` adds a
  newline to an unterminated last line and desyncs offsets.
- Verify nesting with the READER, not by eye: a `handler-case` clause written
  inside the protected `progn` becomes a runtime function call (`E is
  undefined`). `sbcl --script` compile warnings will not tell you.
- On a first run (no persisted state), baseline all existing records as seen,
  or the first turn collects the whole conversation (6928 records observed)
  and delivers a historical message as the answer.
- The TLS socket belongs to the openssl CHILD, so watchdog/canary must check
  the process *and its descendants* for `:5222`.

## Verified on cutover (2026-09-27)

MUC mention → `turn start` → `turn over: DONE` (67s) → `collected 3 new
records, 1 assistant text` → `deliver XMPP-GROUP (8 chars)`; the room shows
`gregor: FINAL-OK`. watchdog silent (healthy, and defers repairs mid-turn),
canary green on all three hops, exactly one tunnel, flat RSS, 0% CPU.

## Incident: post-reboot silent turns (2026-10-04)

Symptom: after a clean reboot the bridge and autolith session both came up,
the bridge logged `DM from roerick...` and `turn over: DONE`, but delivered
`0 assistant text(s)` — gregor was online but mute.

Cause: the first post-boot turn (reported 168,746 tokens, past the
`AUTOLITH_COMPACTION_THRESHOLD=60` trigger) ran a *mid-turn* compaction whose
summarization side-channel returned no text. Autolith raises
`CL-LLM-PROVIDER-API:PROVIDER-PROTOCOL-ERROR` ("Compaction produced no summary
text.") and aborts the turn before any assistant text is appended, so the
bridge has nothing to deliver. A reboot is what put the conversation over the
trigger at the wrong moment.

Recovery (safe, non-destructive; history is untouched):

    su - al -c "~/.local/bin/autolith localgroup tell E5WjMcb 'Reply with exactly: ALIVE-PROBE-OK'"

This forces the pending compaction to run again; on success it appends a new
`:SUMMARY` record and the live context drops (observed 169K -> 27K). Confirm
with `tmux capture-pane -pt alagent -S -5` (ctx line) and
`grep '^(:SUMMARY' ~/.local/share/autolith/conversations/<conv>/*.sexp`.

Why the watchdog stayed quiet: the session is idle, the process is alive, the
:5222 connection is live and the canary is green — the failure is only visible
in the turn's record stream (`TURN-ABORTED`, `PROVIDER-PROTOCOL-ERROR`), which
the watchdog does not parse. A future guard should alert when a turn completes
with a `TURN-ABORTED` at/after its `TURN-START-SEQ` and no new assistant item.

Do NOT delete watermarks or the conversation to recover: the bridge's
watermark default is 0 (unseen), so wiping state re-delivers the last
historical assistant message as if it answered the current request. If the
compaction dead-end ever becomes permanent, rotate `[autolith] conv` to a
fresh id (the documented rotation), not a conversation wipe.
