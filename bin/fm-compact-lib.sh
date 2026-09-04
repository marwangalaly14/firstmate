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
FM_COMPACT_TRIGGER_TOKENS=$((FM_COMPACT_WINDOW_TOKENS - FM_COMPACT_BUFFER_TOKENS))
# Consumed by bin/fm-spawn.sh when it writes the task record's budget= field.
export FM_COMPACT_TRIGGER_TOKENS
# A genuine second compaction must regrow ~120k tokens of context first, so a
# duplicate delivery of the SAME compaction event is any re-fire within this
# many seconds that also claims the same count from the same session.
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

# fm_compact_decide <largest> <count> <budget>
# silent:  no budget (the gate never opened) or no compaction yet.
# incident: first compaction - the learnings incident line records it, the
#           story carries on, nobody is woken.
# signal:   second or later compaction - the worker carries straight on and
#           the branch leader is told once per event so it can steer.
fm_compact_decide() {
  local largest=$1 count=$2 budget=$3
  [ -n "$budget" ] && [ "$budget" -gt 0 ] 2>/dev/null || { printf 'silent\n'; return 0; }
  case $count in '' | *[!0-9]* | 0) printf 'silent\n'; return 0 ;; esac
  if [ "$count" -eq 1 ]; then
    printf 'incident\n'
  else
    printf 'signal\n'
  fi
}

# fm_compact_signal_message <id> <count> <largest> <budget>
# The one short line the branch leader is told: which worker compacted, how
# often, on what budget, and what steering decision that creates.
fm_compact_signal_message() {
  local id=$1 count=$2 largest=$3 budget=$4 times
  case $count in
    2) times=twice ;;
    *) times="$count times" ;;
  esac
  printf '%s compacted %s (peak %s tokens against a %s-token budget) - steer or split the story' \
    "$id" "$times" "$largest" "$budget"
}

# fm_compact_count_from_ledger <ledger>
# Fires this machinery itself recorded, one `compacted <n> at <largest>` line
# per event. The fallback count for a transcript that cannot be read; the
# transcript's boundary rows are the primary count (see below).
fm_compact_count_from_ledger() {
  local n
  n=$(grep -cE '^compacted [0-9]+ at [0-9]+$' "$1" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

# fm_compact_count_from_boundaries <transcript>
# How many times this session has compacted, counted from the transcript's
# own type:"system" subtype:"compact_boundary" rows. Every compaction writes
# one whether or not this machinery was installed when it happened, so the
# count stays true across sessions that ran before the gate opened or through
# a missed fire. Prints nothing (empty) when the transcript cannot be read;
# the caller falls back to the ledger.
fm_compact_count_from_boundaries() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  local n
  n=$(jq -r 'select(.type == "system" and .subtype == "compact_boundary") | 1' "$1" 2>/dev/null | grep -c .)
  printf '%s\n' "${n:-0}"
}

# fm_compact_peak_from_transcript <transcript>
# The peak context of the compaction that just fired: the largest usage row
# AFTER the transcript's last compact_boundary, because the file's all-time
# maximum belongs to an earlier head once the session has compacted before.
# Sums input + cache_read + cache_creation; sidechain rows are skipped. A
# missing, lagging, or unreadable transcript - all observed live - reads as
# peak 0 rather than a fabricated number.
fm_compact_peak_from_transcript() {
  local path=$1 start peak
  [ -n "$path" ] && [ -f "$path" ] || { printf '0\n'; return 0; }
  # input_line_number on a JSONL transcript is exact: find the last boundary
  # row's line, slice the FILE from after it (so the line numbers align), then
  # read the usage rows of that slice only.
  start=$(jq -r 'select(.type == "system" and .subtype == "compact_boundary") | input_line_number' "$path" 2>/dev/null | tail -1)
  case ${start:-} in '' | *[!0-9]*) start=0 ;; esac
  if [ "$start" -gt 0 ]; then
    peak=$(tail -n +"$((start + 1))" -- "$path" \
      | jq -r 'select(.isSidechain != true) | .message.usage? | select(. != null) |
               ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))' 2>/dev/null \
      | sort -n | tail -1)
  else
    peak=$(jq -r 'select(.isSidechain != true) | .message.usage? | select(. != null) |
                  ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))' \
            "$path" 2>/dev/null | sort -n | tail -1)
  fi
  printf '%s\n' "${peak:-0}"
}
