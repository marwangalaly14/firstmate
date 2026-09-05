#!/usr/bin/env bash
# bin/fm-task-card.sh - reprint a crewmate's own task card into its context
# when a trimmed session resumes, from a claude SessionStart hook.
# Usage: fm-task-card.sh <home> <task-id>  < SessionStart payload (JSON on stdin)
#   <home> is the firstmate home the spawn ran under (its state/ and data/).
#   Installed by bin/fm-spawn.sh in a claude ship or scout task's worktree
#   .claude/settings.local.json under SessionStart with the matcher compact,
#   leaders included: the harness runs it once when a session resumes after a
#   trim, and its stdout enters the crewmate's context beside the summary.
#   It prints, in this order and verbatim, what a summary paraphrases:
#     - the brief's `## Captain's intent` section (the story and its
#       acceptance list) and its `# Definition of done` section, from
#       data/<task-id>/brief.md (written by bin/fm-brief.sh and First Mate or
#       the leader);
#     - data/<task-id>/logbook.md, the crewmate's own Done, Next, Open and
#       Decisions (bin/fm-logbook-lib.sh creates it at launch);
#     - how many steering-inbox records wait unread in state/<task-id>.inbox/
#       (written by bin/fm-send.sh) and the exact line that drains them;
#     - the last line of state/<task-id>.status, the crewmate's last word to
#       its supervisor.
#   Each section is cut at a fixed size with a note naming the file, so the
#   whole card stays under about two thousand tokens (FM_TASK_CARD_MAX
#   characters in all). A missing brief, logbook, inbox or status line is
#   named as missing, never invented. The card says nothing about why it is
#   being shown: it is the crewmate's own material, and nothing here stops,
#   warns or measures anything.
#   A payload that is not JSON, is not a SessionStart event, carries a source
#   other than compact, or fires inside a subagent (agent_id present) prints
#   nothing. Every path exits 0: a non-zero exit would show as a hook error in
#   the crewmate's session. Only a missing argument (running it by hand) is
#   refused with usage.
# Reads: the payload on stdin (jq), data/<id>/brief.md, data/<id>/logbook.md,
#   state/<id>.inbox/, state/<id>.status. Writes: nothing.
set -u

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-task-card.sh <home> <task-id> < SessionStart payload" >&2
  exit 2
fi
FM_HOME=$1
ID=$2
case "$ID" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: '$ID' is not a task id" >&2; exit 2 ;;
esac
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"

# Section caps in characters; the sum plus the framing stays under
# FM_TASK_CARD_MAX, about two thousand tokens.
FM_TASK_CARD_MAX=${FM_TASK_CARD_MAX:-8000}
CAP_INTENT=3000
CAP_DOD=2000
CAP_LOGBOOK=2000
CAP_STATUS=300

command -v jq >/dev/null 2>&1 || exit 0

ok=$(jq -r '
  if type != "object" then empty
  elif .hook_event_name != "SessionStart" then empty
  elif .source != "compact" then empty
  elif has("agent_id") and (.agent_id | tostring | length) > 0 then empty
  else "ok" end
' 2>/dev/null) || exit 0
[ "$ok" = ok ] || exit 0

BRIEF="$DATA/$ID/brief.md"
INTENT_HEADING="## Captain's intent"
LOGBOOK="$DATA/$ID/logbook.md"
INBOX="$STATE/$ID.inbox"
STATUS="$STATE/$ID.status"

# section <file> <heading-line>: the body under that exact heading line, up to
# the next heading of the same or a higher level.
section() {
  local file=$1 heading=$2 level
  level=${heading%% *}
  awk -v h="$heading" -v lvl="${#level}" '
    function hlevel(line,   n) { n = 0; while (substr(line, n + 1, 1) == "#") n++; return n }
    found && /^#/ { l = hlevel($0); if (l > 0 && l <= lvl) exit }
    found { print }
    $0 == h { found = 1 }
  ' "$file"
}

# cut <text> <cap> <file>: the text, or its first <cap> characters and a note.
cut_at() {
  local text=$1 cap=$2 file=$3
  if [ "${#text}" -le "$cap" ]; then
    printf '%s\n' "$text"
  else
    printf '%s\n' "${text:0:$cap}"
    printf '(cut at %s characters; the rest is in %s)\n' "$cap" "$file"
  fi
}

card=$(
  printf '# Task %s: where things stand\n' "$ID"
  if [ -f "$BRIEF" ]; then
    intent=$(section "$BRIEF" "$INTENT_HEADING")
    if [ -n "$intent" ]; then
      printf '\n## What was asked, from your brief (%s)\n' "$BRIEF"
      cut_at "$intent" "$CAP_INTENT" "$BRIEF"
    fi
    dod=$(section "$BRIEF" "# Definition of done")
    if [ -n "$dod" ]; then
      printf '\n## Definition of done, from your brief\n'
      cut_at "$dod" "$CAP_DOD" "$BRIEF"
    fi
    if [ -z "$intent" ] && [ -z "$dod" ]; then
      printf '\n## Your brief\n%s carries no %s or Definition of done section; read it whole.\n' "$BRIEF" "${INTENT_HEADING#\#\# }"
    fi
  else
    printf '\n## Your brief\nNo brief at %s.\n' "$BRIEF"
  fi
  printf '\n## Your logbook (%s)\n' "$LOGBOOK"
  if [ -f "$LOGBOOK" ]; then
    cut_at "$(cat "$LOGBOOK")" "$CAP_LOGBOOK" "$LOGBOOK"
  else
    printf 'No logbook yet at %s.\n' "$LOGBOOK"
  fi
  printf '\n## Instructions waiting\n'
  waiting=0
  if [ -d "$INBOX" ]; then
    for f in "$INBOX"/*.msg; do
      [ -f "$f" ] && waiting=$((waiting + 1))
    done
  fi
  if [ "$waiting" -gt 0 ]; then
    printf '%s unread: list %s/*.msg and, in numeric order, read and act on each, then mv each handled file to %s/handled/.\n' "$waiting" "$INBOX" "$INBOX"
  else
    printf 'None.\n'
  fi
  printf '\n## Your last status line\n'
  if [ -s "$STATUS" ]; then
    cut_at "$(tail -n 1 "$STATUS")" "$CAP_STATUS" "$STATUS"
  else
    printf 'None yet.\n'
  fi
)
if [ "${#card}" -gt "$FM_TASK_CARD_MAX" ]; then
  card="${card:0:$FM_TASK_CARD_MAX}
(card cut at $FM_TASK_CARD_MAX characters)"
fi
printf '%s\n' "$card"
exit 0
