#!/usr/bin/env bash
# bin/fm-trim-event.sh - record every trim of a crewmate's context from a
# claude PostCompact hook and, from the second automatic trim on, tell whoever
# leads the crewmate.
# Usage: fm-trim-event.sh <home> <task-id>  < PostCompact payload (JSON on stdin)
#   <home> is the firstmate home the spawn ran under (its state/ and data/).
#   Installed by bin/fm-spawn.sh in a claude ship or scout task's worktree
#   .claude/settings.local.json under PostCompact with the matcher auto|manual,
#   leaders included, so it runs after every trim, the harness's own and a
#   typed /compact alike. The crewmate is never told: the hook prints nothing,
#   and the harness shows its stdout to nobody but the terminal.
#
#   What it reads: the payload's trigger, session_id, transcript_path and
#   compact_summary; the transcript the payload names (the last assistant
#   usage row is the head before this trim - the harness appends this trim's
#   own compact_boundary row only after the hook returns, so the rows visible
#   here are earlier trims'); data/<task-id>/trims/index, its own ledger;
#   state/<task-id>.meta's leader= line (written by bin/fm-spawn.sh --leader)
#   and trim_mark= line (written by the spawn for a story crewmate); and the
#   leader's own record for the presence read bin/fm-lead-lib.sh owns.
#
#   What it writes:
#     data/<task-id>/trims/<n>.md   one record per trim: trigger, time, session,
#                                   transcript, head before the trim, the count
#                                   of automatic trims so far, who was told, and
#                                   the summary the harness wrote, verbatim.
#     data/<task-id>/trims/index    one line per trim:
#                                   <n> <trigger> <epoch> <head|?> <told> [ordered:<leader>]
#                                   (tab-separated; told is leader:<id>,
#                                   firstmate, or -; the sixth field marks a
#                                   manual trim the leader ordered), and, after
#                                   a carry-on nudge that did not record,
#                                   `steer-failed <epoch> <leader>`.
#   The index also carries the leader's orders, written by bin/fm-lead.sh
#   trim before it types /compact: `ordered <epoch> <leader> <focus|->`, and
#   `order-failed <epoch>` when the /compact provably did not reach the pane.
#   A manual trim whose nearest earlier ledger line is a pending `ordered`
#   line is the leader's: its record says `- ordered by: leader <id> ...` and
#   its index line ends in ordered:<leader>; any other manual trim says
#   `- ordered by: nobody in the ledger`. Order lines are never counted as
#   trims.
#
#   The carry-on nudge, on a manual trim the leader ordered and on no other
#   trim: this hook fires only once the compaction has finished, and the
#   pending order names who asked for it, so the nudge is sent from here and
#   nothing anywhere has to wait for the trim to end. One line goes into the
#   crewmate's OWN steering inbox through bin/fm-send.sh, marked from the
#   leader that ordered it - `trim done - continue: <focus>`, or `trim done -
#   continue with your task card` when the order carried no focus. That is an
#   append at a trim, so the law of the head holds. The pending order is
#   one-shot, and it is spent BEFORE the nudge is attempted: this trim's own
#   ledger line is appended first, so a later /compact the crewmate types
#   itself can never be nudged by it, however the send or this process ends. A
#   send that does not record fails nothing: the hook still exits 0 and prints
#   nothing, the trim record's told line names the failure, and a
#   `steer-failed <epoch> <leader>` line goes into the ledger beside it, the
#   same visible shape a failed order already takes. `steer-failed` is not a
#   trim and never clears or counts as one.
#   <n> counts every trim of the task, manual ones included. The automatic
#   count N is 1 + max(automatic lines already in the index, earlier automatic
#   compact_boundary rows in the transcript), so a ledger that missed a trim
#   or a transcript that started over still counts what actually happened. A
#   boundary row with no request after it is this trim's own (a harness that
#   appends the row before the hook), not an earlier one. A manual trim is
#   recorded and never counted.
#
#   Who is told, on an automatic trim with N >= 2 (and nobody otherwise):
#     - the leader named by leader=, when bin/fm-lead-lib.sh reads its endpoint
#       as alive: one line into the leader's steering inbox through
#       bin/fm-send.sh (the durable record plus the doorbell), the leader's
#       ordinary channel, so it can steer or split the story;
#     - otherwise (no leader, a dead or unreadable leader, or a send that did
#       not record) First Mate, through one durable `signal` wake keyed
#       trim:<task-id> (bin/fm-wake-lib.sh's fm_wake_append), the same queue
#       the watcher presents.
#   The line names the crewmate, the count, the head before the trim and the
#   trim line when the task has one, and where the summary is. It is a
#   measurement for the reader to act on; nothing here stops, warns, or
#   throttles the crewmate.
#
#   A payload that is not JSON, is not a PostCompact event, carries a trigger
#   other than auto or manual, or fires inside a subagent (agent_id present)
#   writes nothing and tells nobody. Every payload path prints nothing on
#   stdout and exits 0: a failing hook would show up as a hook error in the
#   crewmate's session, which is not the crewmate's concern. Only a missing
#   argument (running it by hand) is refused with usage.
# Reads: the payload on stdin (jq), the transcript it names, state/<id>.meta,
# data/<task-id>/trims/index.
# Writes: data/<task-id>/trims/; the leader's inbox or the wake queue; the
# crewmate's own inbox, for the carry-on nudge after a leader-ordered trim.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-trim-event.sh <home> <task-id> < PostCompact payload" >&2
  exit 2
fi
FM_HOME=$1
ID=$2
case "$ID" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: '$ID' is not a task id" >&2; exit 2 ;;
esac
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# One jq pass validates the payload and prints trigger, session and transcript.
fields=$(printf '%s' "$payload" | jq -r '
  if type != "object" then empty
  elif .hook_event_name != "PostCompact" then empty
  elif (.trigger | type) != "string" or ((.trigger | IN("auto","manual")) | not) then empty
  elif has("agent_id") and (.agent_id | tostring | length) > 0 then empty
  else
    [ .trigger,
      (if (.session_id | type) == "string" and .session_id != "" then .session_id else "?" end),
      (if (.transcript_path | type) == "string" and (.transcript_path | startswith("/")) then .transcript_path else "" end)
    ] | map(gsub("[\t\n\r]"; " ")) | join("\t")
  end
' 2>/dev/null) || exit 0
[ -n "$fields" ] || exit 0
IFS=$(printf '\t') read -r TRIGGER SESSION TRANSCRIPT <<EOF
$fields
EOF
SUMMARY=$(printf '%s' "$payload" | jq -r '
  if (.compact_summary | type) == "string" then .compact_summary else "" end' 2>/dev/null) || SUMMARY=

# --- the transcript: head before this trim, earlier automatic trims ----------
HEAD='?'
AUTO_ROWS=0
PENDING_AUTO=0
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  read_out=$(jq -R -n -r '
    def total(u): ((u.input_tokens // 0) + (u.cache_creation_input_tokens // 0)
      + (u.cache_read_input_tokens // 0) + (u.output_tokens // 0));
    reduce (inputs | fromjson? // empty) as $r ({head: null, auto: 0, pending: 0};
      if ($r.isSidechain // false) == true then .
      elif $r.type == "assistant" and ($r.message.usage | type) == "object" then
        .head = total($r.message.usage) | .pending = 0
      elif $r.type == "system" and $r.subtype == "compact_boundary" then
        if $r.compactMetadata.trigger == "auto" then .auto += 1 | .pending = 1 else .pending = 0 end
      else . end)
    | "\(.head // "?")\t\(.auto)\t\(.pending)"' "$TRANSCRIPT" 2>/dev/null) || read_out=
  if [ -n "$read_out" ]; then
    IFS=$(printf '\t') read -r HEAD AUTO_ROWS PENDING_AUTO <<EOF
$read_out
EOF
  fi
fi
case "$HEAD" in ''|*[!0-9]*) HEAD='?' ;; esac
case "$AUTO_ROWS" in ''|*[!0-9]*) AUTO_ROWS=0 ;; esac
case "${PENDING_AUTO:-0}" in 1) PENDING_AUTO=1 ;; *) PENDING_AUTO=0 ;; esac

k_of() {  # <tokens|?> -> 138K | 3.1K | 512 | ?
  case "$1" in
    ''|*[!0-9]*) printf '?' ;;
    *) if [ "$1" -ge 10000 ]; then printf '%dK' $(( ($1 + 500) / 1000 ))
       elif [ "$1" -ge 1000 ]; then printf '%d.%dK' $(( $1 / 1000 )) $(( ($1 % 1000) / 100 ))
       else printf '%d' "$1"; fi ;;
  esac
}

# --- the ledger: this trim's number and the automatic count ------------------
TRIMS="$DATA/$ID/trims"
INDEX="$TRIMS/index"
mkdir -p "$TRIMS" 2>/dev/null || exit 0
last_n=0
auto_index=0
# A pending order: the ledger's last line is an `ordered <epoch> <leader>
# <focus>` line bin/fm-lead.sh trim wrote before typing /compact (an
# `order-failed` line or a trim line after it clears it).
ORDER_LEADER=
ORDER_EPOCH=
ORDER_FOCUS=
if [ -f "$INDEX" ]; then
  while IFS=$(printf '\t') read -r n trig f3 f4 _rest; do
    case "$n" in
      ordered) ORDER_EPOCH=$trig; ORDER_LEADER=$f3; ORDER_FOCUS=$f4; continue ;;
      order-failed) ORDER_LEADER=; ORDER_EPOCH=; ORDER_FOCUS=; continue ;;
      ''|*[!0-9]*) continue ;;
    esac
    ORDER_LEADER=; ORDER_EPOCH=; ORDER_FOCUS=
    [ "$n" -gt "$last_n" ] && last_n=$n
    [ "$trig" = auto ] && auto_index=$((auto_index + 1))
  done < "$INDEX"
fi
for f in "$TRIMS"/[0-9]*.md; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .md)
  case "$n" in ''|*[!0-9]*) continue ;; esac
  [ "$n" -gt "$last_n" ] && last_n=$n
done
N=$((last_n + 1))
# Earlier automatic trims: the ledger's or the transcript's, whichever saw
# more. A trailing auto boundary row with no request after it is this trim's.
earlier=$AUTO_ROWS
if [ "$TRIGGER" = auto ] && [ "$PENDING_AUTO" -eq 1 ] && [ "$earlier" -gt 0 ]; then
  earlier=$((earlier - 1))
fi
[ "$auto_index" -gt "$earlier" ] && earlier=$auto_index
if [ "$TRIGGER" = auto ]; then
  N_AUTO=$((earlier + 1))
else
  N_AUTO=$earlier
fi

EPOCH=$(date +%s)
WHEN=$(date -u -r "$EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u +%Y-%m-%dT%H:%M:%SZ)
META="$STATE/$ID.meta"
MARK=
LEADER=
if [ -f "$META" ]; then
  MARK=$(sed -n 's/^trim_mark=//p' "$META" | head -1)
  LEADER=$(sed -n 's/^leader=//p' "$META" | head -1)
fi
case "$MARK" in ''|*[!0-9]*) MARK= ;; esac

write_record() {  # <told line>
  local tmp="$TRIMS/.$N.$$.tmp"
  {
    printf '# Trim %s: %s\n\n' "$N" "$ID"
    printf -- '- trigger: %s\n' "$TRIGGER"
    printf -- '- time: %s (epoch %s)\n' "$WHEN" "$EPOCH"
    printf -- '- session: %s\n' "$SESSION"
    printf -- '- transcript: %s\n' "${TRANSCRIPT:-?}"
    if [ "$HEAD" = '?' ]; then
      printf -- '- head before the trim: ? (no readable transcript)\n'
    else
      printf -- '- head before the trim: %s (%s tokens, the last request in the transcript)\n' "$(k_of "$HEAD")" "$HEAD"
    fi
    [ -z "$MARK" ] || printf -- '- trim line: %s\n' "$(k_of "$MARK")"
    printf -- '- automatic trims so far: %s\n' "$N_AUTO"
    if [ "$TRIGGER" = manual ]; then
      if [ -n "$ORDER_LEADER" ]; then
        printf -- '- ordered by: leader %s (order at epoch %s, focus: %s)\n' "$ORDER_LEADER" "$ORDER_EPOCH" "$ORDER_FOCUS"
      else
        printf -- '- ordered by: nobody in the ledger (a typed /compact without a leader order)\n'
      fi
    fi
    printf -- '- told: %s\n' "$1"
    printf '\n## Summary\n\n%s\n' "$SUMMARY"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$TRIMS/$N.md" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# The record first, so a notification that hangs or fails still leaves it.
write_record "(pending)" || exit 0

# --- who is told --------------------------------------------------------------
TOLD='-'
TOLD_LINE='nobody (manual trim)'
if [ "$TRIGGER" = auto ] && [ "$N_AUTO" -lt 2 ]; then
  TOLD_LINE='nobody (first automatic trim)'
fi
if [ "$TRIGGER" = auto ] && [ "$N_AUTO" -ge 2 ]; then
  nth="${N_AUTO}th"
  case "$N_AUTO" in 2) nth=2nd ;; 3) nth=3rd ;; esac
  head_words="head $(k_of "$HEAD") before it"
  [ -z "$MARK" ] || head_words="$head_words, line $(k_of "$MARK")"
  where="$TRIMS/$N.md"
  line="$ID trimmed its context for the $nth time ($head_words) - steer or split the story; summary in $where"
  sent=0
  leader_state=none
  if [ -n "$LEADER" ] && [ -f "$STATE/$LEADER.meta" ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    # shellcheck source=bin/fm-lead-lib.sh
    . "$SCRIPT_DIR/fm-lead-lib.sh"
    leader_state=$(fm_lead_endpoint_state "$STATE/$LEADER.meta" "$LEADER" 2>/dev/null) || leader_state=unknown
    if [ "$leader_state" = alive ]; then
      if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$LEADER" "trim event: $line" >/dev/null 2>&1; then
        sent=1
        TOLD="leader:$LEADER"
        TOLD_LINE="leader $LEADER (steering inbox)"
      else
        leader_state='send failed'
      fi
    fi
  elif [ -n "$LEADER" ]; then
    leader_state='no record'
  fi
  if [ "$sent" -ne 1 ]; then
    why="no leader"
    [ -z "$LEADER" ] || why="leader $LEADER $leader_state"
    (
      export FM_HOME STATE
      # shellcheck source=bin/fm-wake-lib.sh
      . "$SCRIPT_DIR/fm-wake-lib.sh"
      fm_wake_append signal "trim:$ID" "$line ($why)"
    ) >/dev/null 2>&1 && { TOLD=firstmate; TOLD_LINE="First Mate (signal wake; $why)"; } \
      || TOLD_LINE="nobody ($why; the wake could not be queued)"
  fi
fi

write_record "$TOLD_LINE" || true
ORDERED=
[ "$TRIGGER" = manual ] && [ -n "$ORDER_LEADER" ] && ORDERED="ordered:$ORDER_LEADER"
printf '%s\t%s\t%s\t%s\t%s%s\n' "$N" "$TRIGGER" "$EPOCH" "$HEAD" "$TOLD" "${ORDERED:+$(printf '\t%s' "$ORDERED")}" >> "$INDEX" 2>/dev/null || true

# The order is spent the moment the line above exists, so the nudge is sent
# only after it: whatever happens to this process now, no later trim can be
# nudged by this order.
if [ "$TRIGGER" = manual ] && [ -n "$ORDER_LEADER" ]; then
  case "$ORDER_FOCUS" in
    ''|-) CONTINUE='trim done - continue with your task card' ;;
    *) CONTINUE="trim done - continue: $ORDER_FOCUS" ;;
  esac
  # shellcheck disable=SC2031  # FM_HOME is this script's own argument, never a subshell's
  if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" --from-leader "$ORDER_LEADER" "$CONTINUE" >/dev/null 2>&1; then
    TOLD_LINE="$ID itself (carry-on steer from leader $ORDER_LEADER)"
  else
    TOLD_LINE="nobody (the carry-on steer from leader $ORDER_LEADER did not reach $ID)"
    printf 'steer-failed\t%s\t%s\n' "$(date +%s)" "$ORDER_LEADER" >> "$INDEX" 2>/dev/null || true
  fi
  write_record "$TOLD_LINE" || true
fi
exit 0
