#!/usr/bin/env bash
# bin/fm-crew-signals.sh - ring a led crewmate's leader once per episode when
# the crewmate's transcript shows a stall, a loop or a drift candidate.
# Usage: fm-crew-signals.sh <home> <task-id>
#
# Everything here is read from the crewmate's card (bin/fm-crew-vitals.sh
# --json: the transcript the harness writes every turn, the worktree's HEAD
# time, the logbook's modified time) and nothing from what the crewmate
# writes, says or reports. The logbook enters only as "changed or not"; its
# words never do. Three signals, each with a signature that names its episode:
#   stall   the crewmate is busy (the transcript's last conversation row is a
#           tool call in flight, or a prompt or tool result the model has not
#           answered) and nothing new has been written for FM_STUCK_CALL_SECS
#           (900): stuck in one call or wedged. Signature: when the quiet began.
#   loop    the card's repeats field: the same tool with the same input three
#           or more times in the last 30 calls, the same file read five or
#           more times, or an A-B-A-B alternation four times. Signature: the
#           repeat's kind and subject (its count may grow; that is the same
#           episode).
#   drift?  FM_DRIFT_TOKENS (40,000) spent since the last commit with no
#           logbook change over that spend (the logbook missing or untouched,
#           or as much spent since its last change). A candidate, never a
#           verdict: the leader confirms it against the acceptance criteria.
#           Signature: the commit and the logbook change it measures from.
# Each signal rings the leader named by state/<task-id>.meta's leader= line
# once per episode: the ledger data/<task-id>/signals/index takes one row per
# signal and signature -
#   <epoch>\t<signal>\t<signature>\t<rung|failed:<why>>\t<leader>\t<summary>
# - and a signal whose row exists is silent (why: leader-dead, leader-unknown,
# leader-no-record, send; a failed ring is recorded once too, so a dead leader
# is never hammered and First Mate is not woken for it: it learns of a dead
# leader through its own liveness paths, the leader being a task). The ring is
# one bin/fm-send.sh record on the leader's steering inbox: the signal line,
# the crewmate's card, and how to steer. The leader's endpoint is read with
# bin/fm-lead-lib.sh (fm_lead_endpoint_state) before any send. A crewmate
# with no leader= line never rings and gets no ledger.
# Who runs it: bin/fm-watch.sh, for every led crewmate once per
# FM_SIGNAL_CHECK_SECS (300); a leader may run it by hand. Prints one line
# per signal on stdout - <signal>\t<rung|silent|failed:<why>>\t<summary> -
# and nothing when the transcript shows none. Nothing here stops, warns or
# throttles the crewmate, and nothing reaches it.
# Limits, stated plainly: an interrupted turn leaves no finished-turn row, so
# an idle crewmate interrupted mid-call reads as busy and can ring one stall;
# a foreground command that legitimately runs past the bound rings once too;
# the leader judges from the card. A transcript the harness has not begun
# (no data/<task-id>/sessions.log) yields no signal.
# Exit: 0 on every path once the arguments are valid; 2 on usage. Errors go
# to stderr. FM_STATE_OVERRIDE and FM_DATA_OVERRIDE point the directories
# elsewhere for tests, exactly as for the card; FM_VITALS_NOW fixes its clock.
# Reads: state/<task-id>.meta, state/<leader>.meta, the card's inputs,
# data/<task-id>/signals/index. Writes: data/<task-id>/signals/{index,.lock};
# the leader's inbox.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-crew-signals.sh <home> <task-id>" >&2
  exit 2
fi
FM_HOME=$1
ID=$2
case "$ID" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: '$ID' is not a task id" >&2; exit 2 ;;
esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
META="$STATE/$ID.meta"
STUCK_SECS=${FM_STUCK_CALL_SECS:-900}
case "$STUCK_SECS" in ''|*[!0-9]*) STUCK_SECS=900 ;; esac
DRIFT_TOKENS=${FM_DRIFT_TOKENS:-40000}
case "$DRIFT_TOKENS" in ''|*[!0-9]*) DRIFT_TOKENS=40000 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

[ -f "$META" ] || exit 0
LEADER=$(fm_meta_get "$META" leader 2>/dev/null) || LEADER=
[ -n "$LEADER" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo "error: jq is required to read a card" >&2; exit 0; }

card=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-vitals.sh" "$ID" --json 2>/dev/null) || card=
[ -n "$card" ] || exit 0

# The three readings, as <signal>\t<signature>\t<summary> lines; the shell
# only records and rings.
signals=$(printf '%s' "$card" | jq -r --argjson stuck "$STUCK_SECS" --argjson drift "$DRIFT_TOKENS" '
  # The card'"'"'s own number and age shapes (k_of, age_of in bin/fm-crew-vitals.sh).
  def k: if . == null then "?"
    elif . >= 9950 then ((((. + 500) / 1000) | floor | tostring) + "K")
    elif . >= 1000 then (((. + 50) / 100 | floor) as $h | (($h / 10 | floor) | tostring) + "." + (($h % 10) | tostring) + "K")
    else tostring end;
  def age: if . == null then "?" else (if . < 0 then 0 else . end) as $d
    | if $d < 90 then ($d | tostring) + "s"
      elif $d < 5400 then ((($d + 30) / 60 | floor | tostring) + "m")
      elif $d < 172800 then ((($d + 1800) / 3600 | floor | tostring) + "h")
      else ((($d + 43200) / 86400 | floor | tostring) + "d") end end;
  [
    (if .busy == true and .quiet_for != null and .quiet_for >= $stuck then
       "stall\t" + ((.now - .quiet_for) | tostring) + "\tbusy with nothing new for " + (.quiet_for | age)
       + " (bound " + ($stuck | age) + "); last call " + (.last_call.name // "?") + " `" + (.last_call.short // "") + "`"
     else empty end),
    (if .repeats != null and .repeats.kind != "none" and .repeats.kind != "?" then
       "loop\t" + .repeats.kind + " " + .repeats.what + "\t" + .repeats.kind + " " + (.repeats.n | tostring) + "x " + .repeats.what + " in the last 30 calls"
     else empty end),
    (if .spend_since_commit != null and .spend_since_commit >= $drift
        and (.logbook != "written" or (.spend_since_logbook != null and .spend_since_logbook >= $drift)) then
       "drift?\t" + ((.commit_epoch // 0) | tostring) + "/" + ((.logbook_epoch // 0) | tostring) + "\t" + (.spend_since_commit | k)
       + " tokens since the last commit (" + (.commit_age | age) + ") with no logbook change over that spend (bound " + ($drift | k)
       + "; logbook " + (if .logbook == "written" then ((.logbook_age | age) + " old") else .logbook end) + ")"
     else empty end)
  ] | .[]' 2>/dev/null) || signals=
[ -n "$signals" ] || exit 0

SIGDIR="$DATA/$ID/signals"
mkdir -p "$SIGDIR" 2>/dev/null || exit 0
LEDGER="$SIGDIR/index"

# Portable mtime: BSD stat takes -f, GNU stat -c; never the `-f || -c` fallback,
# because GNU `stat -f` is filesystem stat and prints a dump before failing.
if [ "$(uname)" = Darwin ]; then
  mtime_of() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
  mtime_of() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

# One check at a time per crewmate (the watcher and a leader by hand): the
# ledger is read and appended under the lock. A lock older than two minutes is
# a crashed check's and is taken over.
LOCK="$SIGDIR/.lock"
i=0
until mkdir "$LOCK" 2>/dev/null; do
  if [ "$i" -ge 50 ]; then
    lock_age=$(( $(date +%s) - $(mtime_of "$LOCK") ))
    [ "$lock_age" -gt 120 ] && rmdir "$LOCK" 2>/dev/null && continue
    exit 0
  fi
  sleep 0.1
  i=$((i + 1))
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

episode_recorded() {  # <signal> <signature> -> 0 when the ledger has its row
  [ -f "$LEDGER" ] || return 1
  awk -F '\t' -v s="$1" -v g="$2" '$2 == s && $3 == g { found = 1 } END { exit !found }' "$LEDGER" 2>/dev/null
}

leader_state=none
leader_read=0
read_leader() {
  [ "$leader_read" -eq 0 ] || return 0
  leader_read=1
  if [ ! -f "$STATE/$LEADER.meta" ]; then
    leader_state=no-record
    return 0
  fi
  # shellcheck source=bin/fm-lead-lib.sh
  . "$SCRIPT_DIR/fm-lead-lib.sh"
  leader_state=$(fm_lead_endpoint_state "$STATE/$LEADER.meta" "$LEADER" 2>/dev/null) || leader_state=unknown
  [ -n "$leader_state" ] || leader_state=unknown
}

card_text=
read_card_text() {
  [ -z "$card_text" ] || return 0
  card_text=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-vitals.sh" "$ID" 2>/dev/null) || card_text=
  [ -n "$card_text" ] || card_text="(the card could not be read: FM_HOME=$FM_HOME bin/fm-crew-vitals.sh $ID)"
}

while IFS=$'\t' read -r signal signature summary; do
  [ -n "$signal" ] || continue
  if episode_recorded "$signal" "$signature"; then
    printf '%s\tsilent\t%s\n' "$signal" "$summary"
    continue
  fi
  read_leader
  result="failed:leader-$leader_state"
  if [ "$leader_state" = alive ]; then
    read_card_text
    text="signal: $ID $signal: $summary
$card_text
Mechanical, from the transcript, never from the crewmate's report; the judgment is yours. Look at the pane and the logbook, then steer if the work is off: FM_HOME=$FM_HOME bin/fm-lead.sh steer --leader $LEADER $ID \"<one line>\". Nobody else is told."
    if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$LEADER" "$text" >/dev/null 2>&1; then
      result=rung
    else
      result=failed:send
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$signal" "$signature" "$result" "$LEADER" "$summary" >> "$LEDGER" 2>/dev/null \
    || echo "fm-crew-signals: could not write $LEDGER" >&2
  printf '%s\t%s\t%s\n' "$signal" "$result" "$summary"
done <<EOF
$signals
EOF
exit 0
