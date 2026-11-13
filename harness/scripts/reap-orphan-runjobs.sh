#!/bin/sh
# reap-orphan-runjobs.sh -- kill autolith "run-job" invocations whose caller is gone.
#
# WHY (measured 2026-11-11 on hwre):
#   pp-flow's adapter (pricklypear/scripts/pp-flow-autolith.sh) runs
#   `autolith run-job`. The autolith launcher puts the SBCL image in its own
#   process group (`set -m` + a fifo gate), so loop.py's killpg() on a pass
#   timeout reaps the adapter but leaves the launcher -- and the image --
#   reparented to init. 46 such orphans accumulated in ~40h. Each holds a
#   process slot against al's RLIMIT_NPROC of 256, so `fork` began failing:
#       fork: retry: Resource temporarily unavailable
#   An orphan is unreadable by definition: its --output never gets a :STATUS
#   (its own :timeout-seconds is 3000, so anything past ~50 min is already
#   over its deadline) and the caller that would read it is dead.
#
# MEASURED GOTCHA: SIGTERM does not touch these processes (92/92 survived a
# TERM, all then died on -9), so this reaps with SIGKILL only.
#
# SAFETY: only ppid == 1 (orphan) AND age >= MIN_AGE are touched, and the
# command must be exactly ".../bin/autolith run-job". A live pass always has
# loop.py or the adapter as its parent.
#
# Usage:  reap-orphan-runjobs.sh            # reap, log to ~/.cache
#         DRY=1 reap-orphan-runjobs.sh      # report only
#         MIN_AGE=3600 reap-orphan-runjobs.sh
set -u

MIN_AGE=${MIN_AGE:-5400}     # 90 min = 1.8x run-job's 3000s job timeout
DRY=${DRY:-0}
LOG=${LOG:-$HOME/.cache/reap-orphan-runjobs.log}
ME=$(id -un)

log() {
  mkdir -p "${LOG%/*}" 2>/dev/null || true
  printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true
  [ "$DRY" = 1 ] && printf '%s\n' "$*"
}

# ps ELAPSED ([[dd-]hh:]mm:ss) -> seconds
age_of() {
  case $1 in
    *-*) d=${1%%-*}; rest=${1#*-} ;;
    *)   d=0;        rest=$1       ;;
  esac
  h=0
  rest=$(printf '%s' "$rest" | tr ':' ' ')
  set -- $rest
  case $# in
    3) h=$1; m=$2; s=$3 ;;
    2) m=$1; s=$2       ;;
    *) return 1         ;;
  esac
  echo $(( d * 86400 + h * 3600 + m * 60 + s ))
}

if [ "${SELFTEST:-0}" = 1 ]; then
  for e in 00:42 13:10 1-16:44 2-03:04:05; do
    printf '%s -> %ss\n' "$e" "$(age_of "$e")"
  done
  exit 0
fi

ps -ww -U "$ME" -o pid=,ppid=,etime=,command= |
  awk '$2 == 1 && $4 ~ /\/bin\/autolith$/ && $5 == "run-job" { print $1, $3 }' |
  while read -r pid etime; do
    age=$(age_of "$etime") || continue
    [ "$age" -ge "$MIN_AGE" ] || continue
    kids=$(ps -U "$ME" -o pid=,ppid= | awk -v p="$pid" '$2 == p { print $1 }')
    log "$(date -u +%Y-%m-%dT%H:%M:%SZ) reap pid=$pid age=${age}s kids=[$kids]"
    if [ "$DRY" = 0 ]; then
      [ -n "$kids" ] && kill -9 $kids 2>/dev/null
      kill -9 "$pid" 2>/dev/null
    fi
  done

# keep the log bounded
if [ "$DRY" = 0 ] && [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 500 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
