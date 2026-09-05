#!/usr/bin/env bash
# bin/fm-lead.sh - the branch leader's hands and eyes over its own crewmates.
# Usage: FM_HOME=<home> fm-lead.sh crew  --leader <task-id>
#        FM_HOME=<home> fm-lead.sh steer --leader <task-id> <crewmate> [--resolve-key <key>]... <text...>
#        FM_HOME=<home> fm-lead.sh trim  --leader <task-id> <crewmate> [focus...]
#   crew lists every crewmate recorded under <task-id> (the leader= line
#   bin/fm-spawn.sh --leader writes; bin/fm-lead-lib.sh owns the chain), one
#   per line, sorted by id:
#     <id> kind=<ship|scout> mode=<mode|-> endpoint=<alive|dead|unknown> window=<endpoint>
#   endpoint is bin/fm-lead-lib.sh's liveness read (fm-backend's recovery-grade
#   agent read, then the digest's cheap presence read where that cannot
#   classify), not a full state read; bin/fm-crew-state.sh <id> owns the
#   crewmate's current state. A leader with no crewmates prints one "no crewmates recorded" line
#   to stderr and exits 0.
#   steer sends <crewmate> the text through bin/fm-send.sh exactly as First
#   Mate would (the durable inbox record plus the doorbell; --resolve-key
#   closes the door the text answers), carrying fm-send's --from-leader mark
#   (the led channel: to a led crewmate, only its leader's steer, a lifecycle
#   action or the captain's words get through; the mark is recorded in the
#   record's header), then appends one line to the leader's
#   own state/<task-id>.status:
#     note: steered <crewmate> (<chars> chars, <lines> lines): <first line>
#   so First Mate reads every steer in its next UNREAD STATUS section without
#   being woken (a note: line is not a wake; a first line that itself carries
#   a captain-relevant token such as "merged" wakes First Mate as any status
#   line would), and measures it in data/<task-id>/steers/index, one line per
#   steer, tab-separated: <epoch> <crewmate> <chars> <lines> <key|->. A steer
#   over 1,200 characters is warned about on stderr and sent anyway: size is
#   measured, never enforced. The exit is fm-send's.
#   trim orders <crewmate> to trim its context: it appends
#     ordered <epoch> <leader> <focus|->
#   to data/<crewmate>/trims/index (bin/fm-trim-event.sh's ledger; it skips
#   lines that do not start with a number when counting trims and attributes
#   the manual trim that follows to this order), then types `/compact <focus>`
#   into the crewmate's pane through fm-send's typed plane, and notes
#   `note: ordered a trim of <crewmate>: <focus>` on the leader's status. A
#   /compact that provably did not reach the pane (fm-send exit other than 0
#   or 3) appends `order-failed <epoch>` after the order, notes nothing and
#   exits 1; an unconfirmed submit (exit 3) keeps the order and exits 3. The
#   harness runs a typed /compact at the crewmate's next turn boundary when
#   the crewmate is mid-turn; the order is not an interrupt.
#   trim never waits: it marks the order, types /compact, and returns. The
#   crewmate is not left idle at its prompt either, because the carry-on
#   nudge belongs to the crewmate's own PostCompact hook, which fires when
#   the compaction actually ends and reads the pending order to know who
#   asked for it (bin/fm-trim-event.sh). No leader command has to outlive a
#   compaction for the crewmate to be told to carry on.
#   steer and trim refuse, before writing anything: a crewmate not recorded in
#   this home; one whose record names another leader or none ("not led by");
#   one whose endpoint reads dead through bin/fm-lead-lib.sh (lifecycle is
#   First Mate's; ask it to relaunch). An unknown endpoint is left to fm-send.
#   A leader with no record in this home, a missing --leader, or an unknown
#   verb is refused with exit 1. A leader is a task spawned with
#   bin/fm-spawn.sh --leads (leads=1 in its record); every verb here works on
#   what is recorded under any task id and leaves the leader test to the spawn.
# FM_HOME must be explicit, exactly as for bin/fm-send.sh: a leader's view must
# never silently resolve against another home. FM_STATE_OVERRIDE points the
# state directory elsewhere for tests (crew only; steer and trim write through
# fm-send, which reads FM_HOME/state).
# Reads: state/<id>.meta, data/<crewmate>/trims/index. Writes: the crewmate's
# inbox and pane through fm-send, state/<leader>.status,
# data/<leader>/steers/index, data/<crewmate>/trims/index.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-lead refuses to read a fleet without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-lead cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-lead cannot read crewmates for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lead-lib.sh
. "$SCRIPT_DIR/fm-lead-lib.sh"

VERB=${1:-}
[ -n "$VERB" ] || { echo "error: a verb is required (crew, steer, trim); see fm-lead.sh --help" >&2; exit 1; }
shift
case "$VERB" in
  crew|steer|trim) ;;
  *) echo "error: unknown verb '$VERB' (crew, steer, trim); see fm-lead.sh --help" >&2; exit 1 ;;
esac

# --leader is taken from anywhere on the line; for steer and trim the first
# other word is the crewmate, --resolve-key <key> (steer only) is handed to
# fm-send, and every remaining word is the text (steer) or the focus (trim).
LEADER=
CREWMATE=
RESOLVE_KEYS=()
WORDS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      leader) LEADER=$a ;;
      key) RESOLVE_KEYS+=("$a") ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --leader) want_value=leader ;;
    --leader=*) LEADER=${a#--leader=} ;;
    --resolve-key)
      [ "$VERB" = steer ] || { echo "error: --resolve-key belongs to steer; see fm-lead.sh --help" >&2; exit 1; }
      want_value=key ;;
    --resolve-key=*)
      [ "$VERB" = steer ] || { echo "error: --resolve-key belongs to steer; see fm-lead.sh --help" >&2; exit 1; }
      RESOLVE_KEYS+=("${a#--resolve-key=}") ;;
    *)
      if [ "$VERB" = crew ]; then
        echo "error: unknown argument '$a'; see fm-lead.sh --help" >&2; exit 1
      elif [ -z "$CREWMATE" ]; then
        CREWMATE=$a
      else
        WORDS+=("$a")
      fi ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ -n "$LEADER" ] || { echo "error: --leader <task-id> is required; a leader names itself, fm-lead never guesses" >&2; exit 1; }
case "$LEADER" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: '$LEADER' is not a task id" >&2; exit 1 ;;
esac
[ -f "$STATE/$LEADER.meta" ] || {
  echo "error: no task record for $LEADER in this home (state/$LEADER.meta)" >&2
  exit 1
}

# own_live_crewmate: refuse, before anything is written, a crewmate that is
# not recorded here, not led by this leader, or dead. Sets CREW_META.
own_live_crewmate() {  # <crewmate>
  local id=$1 led
  [ -n "$id" ] || { echo "error: $VERB needs a crewmate id; see fm-lead.sh --help" >&2; return 1; }
  case "$id" in
    *[!A-Za-z0-9._-]*|.|..) echo "error: '$id' is not a task id" >&2; return 1 ;;
  esac
  CREW_META="$STATE/$id.meta"
  [ -f "$CREW_META" ] || { echo "error: no task record for $id in this home (state/$id.meta)" >&2; return 1; }
  led=$(fm_meta_get "$CREW_META" leader)
  if [ "$led" != "$LEADER" ]; then
    if [ -n "$led" ]; then
      echo "error: $id is not led by $LEADER (its record says leader=$led); a leader steers only its own chain" >&2
    else
      echo "error: $id is not led by $LEADER (its record names no leader); a leader steers only its own chain" >&2
    fi
    return 1
  fi
  case "$(fm_lead_endpoint_state "$CREW_META" "$id")" in
    dead)
      echo "error: $id is not alive (endpoint dead); lifecycle is First Mate's: ask it to relaunch $id, then steer" >&2
      return 1 ;;
  esac
  return 0
}

leader_note() {  # <text>: one line on the leader's own status
  printf '%s\n' "$1" >> "$STATE/$LEADER.status"
}

case "$VERB" in
  crew)
    [ -f "$STATE/$LEADER.meta" ] || {
      echo "error: no task record for $LEADER in this home (state/$LEADER.meta)" >&2
      exit 1
    }
    crew=$(fm_lead_crew_of "$STATE" "$LEADER")
    if [ -z "$crew" ]; then
      echo "no crewmates recorded for $LEADER" >&2
      exit 0
    fi
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      meta="$STATE/$id.meta"
      kind=$(fm_meta_get "$meta" kind)
      mode=$(fm_meta_get "$meta" mode)
      window=$(fm_meta_get "$meta" window)
      printf '%s kind=%s mode=%s endpoint=%s window=%s\n' \
        "$id" "${kind:-?}" "${mode:--}" "$(fm_lead_endpoint_state "$meta" "$id")" "${window:-?}"
    done <<EOF
$crew
EOF
    ;;
  steer)
    own_live_crewmate "$CREWMATE" || exit 1
    [ "${#WORDS[@]}" -gt 0 ] || { echo "error: steer needs the text to send $CREWMATE; see fm-lead.sh --help" >&2; exit 1; }
    TEXT="${WORDS[*]}"
    [ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] || { echo "error: steer needs the text to send $CREWMATE; see fm-lead.sh --help" >&2; exit 1; }
    chars=$(printf '%s' "$TEXT" | wc -m | tr -d ' ')
    lines=$(printf '%s\n' "$TEXT" | wc -l | tr -d ' ')
    if [ "$chars" -gt 1200 ]; then
      echo "fm-lead: the steer to $CREWMATE is $chars characters (over 1,200); sent anyway - a shorter steer costs the crewmate less to read" >&2
    fi
    send_args=()
    for k in ${RESOLVE_KEYS[@]+"${RESOLVE_KEYS[@]}"}; do send_args+=(--resolve-key "$k"); done
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$CREWMATE" --from-leader "$LEADER" ${send_args[@]+"${send_args[@]}"} "$TEXT"
    send_rc=$?
    [ "$send_rc" -eq 0 ] || exit "$send_rc"
    first=$(printf '%s\n' "$TEXT" | head -n 1)
    leader_note "note: steered $CREWMATE ($chars chars, $lines lines): $first"
    mkdir -p "$FM_HOME/data/$LEADER/steers"
    if [ "${#RESOLVE_KEYS[@]}" -gt 0 ]; then key=$(IFS=,; printf '%s' "${RESOLVE_KEYS[*]}"); else key=-; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$CREWMATE" "$chars" "$lines" "$key" >> "$FM_HOME/data/$LEADER/steers/index"
    ;;
  trim)
    own_live_crewmate "$CREWMATE" || exit 1
    if [ "${#WORDS[@]}" -gt 0 ]; then FOCUS="${WORDS[*]}"; else FOCUS=; fi
    FOCUS=$(printf '%s' "$FOCUS" | tr '\n\t' '  ')
    TRIMS="$FM_HOME/data/$CREWMATE/trims"
    mkdir -p "$TRIMS"
    ORDER_EPOCH=$(date +%s)
    printf 'ordered\t%s\t%s\t%s\n' "$ORDER_EPOCH" "$LEADER" "${FOCUS:--}" >> "$TRIMS/index"
    if [ -n "$FOCUS" ]; then ORDER="/compact $FOCUS"; else ORDER="/compact"; fi
    send_rc=0
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$CREWMATE" --from-leader "$LEADER" "$ORDER" || send_rc=$?
    case "$send_rc" in
      0) ;;
      3) echo "fm-lead: the trim order to $CREWMATE was typed but its submit is unconfirmed (fm-send exit 3); the order stands in the ledger - verify the pane before ordering again" >&2
         exit 3 ;;
      *) printf 'order-failed\t%s\n' "$(date +%s)" >> "$TRIMS/index"
         echo "error: the trim order did not reach $CREWMATE (fm-send exit $send_rc); recorded as order-failed" >&2
         exit 1 ;;
    esac
    leader_note "note: ordered a trim of $CREWMATE: ${FOCUS:-no focus given}"
    ;;
esac
