# shellcheck shell=bash
# Pure decision core for worker auto-compaction (AGENTS.md section 7's
# crewmates-compact-at-120k story). Sourced by bin/fm-compact-spine.sh,
# bin/fm-compact-stop.sh, and tests/token-budget.test.sh; no I/O of its own
# beyond reading the files its callers name.
#
# THE MEASURED TRIGGER LAW (claude 2.1.259, measured on a live interactive TUI
# on this machine, 2026-09-04; see the task report for the full rehearsal):
# auto-compaction fires when the session's context reaches
# autoCompactWindow - 33000 tokens. The 33k "Autocompact buffer" is flat, not a
# ratio: verified at window 120000 -> fired at 87000, window 153000 -> fired at
# exactly 120000, window 200000 -> fired at 167000. Therefore the window that
# triggers compaction at exactly 120000 tokens is 153000, and that is what
# bin/fm-spawn.sh writes into each claude worker worktree's
# .claude/settings.local.json as autoCompactWindow. Headless `claude -p`
# sessions never auto-compact at all, so the setting changes nothing for them.
# Project-local settings beat user settings, so the captain's own sessions
# (window 500000 in the user settings) are untouched.
#
# THE DECISION, owned here and nowhere else:
#   count 0 -> silent   (the 140k-and-under world is unchanged)
#   count 1 -> incident (one line in data/learnings.md naming story and peak)
#   count >= 2 -> stop  (the PreToolUse hook denies further tool calls)
# A budget of 0 or absent means the brief carried no Budget line, and the whole
# machinery stays silent: the gate is the brief, not the ledger. The largest
# context never changes the decision - it is reportable evidence only.
set -u

# The measured window written at spawn (see the law above).
FM_COMPACT_WINDOW_TOKENS=153000

# Duplicate-fire dedup window in seconds. One compaction event can reach this
# hook twice: the tracked .claude/settings.json entry and the spawn-written
# settings.local.json entry merge into the same session and their command
# strings differ, so both run. The two fires land within a couple of seconds of
# each other; a GENUINE second compaction cannot, because it requires the
# session to regrow ~120k tokens of context first.
FM_COMPACT_DEDUP_WINDOW=15

# fm_compact_budget_from_brief <brief-path>: echo the story's budget in tokens,
# or nothing when the brief has no parseable `Budget:` line. Line-anchored on
# the Budget: prefix so a number elsewhere in the brief never parses. K/k
# multiplies by 1000, M/m by 1000000, commas are stripped. A decimal number
# (1.2M) parses to NOTHING rather than to a wrong integer.
fm_compact_budget_from_brief() {
  local brief=$1 line rest tok num suf
  [ -n "$brief" ] && [ -f "$brief" ] || return 0
  line=$(grep -m1 -E '^[[:space:]]*Budget:' "$brief" 2>/dev/null) || return 0
  rest=${line#*:}
  rest=${rest//,/}
  tok=$(printf '%s' "$rest" | grep -oE '[0-9]+(\.[0-9]+)?[KkMm]?' | head -1) || return 0
  [ -n "$tok" ] || return 0
  case $tok in *.*) return 0 ;; esac
  num=${tok//[!0-9]/}
  [ -n "$num" ] || return 0
  suf=${tok##*[0-9]}
  case $suf in
    K | k) num=$((num * 1000)) ;;
    M | m) num=$((num * 1000000)) ;;
  esac
  printf '%s\n' "$num"
}

# fm_compact_decide <largest> <count> <budget>: echo silent|incident|stop.
# Junk numerics read as 0, so malformed input can neither fabricate nor evade
# a verdict: a junk peak still stops at count 2, and a junk count cannot
# reach it.
fm_compact_decide() {
  local largest=$1 count=$2 budget=$3
  case $largest in '' | *[!0-9]*) largest=0 ;; esac
  case $count in '' | *[!0-9]*) count=0 ;; esac
  case $budget in '' | *[!0-9]*) budget=0 ;; esac
  [ "$budget" -gt 0 ] || { printf 'silent\n'; return 0; }
  [ "$count" -ge 1 ] || { printf 'silent\n'; return 0; }
  [ "$count" -ge 2 ] && { printf 'stop\n'; return 0; }
  printf 'incident\n'
}

# fm_compact_hold_sentence <largest> <budget>: the one sentence the stop hook
# shows the worker and the spine prints at the second compaction.
fm_compact_hold_sentence() {
  printf 'This story compacted twice (peak %s tokens against a %s-token budget): stop and hold - further tool calls will be denied until firstmate splits the story or explicitly lifts the stop.\n' "$1" "$2"
}

# fm_compact_count_from_status <status-file>: how many ledger lines the story
# has. A ledger line is exactly `compacted <n> at <largest>`; trailing prose
# makes it prose, not a ledger line, because these hooks are their only writer.
fm_compact_count_from_status() {
  local file=$1 n
  [ -n "$file" ] && [ -f "$file" ] || { printf '0\n'; return 0; }
  # grep -c prints 0 (exit 1) on no match; capture rather than fall back, or
  # the miss case would print two zeros.
  n=$(grep -cE '^compacted [0-9]+ at [0-9]+$' "$file" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

# fm_compact_last_largest_from_status <status-file>: the peak from the most
# recent ledger line, or nothing when the ledger is empty.
fm_compact_last_largest_from_status() {
  local file=$1
  [ -n "$file" ] && [ -f "$file" ] || return 0
  grep -E '^compacted [0-9]+ at [0-9]+$' "$file" 2>/dev/null | tail -1 | awk '{print $4}'
  return 0
}

# fm_compact_status_has_lift <status-file>: exit 0 when the status file carries
# a firstmate-written `compaction-stop-lifted:` line releasing the stop.
fm_compact_status_has_lift() {
  local file=$1
  [ -n "$file" ] && [ -f "$file" ] || return 1
  grep -q '^compaction-stop-lifted:' "$file" 2>/dev/null
}
