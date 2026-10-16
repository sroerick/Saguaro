#!/bin/sh
# hygiene.sh — observe-only repo/image hygiene for a saguaro box (cron, daily).
#
# Never changes live behavior: it pushes main to origin when this box is
# ahead, and LOGS drift so a human (or a debugging agent session) sees it:
#   1. box main vs origin/main — push when ahead, log when behind
#   2. last autolith image-commit age (> 3 days = in-image changes unpersisted)
#   3. installed autolith version vs the ENGINE_PIN "tested" version
# Every run ends with one "hygiene: ok" line, so a daily ok in the log proves
# cron fired and lets a reader spot the first missing day.
# Exit 0 always: cron stays quiet.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOG="$ROOT/harness/hygiene.log"
AUTOLITH_HOME=${AUTOLITH_HOME:-"$HOME/.local/share/autolith"}
IMAGE_COMMITS="$AUTOLITH_HOME/image-commits"
IMAGE_AGE_DAYS=3

log() { printf '%s hygiene: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

# --- 1. repo sync vs origin ------------------------------------------------
if git -C "$ROOT" fetch -q origin 2>>"$LOG"; then
    ahead=$(git -C "$ROOT" rev-list --count origin/main..main 2>/dev/null)
    behind=$(git -C "$ROOT" rev-list --count main..origin/main 2>/dev/null)
    if [ "${ahead:-0}" -gt 0 ]; then
        if git -C "$ROOT" push -q origin main >>"$LOG" 2>&1; then
            log "pushed $ahead commit(s) to origin/main"
        else
            log "DRIFT: push to origin FAILED ($ahead commit(s) unpushed)"
        fi
    fi
    if [ "${behind:-0}" -gt 0 ]; then
        log "DRIFT: box is $behind commit(s) behind origin/main; pull needed"
    fi
else
    log "DRIFT: git fetch origin failed; skipping repo checks"
fi

# --- 2. image-commit age ---------------------------------------------------
# autolith's private mutation-history commits land here; a stale directory
# means in-image work has not been persisted since the last "save" session.
if [ ! -d "$IMAGE_COMMITS" ]; then
    log "DRIFT: $IMAGE_COMMITS missing; cannot track image saves"
else
    newest=$(ls -t "$IMAGE_COMMITS" 2>/dev/null | head -1)
    if [ -z "$newest" ]; then
        log "DRIFT: no image-commits at all"
    elif find "$IMAGE_COMMITS/$newest" -maxdepth 0 -mtime +"$IMAGE_AGE_DAYS" >/dev/null 2>&1; then
        log "DRIFT: last image-commit ($newest) is older than $IMAGE_AGE_DAYS days; in-image changes unpersisted"
    fi
fi

# --- 3. engine pin vs installed --------------------------------------------
tested=$(awk '/^tested:/ {print $2; exit}' "$ROOT/ENGINE_PIN" 2>/dev/null)
installed=""
for c in "$(command -v autolith 2>/dev/null)" "$AUTOLITH_HOME/installation/current/bin/autolith"; do
    if [ -n "$c" ] && [ -x "$c" ]; then
        installed=$("$c" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)
        [ -n "$installed" ] && break
    fi
done
if [ -z "$tested" ]; then
    log "DRIFT: could not parse tested version from ENGINE_PIN"
elif [ -z "$installed" ]; then
    log "DRIFT: could not determine installed autolith version"
elif [ "$installed" != "${tested#v}" ]; then
    log "DRIFT: installed autolith $installed != ENGINE_PIN tested ${tested#v}"
fi

log "ok"
exit 0
