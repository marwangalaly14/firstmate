#!/usr/bin/env bash
# SessionStart hook (matcher "compact"): after a worker's context is compacted,
# print the story spine back to the session FROM DISK, and keep the story's
# compaction ledger in its status file. The design contract is the
# crewmates-compact-at-120k story: the loop's state already lives in the brief,
# the status file, the report, and the branch, so the compaction summary is
# never trusted with anything that matters - read from disk, always.
#
# Stdin: the Claude SessionStart hook payload. The hook answers ONLY
# {"hook_event_name":"SessionStart","source":"compact"}; every other payload,
# a missing jq, an unresolvable story, or a brief without a `Budget:` line is
# a silent exit 0 that writes nothing. The brief's Budget line is the gate:
# sessions with no recorded budget (the captain's, firstmate's, every
# non-worker session) never see this hook output.
#
# Story resolution, two modes:
#   --home <FM_HOME> --id <task-id>   explicit; what bin/fm-spawn.sh writes
#                                     into the worker's settings.local.json
#   (no args)                         derive from the payload: cwd must be a
#                                     git worktree or repo on branch fm/<id>,
#                                     and the owning home is the git common
#                                     dir's parent (validated: state/ and bin/
#                                     exist). This is the tracked
#                                     .claude/settings.json entry's shape for
#                                     workers inside firstmate-repo worktrees.
#
# Side effects, all under the per-story state lock:
#   state/<id>.status         += `compacted <n> at <largest>` (exact line; the
#                              ledger the stop hook counts)
#   n = 1: data/learnings.md  += one incident line naming story, peak, budget
#   n >= 2: state/<id>.status += `blocked: ...` so firstmate wakes
#   state/.<id>.compact-fire  = "<epoch> <n> <session>" duplicate-fire marker
#
# `largest` is the peak context measured from the transcript's usage rows
# (input + cache_read + cache_creation, sidechain rows skipped). A missing,
# lagging, or unreadable transcript - the rehearsal showed both happen - reads
# as peak 0 and says so in the spine text rather than fabricating a number.
#
# Duplicate-fire dedup: one compaction event can reach this hook twice because
# the tracked settings entry and the spawn-written entry merge into one
# session and their command strings differ. A fire is skipped when the marker
# shows the same session already appended this exact ledger count within
# FM_COMPACT_DEDUP_WINDOW seconds (see bin/fm-compact-lib.sh). A genuine second
# compaction cannot land inside that window: it must regrow ~120k tokens of
# context first.
#
# Output: the spine on stdout (injected as context), exit 0 always. A
# SessionStart exit 2 would not block the session anyway - every failure here
# is silent-by-design, never session-breaking.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-compact-lib.sh
. "$SCRIPT_DIR/fm-compact-lib.sh"

silent_exit() { exit 0; }

# jq is the payload parser; without it the hook cannot read anything and steps
# aside rather than guessing.
command -v jq >/dev/null 2>&1 || silent_exit

PAYLOAD=$(cat 2>/dev/null) || silent_exit
[ -n "$PAYLOAD" ] || silent_exit
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null) || silent_exit
SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '.source // empty' 2>/dev/null) || silent_exit
[ "$EVENT" = "SessionStart" ] && [ "$SOURCE" = "compact" ] || silent_exit

SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || silent_exit
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || silent_exit
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null) || silent_exit

HOME_ARG=""
ID_ARG=""
FM_DERIVED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || silent_exit; HOME_ARG=$2; shift 2 ;;
    --id) [ $# -ge 2 ] || silent_exit; ID_ARG=$2; shift 2 ;;
    *) shift ;;
  esac
done

FM_ID="$ID_ARG"
FM_HOME=""
if [ -n "$HOME_ARG" ] && [ -n "$FM_ID" ]; then
  FM_HOME=$HOME_ARG
else
  FM_DERIVED=1
  # Derive mode: the story is the fm/<id> branch of the payload cwd; the
  # owning home is the parent of the git common dir. Anything else - not a
  # repo, another branch shape, a home without state/ and bin/ - stays silent.
  [ -n "$CWD" ] && [ -d "$CWD" ] || silent_exit
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null) || silent_exit
  case $BRANCH in
    fm/*) FM_ID=${BRANCH#fm/} ;;
    *) silent_exit ;;
  esac
  [ -n "$FM_ID" ] || silent_exit
  COMMON=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || COMMON=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null) || silent_exit
  FM_HOME=$(dirname -- "$COMMON")
fi
[ -n "$FM_HOME" ] && [ -n "$FM_ID" ] || silent_exit
[ -d "$FM_HOME/state" ] || silent_exit
# bin/ is the derive-mode home marker only: an explicit spawn-passed home is
# trusted as the caller's own, and a fixture or secondmate home may not carry
# a bin/ directory.
[ "$FM_DERIVED" = 1 ] && [ ! -d "$FM_HOME/bin" ] && silent_exit

BRIEF="$FM_HOME/data/$FM_ID/brief.md"
BUDGET=$(fm_compact_budget_from_brief "$BRIEF")
[ -n "$BUDGET" ] || silent_exit

STATUS="$FM_HOME/state/$FM_ID.status"
LEARNINGS="$FM_HOME/data/learnings.md"
MARKER="$FM_HOME/state/.$FM_ID.compact-fire"
LOCK="$FM_HOME/state/.$FM_ID.compact-lock"

# Peak context from the transcript's usage rows, streamed one line at a time.
# jq exits nonzero on a malformed line mid-stream; the numbers it already
# printed are still piped through, so the max of what was readable wins.
fm_compact_peak_from_transcript() {
  local path=$1
  [ -n "$path" ] && [ -f "$path" ] || { printf '0\n'; return 0; }
  jq -r 'select(.isSidechain != true) | .message.usage? | select(. != null) |
         ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))' \
    "$path" 2>/dev/null | sort -n | tail -1
}

# Minimal portable critical section: mkdir is atomic on every supported
# platform. Bounded spin; losing means the other settings-layer fire of the
# SAME event holds the lock and is doing the append, so skipping is correct.
# A lock left by a crashed fire is taken over once it is older than the dedup
# window, so one dead process can never wedge every future compaction.
fm_compact_acquire_lock() {
  local dir=$1 spins=0
  while ! mkdir -- "$dir" 2>/dev/null; do
    if [ -d "$dir" ]; then
      if [ -z "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        : # younger than a minute: a live fire holds it, keep waiting
      else
        rmdir -- "$dir" 2>/dev/null && continue
      fi
    fi
    spins=$((spins + 1))
    [ "$spins" -lt 40 ] || return 1
    sleep 0.05 2>/dev/null || sleep 1
  done
  return 0
}

fm_compact_release_lock() {
  rmdir -- "$1" 2>/dev/null || true
}

if ! fm_compact_acquire_lock "$LOCK"; then
  silent_exit
fi

COUNT=$(fm_compact_count_from_status "$STATUS")
NOW=$(date +%s)

# Duplicate fire of the event this session already appended (see header).
if [ -f "$MARKER" ]; then
  MARKER_EPOCH=$(awk '{print $1}' "$MARKER" 2>/dev/null)
  MARKER_N=$(awk '{print $2}' "$MARKER" 2>/dev/null)
  MARKER_SESSION=$(awk '{print $3}' "$MARKER" 2>/dev/null)
  case $MARKER_EPOCH in '' | *[!0-9]*) MARKER_EPOCH=0 ;; esac
  if [ "$MARKER_SESSION" = "$SESSION" ] && [ "$MARKER_N" = "$COUNT" ] \
    && [ "$((NOW - MARKER_EPOCH))" -lt "$FM_COMPACT_DEDUP_WINDOW" ]; then
    fm_compact_release_lock "$LOCK"
    silent_exit
  fi
fi

PEAK=$(fm_compact_peak_from_transcript "$TRANSCRIPT")
case $PEAK in '' | *[!0-9]*) PEAK=0 ;; esac
N=$((COUNT + 1))

printf 'compacted %s at %s\n' "$N" "$PEAK" >> "$STATUS"

if [ "$N" -eq 1 ]; then
  {
    printf -- '- %s - `%s` compacted once (peak %s tokens) on a story briefed at %s tokens.\n' \
      "$(date +%F)" "$FM_ID" "$PEAK" "$BUDGET"
  } >> "$LEARNINGS"
elif [ "$N" -ge 2 ]; then
  printf 'blocked: second auto-compaction on this story; firstmate must split the story or lift the stop\n' >> "$STATUS"
fi

printf '%s %s %s\n' "$NOW" "$N" "$SESSION" > "$MARKER"
fm_compact_release_lock "$LOCK"

# --- the spine, from disk -----------------------------------------------------
printf 'Your context was compacted. This spine is read from disk, not from the compaction summary - trust it over the summary.\n\n'
printf 'Story: %s\nBrief: %s\n' "$FM_ID" "$BRIEF"

if [ -f "$BRIEF" ]; then
  if grep -q '^## Definition of done' "$BRIEF" 2>/dev/null; then
    sed -n '/^## Definition of done/,$p' "$BRIEF" | head -60
  else
    sed -n "/^## Captain's intent/,\$p" "$BRIEF" | head -60
  fi
  printf '\n'
fi

printf 'Budget: %s tokens. Compactions so far: %s. Peak context this compaction: %s tokens.\n' \
  "$BUDGET" "$N" "$PEAK"
if [ "$PEAK" = "0" ]; then
  printf 'The transcript was not readable at compaction time, so the peak is unknown (recorded as 0) - the trigger point, not the measurement, is what fired this hook.\n'
fi

printf '\nRecent status events (wake-event history, not current state):\n'
tail -12 "$STATUS" 2>/dev/null

REPORT="$FM_HOME/data/$FM_ID/report.md"
if [ -f "$REPORT" ]; then
  printf '\nReading on file: %s\n' "$REPORT"
  head -15 "$REPORT" 2>/dev/null
fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  COMMITS=$(git -C "$CWD" log --oneline --max-count=15 main..HEAD 2>/dev/null) \
    || COMMITS=$(git -C "$CWD" log --oneline --max-count=15 master..HEAD 2>/dev/null) || COMMITS=""
  if [ -n "$COMMITS" ]; then
    printf '\nCommits on the story branch:\n%s\n' "$COMMITS"
  fi
fi

if [ "$N" -eq 1 ]; then
  printf '\nAppend one line to your status file naming WHY this story was too big for the window, so the incident record carries the cause and firstmate can split it.\n'
elif [ "$N" -ge 2 ]; then
  printf '\n%s\n' "$(fm_compact_hold_sentence "$PEAK" "$BUDGET")"
  printf 'Your further tool calls will be denied. Firstmate has been notified through the blocked status line and will split the story or explicitly lift the stop.\n'
fi

exit 0
