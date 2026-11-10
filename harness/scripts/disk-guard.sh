#!/bin/sh
# disk-guard.sh - keep the root filesystem from filling with dune _build trees.
#
# Why: 2026-11-10 outage. Every factory job leaves a ~1.5-3G _build behind;
# four of them filled / to 101% (-18K free) and took the agent and the bridge
# down. The watchdog had no disk check at all, so the first symptom was a
# canary FAIL 75 minutes later and a "restart" that could not write.
#
# Policy - SIZE-aware, not schedule-based (a pure age pruner still fills up
# during a burst of jobs):
#   free >= LOW   (8G) -> prune builds idle > HARD_IDLE (48h)   [hygiene]
#   free <  LOW        -> prune builds idle > SOFT_IDLE (2h)    until TARGET (10G)
#   free <  FLOOR (4G) -> prune builds idle > TIGHT_IDLE (20m)  until TARGET
# A _build being written by a running build always has a fresh mtime, so the
# idle window IS the safety property: nothing younger than TIGHT_IDLE is ever
# removed. Only directories literally named _build under known worktree roots
# are candidates; the live checkouts (/home/al/pricklypear, tuna-work, ...) are
# never touched. Deleting a _build only costs a rebuild, never source.
#
# Exit: 0 quiet/ok, 1 pruned something, 2 still below FLOOR after pruning.
# Usage: disk-guard.sh [--dry-run] [--verbose]

set -u

DRY=0
VERB=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verbose) VERB=1 ;;
        *) echo "usage: $0 [--dry-run] [--verbose]" >&2; exit 64 ;;
    esac
done

G=$((1024 * 1024))
LOW_KB=$((8 * G))
TARGET_KB=$((10 * G))
FLOOR_KB=$((4 * G))
HARD_IDLE=172800    # 48h
SOFT_IDLE=3600      # 1h
TIGHT_IDLE=1200     # 20min

LOG=/home/al/saguaro-live/harness/disk-guard.log

# Worktree roots whose _build dirs are disposable. Add roots here, not paths.
ROOTS="/home/al/factory-loop/wt
/home/al/.worktrees
/home/al/.local/share/autolith/task-worktrees/checkouts
/tmp/pp-gate"

free_kb() { df -k / | awk 'NR==2 {print $4}'; }

free0=$(free_kb)
now=$(date +%s)

# --- pick the tier ---------------------------------------------------------
if [ "$free0" -lt "$FLOOR_KB" ]; then
    tier=tight;   idle=$TIGHT_IDLE
elif [ "$free0" -lt "$LOW_KB" ]; then
    tier=low;     idle=$SOFT_IDLE
else
    tier=hygiene; idle=$HARD_IDLE
fi

# --- enumerate candidates cheaply (mtime only), oldest first ---------------
tmp=$(mktemp /tmp/diskguard.XXXXXX) || exit 70
for root in $ROOTS; do
    [ -d "$root" ] || continue
    find "$root" -type d -name _build -prune 2>/dev/null | while IFS= read -r d; do
        mt=$(stat -f %m "$d" 2>/dev/null) || continue
        age=$((now - mt))
        [ "$age" -ge "$idle" ] || continue
        printf '%s\t%s\n' "$age" "$d"
    done
done | sort -rn > "$tmp"

if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    [ "$VERB" = 1 ] && echo "disk-guard: free=$(($free0 / 1024))M tier=$tier nothing eligible"
    exit 0
fi

target=$TARGET_KB
[ "$tier" = hygiene ] && target=$((free0 + 1))   # hygiene: take every eligible

freed=0
n=0
deleted=""
while IFS='	' read -r age d; do
    [ -n "$d" ] || continue
    cur=$(free_kb)
    [ "$cur" -ge "$target" ] && break
    size=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    [ -n "$size" ] || size=0
    if [ "$DRY" = 1 ]; then
        echo "would delete $d ($((size / 1024))M, idle $((age / 3600))h)"
        freed=$((freed + size))
        n=$((n + 1))
        continue
    fi
    if rm -rf "$d" 2>/dev/null; then
        freed=$((freed + size))
        n=$((n + 1))
        deleted="$deleted $d"
    fi
done < "$tmp"
rm -f "$tmp"

free1=$(free_kb)
msg="free=$((free0 / 1024))M->$((free1 / 1024))M tier=$tier pruned=$n freed=$((freed / 1024))M"
[ -n "$deleted" ] && msg="$msg dirs:$deleted"

if [ "$n" -gt 0 ] || [ "$VERB" = 1 ] || [ "$free1" -lt "$FLOOR_KB" ]; then
    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s disk-guard: %s\n' "$stamp" "$msg"
    printf '%s disk-guard: %s\n' "$stamp" "$msg" >> "$LOG" 2>/dev/null
fi

[ "$free1" -lt "$FLOOR_KB" ] && exit 2
[ "$n" -gt 0 ] && exit 1
exit 0
