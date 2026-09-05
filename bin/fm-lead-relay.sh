#!/usr/bin/env bash
# bin/fm-lead-relay.sh - route a led crewmate's door lines to its leader.
#
# Usage: fm-lead-relay.sh <home> <task-id>
#
# A led crewmate (state/<task-id>.meta carries leader=<leader-id>, written by
# fm-spawn --leader) has two doors, both keyed status lines it appends to
# state/<task-id>.status:
#   needs-decision: [key=story-size] ...
#   blocked: [key=stuck] ...
# Those doors are the leader's to answer, so this relay puts each NEW keyed
# door line into the leader's steering inbox through bin/fm-send.sh (a
# durable record plus the doorbell; the watcher's re-ring ladder covers an
# unacknowledged record as it covers any ordinary steer) and writes what it
# did into the crewmate's door ledger, data/<task-id>/doors/index, one
# tab-separated row per door line:
#   <epoch>  rung                    <leader>  <key>  <the status line>
#   <epoch>  failed:<why>            <leader>  <key>  <the status line>
# where <why> is leader-dead, leader-unknown, leader-no-record or send. Tabs
# inside the status line are written as spaces. bin/fm-watch.sh appends its
# own rows to the same ledger (escalated, answered) and reads the rung rows to
# decide whether First Mate must be woken for the door (its header, "the
# chain"). A door is never rung twice: data/<task-id>/doors/cursor holds the
# count of status lines already read, advanced under data/<task-id>/doors/.lock
# so the Stop hook and the watcher, which both run this relay, cannot both
# ring the same line.
#
# Who runs it: the crewmate's Stop hook, after the busy-event writer (fm-spawn
# wires it for a led claude crewmate only), and the watcher when it meets a
# door the hook has not rung yet. A task without leader= exits 0 at once and
# writes nothing, so an unled crewmate is exactly as before.
#
# Which lines: a line whose verb is needs-decision or blocked and which carries
# a [key=<slug>] token (bin/fm-classify-lib.sh's status_line_decision_key), read from
# the lines past the cursor. An unkeyed blocked: line is not a door and is left
# to First Mate's ordinary wake path. A resolved: line closes nothing here; the
# watcher reads the open set.
#
# What the leader receives, two lines:
#   door: <task-id> <verb> [key=<key>] <note>
#   Answer it and close the door: FM_HOME=<home> bin/fm-lead.sh steer --leader
#   <leader> <task-id> --resolve-key <key> "<one line>" - or escalate it to
#   First Mate in your status.
# Nothing here reaches the crewmate: the ring goes to the leader's pane, the
# ledger is under data/, and the hook prints nothing.
#
# Liveness: the leader's endpoint is read with bin/fm-lead-lib.sh
# (fm_lead_endpoint_state) before any send; a dead or unclassifiable leader
# gets a failed: row and no send, so the watcher surfaces the door to First
# Mate as it always did.
#
# Exit: 0 on every path once the arguments are valid, so a failing hook can
# never show up in the crewmate's session; 2 on usage. Prints nothing on
# stdout; errors go to stderr.
# Reads: state/<task-id>.meta, state/<task-id>.status, state/<leader>.meta.
# Writes: data/<task-id>/doors/{cursor,index,.lock}; the leader's inbox.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-lead-relay.sh <home> <task-id>" >&2
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
STATUS="$STATE/$ID.status"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

[ -f "$META" ] || exit 0
LEADER=$(fm_meta_get "$META" leader 2>/dev/null) || LEADER=
[ -n "$LEADER" ] || exit 0
[ -f "$STATUS" ] || exit 0

DOORS="$DATA/$ID/doors"
mkdir -p "$DOORS" 2>/dev/null || exit 0

# Portable mtime: BSD stat takes -f, GNU stat -c; never the `-f || -c` fallback,
# because GNU `stat -f` is filesystem stat and prints a dump before failing.
if [ "$(uname)" = Darwin ]; then
  mtime_of() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
  mtime_of() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

# One relay at a time per crewmate: the cursor is read and advanced under the
# lock. A lock older than two minutes is a crashed relay's and is taken over.
LOCK="$DOORS/.lock"
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

CURSOR=0
[ ! -f "$DOORS/cursor" ] || CURSOR=$(tr -d '[:space:]' < "$DOORS/cursor" 2>/dev/null)
case "$CURSOR" in ''|*[!0-9]*) CURSOR=0 ;; esac
TOTAL=$(wc -l < "$STATUS" 2>/dev/null | tr -d ' ')
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
# The status log is append-only; a shorter file than the cursor remembers is
# not re-read (nothing would be new), only re-based.
[ "$CURSOR" -le "$TOTAL" ] || CURSOR=$TOTAL
[ "$CURSOR" -lt "$TOTAL" ] || exit 0

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

n=0
# Only whole lines: a line still being written (no newline yet) is not counted
# by wc -l and is read next time.
while IFS= read -r line; do
  n=$((n + 1))
  [ "$n" -gt "$CURSOR" ] || continue
  case "$line" in *[![:space:]]*) ;; *) continue ;; esac
  key=$(status_line_decision_key "$line") || continue
  verb=$(status_line_verb "$line")
  note=$(status_line_note "$line")
  flat=$(printf '%s' "$line" | tr '\t' ' ')
  read_leader
  result="failed:leader-$leader_state"
  if [ "$leader_state" = alive ]; then
    text="door: $ID $verb [key=$key] $note
Answer it and close the door: FM_HOME=$FM_HOME bin/fm-lead.sh steer --leader $LEADER $ID --resolve-key $key \"<one line>\" - or escalate it to First Mate in your status."
    if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$LEADER" "$text" >/dev/null 2>&1; then
      result=rung
    else
      result=failed:send
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$result" "$LEADER" "$key" "$flat" >> "$DOORS/index" 2>/dev/null \
    || echo "fm-lead-relay: could not write $DOORS/index" >&2
done < "$STATUS"
printf '%s\n' "$TOTAL" > "$DOORS/cursor" 2>/dev/null || echo "fm-lead-relay: could not write $DOORS/cursor" >&2
exit 0
