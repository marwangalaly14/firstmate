#!/usr/bin/env bash
# Pure decision core for the worker auto-compaction machinery. No I/O of its
# own beyond reading the files its callers name.
#
# The measured trigger law (claude 2.1.259, live interactive TUI, 2026-09-04):
#   - Headless `claude -p` never auto-compacts; the machinery is wired for the
#     interactive TUI workers actually run.
#   - With autoCompactWindow set to W, auto-compaction fires at the first
#     between-turn context check after the context crosses W - 33000. The 33k
#     "Autocompact buffer" is flat: verified at W=120k (fired at 87k),
#     W=153k (fired at exactly 120,000), and W=200k (fired at 167k).
#   - The trigger is only checked between turns, so one large turn can carry
#     the true peak well past the crossing before the check runs. The crossing
#     (~120k) is the trigger; the peak the transcript records is the crossing
#     plus whatever the last turn added. Both numbers are real and mean
#     different things; see docs/architecture.md "Worker auto-compaction".
#   - Below the documented 100000 floor the window silently clamps.
#   - Project-local settings beat user settings; sessions read settings at
#     startup only.
#
# fm-spawn writes the measured window into every claude worker worktree's
# .claude/settings.local.json, so a worker's head compacts at ~120k.
FM_COMPACT_WINDOW_TOKENS=${FM_COMPACT_WINDOW_TOKENS:-153000}
FM_COMPACT_BUFFER_TOKENS=${FM_COMPACT_BUFFER_TOKENS:-33000}

# fm_compact_is_positive_int <value>
# True only for a bare positive decimal integer. Both token settings are read
# from the environment and then land verbatim in a worker's
# settings.local.json and in its task record, so anything else has to be
# refused by the caller rather than arithmetic-expanded or interpolated.
fm_compact_is_positive_int() {
  case ${1:-} in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
}

# The measured trigger, consumed by bin/fm-spawn.sh when it writes the task
# record's budget= field. Empty when either setting is not a positive integer
# or the buffer is not smaller than the window: a budget that is absent closes
# the gate honestly, and bin/fm-spawn.sh refuses the spawn outright rather
# than writing a nonsense window or a negative budget.
if fm_compact_is_positive_int "$FM_COMPACT_WINDOW_TOKENS" \
  && fm_compact_is_positive_int "$FM_COMPACT_BUFFER_TOKENS" \
  && [ "$FM_COMPACT_WINDOW_TOKENS" -gt "$FM_COMPACT_BUFFER_TOKENS" ]; then
  FM_COMPACT_TRIGGER_TOKENS=$((FM_COMPACT_WINDOW_TOKENS - FM_COMPACT_BUFFER_TOKENS))
else
  FM_COMPACT_TRIGGER_TOKENS=""
fi
export FM_COMPACT_TRIGGER_TOKENS
# A genuine second compaction must regrow ~120k tokens of context first, so a
# duplicate delivery of the SAME compaction event is any re-fire from the same
# session within this many seconds.
FM_COMPACT_DEDUP_WINDOW=${FM_COMPACT_DEDUP_WINDOW:-15}

# fm_compact_budget_from_brief <brief>
# The brief's `Budget:` line, when a human wrote one. A number with an
# optional K/M suffix; commas stripped; decimals refused rather than rounded.
# This is the OVERRIDE path: fm-spawn writes the machine record (see
# fm_compact_budget_from_meta), and real scaffold briefs carry no Budget line.
fm_compact_budget_from_brief() {
  local line
  line=$(grep -m1 -E '^[[:space:]]*Budget:' "$1" 2>/dev/null) || return 0
  fm_compact_budget_from_line "$line"
}

# fm_compact_budget_from_meta <meta>
# The `budget=` field fm-spawn writes into every claude worker's task record.
# This is the gate's normal key: it exists for every spawned claude worker
# without depending on a brief line nobody writes.
fm_compact_budget_from_meta() {
  local line
  line=$(grep -m1 -E '^budget=' "$1" 2>/dev/null) || return 0
  fm_compact_budget_from_line "$line"
}

fm_compact_budget_from_line() {
  local num
  num=$(printf '%s' "$1" | tr -d ',' | grep -oE '[0-9]+(\.[0-9]+)?[KkMm]?' | head -1)
  [ -n "$num" ] || return 0
  case $num in
    *.*.*) return 0 ;;
    *.*)
      # A decimal budget would round to a lie; refuse it.
      return 0
      ;;
  esac
  local value=${num%[KkMm]}
  case $num in
    *[Kk]) value=$((value * 1000)) ;;
    *[Mm]) value=$((value * 1000000)) ;;
  esac
  printf '%s\n' "$value"
}

# fm_compact_decide <count> <budget>
# silent:  no budget (the gate never opened) or no compaction yet.
# incident: first compaction - the learnings incident line records it, the
#           story carries on, nobody is woken.
# signal:   second or later compaction - the worker carries straight on and
#           the branch leader is told once per event so it can steer.
fm_compact_decide() {
  local count=$1 budget=$2
  [ -n "$budget" ] && [ "$budget" -gt 0 ] 2>/dev/null || { printf 'silent\n'; return 0; }
  case $count in '' | *[!0-9]* | 0) printf 'silent\n'; return 0 ;; esac
  if [ "$count" -eq 1 ]; then
    printf 'incident\n'
  else
    printf 'signal\n'
  fi
}

# fm_compact_signal_message <id> <count> <largest> [budget]
# The one short line the branch leader is told: which worker compacted, how
# often, and what steering decision that creates. The budget clause is printed
# ONLY for a budget a human wrote into the brief. The machine trigger is never
# named here: a worker compacts AT the trigger, so measuring its peak against
# it says nothing while reading as though it did.
fm_compact_signal_message() {
  local id=$1 count=$2 largest=$3 budget=${4:-} times against=""
  case $count in
    2) times=twice ;;
    *) times="$count times" ;;
  esac
  if [ -n "$budget" ]; then
    against=" against a $budget-token budget"
  fi
  printf '%s compacted %s (peak %s tokens%s) - steer or split the story' \
    "$id" "$times" "$largest" "$against"
}

# fm_compact_count_from_ledger <ledger>
# Fires this machinery itself recorded, one `compacted <n> at <largest>` line
# per event, in ANY session of the story. The story-level floor under the
# current session's boundary count (see below), and the whole count when the
# transcript cannot be read.
#
# The answer is the HIGHEST n the ledger records, not how many lines it holds:
# a story whose earlier compactions were counted from the transcript writes
# `compacted 3` as its first line, and reading that file as "one compaction"
# would report less history than this machinery itself already wrote down. The
# line count is the fallback for a ledger whose lines do not parse.
fm_compact_count_from_ledger() {
  local highest lines
  highest=$(sed -nE 's/^compacted ([0-9]+) at [0-9]+$/\1/p' "$1" 2>/dev/null | sort -n | tail -1)
  case ${highest:-} in
    '' | *[!0-9]*) ;;
    *) printf '%s\n' "$highest"; return 0 ;;
  esac
  lines=$(grep -cE '^compacted [0-9]+ at [0-9]+$' "$1" 2>/dev/null) || true
  printf '%s\n' "${lines:-0}"
}

# fm_compact_scan_transcript <transcript>
# ONE pass over the transcript, answering both questions the hook has about it:
# "<boundary-count> <peak>". A worker's transcript at the compaction trigger
# carries every dropped turn and tool result and is routinely tens of
# megabytes, while the hook runs inside the harness's 60s budget, so the file
# is read once and the arithmetic is done on the small stream jq emits.
#
#   boundary-count  type:"system" subtype:"compact_boundary" rows whose
#                   compactMetadata.trigger is "auto". Every compaction writes
#                   a boundary row whether or not this machinery was installed
#                   when it happened, so the count stays true across sessions
#                   that ran before the gate opened or a missed fire - but a
#                   hand-run /compact is deliberate tidying, not a head that
#                   filled, and must never count toward "this story is too
#                   big". The hook fires on both and cannot tell them apart
#                   from its payload; only the count needs to, and the
#                   harness's own trigger field draws the line.
#   peak            the largest usage row AFTER the last boundary row of ANY
#                   trigger, because a hand-run trim ends the head just as an
#                   automatic one does and the file's all-time maximum belongs
#                   to an earlier head. Sums input + cache_read +
#                   cache_creation; sidechain rows never count.
#
# Prints nothing (empty) when the transcript is missing, or when jq cannot
# parse it - a malformed or half-written file is unreadable, not a session that
# never compacted, and the caller must be able to tell those apart.
fm_compact_scan_transcript() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  local rows rc
  rows=$(jq -r '
    if (.type == "system" and .subtype == "compact_boundary") then
      "b \(input_line_number) \(.compactMetadata.trigger? // "unknown")"
    elif ((.isSidechain != true) and ((.message.usage? // null) != null)) then
      "u \(input_line_number) \(((.message.usage.input_tokens // 0)
          + (.message.usage.cache_read_input_tokens // 0)
          + (.message.usage.cache_creation_input_tokens // 0)))"
    else empty end' "$1" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  printf '%s\n' "$rows" | awk '
    $1 == "b" { last = $2 + 0; if ($3 == "auto") boundaries++; next }
    $1 == "u" { line[++rows] = $2 + 0; tokens[rows] = $3 + 0 }
    END {
      peak = 0
      for (i = 1; i <= rows; i++) {
        if (line[i] > last && tokens[i] > peak) peak = tokens[i]
      }
      printf "%d %d\n", boundaries, peak
    }'
}

# fm_compact_count_from_boundaries <transcript>
# The automatic-compaction count of one scan (see fm_compact_scan_transcript).
# Prints
# nothing when the transcript cannot be read; the caller falls back to the
# ledger.
fm_compact_count_from_boundaries() {
  local scan
  scan=$(fm_compact_scan_transcript "${1:-}")
  [ -n "$scan" ] || return 0
  printf '%s\n' "${scan%% *}"
}

# fm_compact_peak_from_transcript <transcript>
# The peak of one scan (see fm_compact_scan_transcript). A missing, lagging, or
# unreadable transcript - all observed live - reads as peak 0 rather than a
# fabricated number.
fm_compact_peak_from_transcript() {
  local scan
  scan=$(fm_compact_scan_transcript "${1:-}")
  [ -n "$scan" ] || { printf '0\n'; return 0; }
  printf '%s\n' "${scan##* }"
}
