#!/usr/bin/env bash
# bin/fm-compact-keep.sh - tell the harness's summarizer what every trim must
# keep, from a claude PreCompact hook.
# Usage: fm-compact-keep.sh  < PreCompact payload (JSON on stdin)
#   Installed by bin/fm-spawn.sh in a claude ship or scout task's worktree
#   .claude/settings.local.json under PreCompact with the matcher auto|manual,
#   so it runs before every trim, the harness's own and a typed /compact alike.
#   It prints the keep-set that bin/fm-compact-lib.sh owns (fm_compact_keep_set)
#   on stdout, which the harness appends to the summarizer's instructions; a
#   typed /compact <focus> keeps its focus and gains the keep-set. The crewmate
#   never sees the text: hook stdout goes to the summary request, not to the
#   session.
#   A payload that is not JSON, is not a PreCompact event, carries a trigger
#   other than auto or manual, or fires inside a subagent (agent_id present)
#   prints nothing. Every path exits 0: a non-zero exit would show as a hook
#   error in the crewmate's session, and a trim without the keep-set is the
#   harness's own default, never a failure of the crewmate's.
# Reads: the payload on stdin (jq). Writes: nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

ok=$(jq -r '
  if type != "object" then empty
  elif .hook_event_name != "PreCompact" then empty
  elif (.trigger | type) != "string" or ((.trigger | IN("auto","manual")) | not) then empty
  elif has("agent_id") and (.agent_id | tostring | length) > 0 then empty
  else "ok" end
' 2>/dev/null) || exit 0
[ "$ok" = ok ] || exit 0

# shellcheck source=bin/fm-compact-lib.sh
. "$SCRIPT_DIR/fm-compact-lib.sh"
fm_compact_keep_set
exit 0
