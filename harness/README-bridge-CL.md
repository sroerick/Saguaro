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
