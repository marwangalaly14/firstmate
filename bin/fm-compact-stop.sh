#!/usr/bin/env bash
# PreToolUse hook (matcher ".*"), written by bin/fm-spawn.sh into a claude
# worker's settings.local.json: deny every further tool call once the story
# has compacted twice. One compaction is an incident the worker works through;
# a second means the story cannot fit its window, so the session holds and
# firstmate decides (split the story, or append a `compaction-stop-lifted:`
# line to state/<id>.status to release it - that line is firstmate-owned).
#
# The decision core and the measured trigger law live in bin/fm-compact-lib.sh.
# The ledger counted here is the `compacted <n> at <largest>` line sequence
# owned by bin/fm-compact-spine.sh; this hook writes nothing.
#
# Stdin: the Claude PreToolUse payload; only hook_event_name is checked. Any
# story without a `Budget:` line in its brief, a missing jq, an unreadable
# payload, a missing status file, or the lift line leaves the gate OPEN with a
# silent exit 0: this hook must never be the thing that bricks a worker's tool
# calls on its own breakage. The deny shape is the house PreToolUse deny
# object on stderr (bin/fm-cd-pretool-check.sh owns the shape): exit 2, stdout
# empty, one sentence naming the peak against the budget.
#
# Scoped to claude workers: only the spawn-written claude settings wire this
# hook, so no other harness and no non-worker session can ever hit it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-compact-lib.sh
. "$SCRIPT_DIR/fm-compact-lib.sh"

silent_exit() { exit 0; }

command -v jq >/dev/null 2>&1 || silent_exit

PAYLOAD=$(cat 2>/dev/null) || silent_exit
[ -n "$PAYLOAD" ] || silent_exit
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null) || silent_exit
[ "$EVENT" = "PreToolUse" ] || silent_exit

HOME_ARG=""
ID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || silent_exit; HOME_ARG=$2; shift 2 ;;
    --id) [ $# -ge 2 ] || silent_exit; ID_ARG=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$HOME_ARG" ] && [ -n "$ID_ARG" ] || silent_exit
[ -d "$HOME_ARG/state" ] || silent_exit

BRIEF="$HOME_ARG/data/$ID_ARG/brief.md"
BUDGET=$(fm_compact_budget_from_brief "$BRIEF")
[ -n "$BUDGET" ] || silent_exit

STATUS="$HOME_ARG/state/$ID_ARG.status"

COUNT=$(fm_compact_count_from_status "$STATUS")
PEAK=$(fm_compact_last_largest_from_status "$STATUS")
case $PEAK in '' | *[!0-9]*) PEAK=0 ;; esac

VERDICT=$(fm_compact_decide "$PEAK" "$COUNT" "$BUDGET")
[ "$VERDICT" = "stop" ] || silent_exit
fm_compact_status_has_lift "$STATUS" && silent_exit

REASON=$(fm_compact_hold_sentence "$PEAK" "$BUDGET")
ESCAPED=$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
