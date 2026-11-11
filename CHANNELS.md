# saguaro on autolith channels

Written 2026-11-10 against `lambda-symbolics/autolith` branch `lho/channels`
at `3e87496c` (VERSION 0.67.32). The design intent behind it is
`docs/autolith-channel-proposal.org` in that tree. This file records what the
harness has to become. `main` stays on the pinned release until the phases
below have landed on a scratch box.

## The interface that replaces sessions

- One **world server** hosts channels. It outlives every terminal: a channel
  keeps running while no client is attached (`src/world/server.lisp`,
  `src/world/client.lisp`).
- A **channel** is the addressable conversation and execution location. Its
  session identifier is the conversation identifier, stable across detach,
  restart and checkpoint. Each channel has its own authenticated local
  endpoint.
- Legacy sessions are still reconciled into channel + participant on every
  start, reusing one mapping per conversation (`src/world/sessions.lisp`), so
  the old `localgroup` verbs keep answering while the model settles.
- A **client** attaches to a channel and gets one ordered event stream:
  `:present`, `:text` deltas, `:status` (`:assistant-response-persisted`,
  `:tool-call-started`), `:work-finished` with `:idle-p`
  (`src/localgroup/subscription.lisp`). Submissions carry an id and their own
  completion, "independently of channel idleness".
- **Channels are resources**: `channel:current`, `channel:id/<id>`,
  `channel:list` (`src/world/resource.lisp`).
- **Messages move between channels**: the person resides in their inbox
  channel, `@name` mentions cross channels without subscribing, and
  subscriptions copy a channel's messages to participants residing elsewhere.
  An agent's proactive message is an ordinary channel message.
- **External clients today**: `autolith acp [--http|--websocket]`
  (`src/acp/*`, `src/startup/main.lisp`), JSON-RPC, opens channels in the
  world server, streams `session/update`, handles prompt, cancel, mode,
  approvals and `_autolith/*` extensions. A run whose stdin is not a terminal
  attaches as a script client instead: one submission per line, transcript on
  stdout (`world-client-run-script`).

## What the harness uses today, and what happens to it

| harness dependency | today | on channels | action |
|---|---|---|---|
| `autolith localgroup status --sexp` | session id, `:idle-p`, `:active-turn-p`, `:waiting-for-input-p` | one record per hosted channel with the same fields plus `:mention-count`, `:task-live-count`, `:terminal-attached-p` (`src/localgroup/runtime.lisp`) | keep, but stop reading tmux liveness into it |
| `autolith localgroup tell SESSION TEXT` | types text into a terminal | sends the channel a message as the person | keep the call; text is now prompt input, never a command line |
| `/model x`, `(compact)`, C-c via `tell` + `send-keys` | terminal commands | client operations on the channel (`:operation`, `:mode`, cancel) | rework the owner ops in `watchdog.py` |
| `<conv>/*.sexp` tailing | reply extraction (`records-for-file`, `all-new-records`, `reply-texts`) | channel history is still a conversation | fallback for one release, then delete |
| settle window, watermark floor, "no text turn" mark | turn end detection (`turn-wait`, `turn-floor`, `above-floor`) | submission completion plus `:work-finished` | delete |
| `tmux capture-pane`, `send-keys`, `kill-session` | crash evidence, forced input, recovery | no pane exists | incident bundles carry bridge log + `lg status` instead |
| one standing conversation for every surface | all DMs and rooms share it | one channel per surface or peer, subscriptions for rooms, mentions for triggers | phase 4 |
| `heartbeat.py` tell | hourly nudge | scheduled message into the standing channel | phase 3 |
| `canary.py` token ping into a MUC | end-to-end chat check | post into a canary channel, verify the subscription copy on the next cycle | phase 3 |
| `tuna` inbox lane | private inbox rows in the standing conversation | the person's inbox channel | phase 4 |

## What the bridge becomes

The bridge stops being a terminal driver and becomes a **channel client**:

1. it finds the world server (`lg start` when absent) and attaches to the
   channel named in config instead of resuming a tmux pane;
2. inbound XMPP/pp messages become submissions with an id, so every reply is
   attributed to the peer that asked;
3. replies, narration and tool activity come from the event stream rather than
   from re-reading and diffing conversation chunk files;
4. turn state comes from `:work-finished`/`await-submission`, so the settle
   window and watermark heuristics go away;
5. owner ops become client calls (cancel, compact, model, permissions) rather
   than keystrokes;
6. proactive agent output and mentions arrive in the person's inbox channel,
   which is what the bridge delivers to the owner surface.

Concretely, in `harness/bridge.lisp` the interface seam is three verbs:

```
status(channel)   -> state plist                ; al-status-records
submit(channel, text) -> submission id          ; al-tell
next-events(channel, from-sequence) -> events   ; new
```

`legacy` implements `submit` with `localgroup tell` and `next-events` by
returning parsed records above a watermark. `channels` implements `submit`
and `next-events` over the event stream. Everything above the seam (reply
policy, chunking, parking, XMPP, pp, commands) is unchanged.

## Surface to channel map

| surface | channel | delivery |
|---|---|---|
| owner DM | the agent's standing channel | direct: the agent is the resident |
| each MUC room | one channel per room | the agent subscribes; `@trigger` becomes a mention |
| pp DM | one channel per habitat user | direct, as a second transport on the same channel |
| heartbeat | the standing channel | scheduled message with a quiet marker |
| canary | a canary channel | post, then verify the copy arrives on the next cycle |
| incidents and pages | the person's inbox | agent-initiated channel message |

The owner keeps one identity across surfaces. XMPP is a transport for the
person's client, not a participant of its own.

## Transport decision

| option | for | against |
|---|---|---|
| **A. ACP** (`autolith acp`, JSON-RPC over stdio, HTTP or WebSocket) | documented, cross-language, ships in the branch, already carries approvals, cancel, mode and the `_autolith/*` extensions; the CL bridge can hold a pipe as easily as a socket | editor-shaped: turn oriented, one subscription per session. Whether it forwards messages the client did not prompt (proactive agent messages, subscription copies, mentions) is unverified |
| **B. native** (image-daemon socket, `channel-subscription` directly) | exact semantics: one connection, any channel, ordered events, submission attribution | internal Lisp protocol with no stability promise, unusable from the Python parts of the harness |
| **C. CLI + history tailing** | zero new dependencies; today's code keeps working with small edits | keeps every heuristic this rebuild exists to remove |

Recommendation: **A** for the turn path. A two-client probe settled the
question that decided it: a client attached to a channel receives what it did
not prompt, so one long-lived ACP connection can carry the whole surface,
replies and proactive messages alike. Keep a thin conformance layer so a
headless channel client can replace it without touching bridge logic.

## Verified against a real build

Built from this branch (`3e87496c`) in a scratch root: the release launcher
compiles the tree when `.qlot` sits beside it, and the twelve dependencies
whose pins moved since 0.67.22 are overlaid on the installed release's
dependency tree. `harness/dev/channels_probe.py` repeats the checks below.

- `autolith lg start` starts the world server with no terminal and prints
  `world server PID N, Autolith 0.67.32, N open channels`.
- `autolith --detached` creates a channel in it and prints
  `Conversation <display id>  PID <world server pid>`; `autolith open <id>
  --detached` resumes one.
- `lg status --sexp` prints one readable form per hosted channel carrying
  `:CONVERSATION-ID`, `:STATE`, `:IDLE-P`, `:WAITING-FOR-INPUT-P`,
  `:ACTIVE-TURN-P`, `:MESSAGE-COUNT`, `:MENTION-COUNT`, `:TASK-LIVE-COUNT`,
  `:TERMINAL-ATTACHED-P` and `:CREATED-AT`. The fields the bridge reads today
  are all still there.
- An empty channel is not durable (`:CONVERSATION-PERSISTED-P NIL`, no
  `conversations/<id>/` directory), so `lg stop`, which terminates the server
  and its channels, drops it.
- Channel history is still a conversation: `conversations/<canonical id>/
  NNNN.sexp`, with the `(:CONVERSATION ...)` header, `(:MESSAGE ... :SUBMISSION
  (:ID ... :CLIENT ... :SOURCE "prompt"))` and `(:TURN-ABORTED ...)`.
- **ACP forwards traffic the client did not prompt.** With two ACP clients on
  one channel, the client that did not prompt received the turn running
  event, the other client's `user_message_chunk`, the `agent_message_chunk`
  reply and the turn idle event.
- ACP `session/load` takes the canonical identifier (`:CONVERSATION-ID` from
  status, not the display form) and refuses a channel that is not durable
  yet; `session/new` opens one and returns `{sessionId, modes}` with the
  permission modes ask, auto, sandboxed and full-access.
- A failed turn answers `session/prompt` with JSON-RPC error -32603 and puts
  the report in the channel transcript as `(:TURN-ABORTED ...)`; the failure
  text also arrives as an `agent_message_chunk`.

### Interface gaps for a headless client

1. `lg tell` refuses with "No person is in the world yet" on a fresh root,
   and neither `lg start` nor `--detached` changes that. The person and the
   inbox conversation appeared only once a real client opened a channel (an
   ACP `session/new` did it, leaving an `:INBOX-P T` conversation behind).
   A bridge that only calls `tell` cannot open the conversation.
2. `lg status --sexp` prints nothing both when no world server runs and when
   it hosts no channel; only the human form names the server. A liveness
   probe cannot use the sexp form alone.
3. ACP attaches per channel and needs a durable conversation id, so a bridge
   cannot watch a channel before its first durable message exists.
4. The user init file in the live config did not compile against 0.67.32
   (`application-status-entry` referenced an internal that moved), so a
   saguaro upgrade has to check the agent's own init before flipping.

## Phases

0. **Pin.** Build the channels release on a scratch box, leave `main` alone.
   No saguaro change. Acceptance: `autolith --version` reports 0.67.32 and a
   detached channel survives a checkpoint.
1. **Seam.** Introduce `status`/`submit`/`next-events` in `bridge.lisp` with a
   `legacy` implementation that reproduces today's behavior. Acceptance: the
   canary stays green with `[autolith] client = "legacy"`.
2. **Channels engine.** Add the `channels` implementation: one channel,
   attach, submit, event stream, completion. Acceptance: a DM turn delivers
   exactly one reply, a 40 minute turn stays attributed, no file polling.
3. **De-tmux.** `start-sessions.sh` boots `lg start` and no terminal;
   `watchdog.py` drops pane probes, pane captures and keystrokes, and drives
   ops through client calls. Acceptance: watchdog restarts a killed world
   server and a killed bridge with no tmux in the path.
4. **Multi-channel.** One channel per surface, subscriptions for rooms,
   mentions for triggers, inbox delivery for proactive output and canaries.
   Acceptance: two peers in parallel turns at once, each reply in its own
   conversation; a proactive message reaches XMPP without a turn.
5. **Retire legacy.** Delete the file tailing, the settle heuristics and the
   `legacy` engine. Acceptance: fresh install from RUNBOOK on a clean box.

## Open questions for lukas

1. Is ACP the sanctioned interface for a long-lived non-terminal client, or is
   a dedicated headless channel client planned?
2. Do `localgroup tell` and `status --sexp` survive the reconciliation period,
   and do they keep their current field names?
3. Can an attached client see messages it did not prompt: proactive agent
   messages, subscription copies, mentions in other channels?
4. How does a headless client answer an approval when nobody is at a keyboard,
   and can it answer with a policy fixed in advance?
5. Is the inbox channel readable and subscribable from outside the image, and
   does its unread state survive restarts?
6. When one XMPP peer sends two messages in a row, does the second land as a
   steer on the running turn, a queued turn, or a new turn? The bridge's reply
   attribution depends on the answer.
