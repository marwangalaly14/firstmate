#!/usr/bin/env bash
# bin/fm-session-event.sh - record a crewmate's real harness session from a
# claude SessionStart hook payload.
# Usage: fm-session-event.sh <data-dir> <task-id>  < SessionStart payload (JSON on stdin)
#   Installed by bin/fm-spawn.sh in a claude task's worktree
#   .claude/settings.local.json under SessionStart with the matcher
#   startup|resume|clear|fork - every source that begins a transcript, never
#   compact. It appends exactly one tab-separated line to
#   data/<task-id>/sessions.log:
#     <epoch>  <source>  <session_id>  <transcript_path>  <model|?>  <effort|?>
#   The newest line is the live session; the whole file is the task's session
#   history, and teardown leaves data/<task-id>/ alone as it does for report.md.
#   model and effort are what the harness reported in the payload (Claude Code
#   omits model on some starts), so a reader gets ? rather than a guess.
#   A payload that is not JSON, is not a SessionStart event, carries a compact
#   source, lacks session_id or an absolute transcript_path, carries a tab in a
#   recorded field, or fires inside a subagent (agent_id present) appends
#   nothing. Every payload path prints nothing on stdout and exits 0: a
#   SessionStart hook's stdout enters the crewmate's context and a failing hook
#   would show up as a hook error, and neither is the crewmate's concern.
#   Only a missing argument (running it by hand) is refused with usage.
# Reads: the payload on stdin (jq). Writes: data/<task-id>/sessions.log.
set -u

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-session-event.sh <data-dir> <task-id> < SessionStart payload" >&2
  exit 2
fi
DATA=$1
ID=$2
case "$ID" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: '$ID' is not a task id" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

# One jq pass validates the payload and prints the record fields or nothing.
record=$(jq -r '
  if type != "object" then empty
  elif .hook_event_name != "SessionStart" then empty
  elif (.source | type) != "string" or ((.source | IN("startup","resume","clear","fork")) | not) then empty
  elif has("agent_id") and (.agent_id | tostring | length) > 0 then empty
  elif (.session_id | type) != "string" or .session_id == "" then empty
  elif (.transcript_path | type) != "string" or (.transcript_path | startswith("/") | not) then empty
  else
    [ .source, .session_id, .transcript_path,
      (if (.model | type) == "string" and .model != "" then .model else "?" end),
      (if (.effort | type) == "object" and (.effort.level | type) == "string" and .effort.level != "" then .effort.level else "?" end)
    ]
    | if any(.[]; test("[\t\n\r]")) then empty else join("\t") end
  end
' 2>/dev/null) || exit 0
[ -n "$record" ] || exit 0

mkdir -p "$DATA/$ID" 2>/dev/null || exit 0
printf '%s\t%s\n' "$(date +%s)" "$record" >> "$DATA/$ID/sessions.log" 2>/dev/null || exit 0
exit 0
