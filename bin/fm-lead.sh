#!/usr/bin/env bash
# bin/fm-lead.sh - the branch leader's hands and eyes over its own crewmates.
# Usage: FM_HOME=<home> fm-lead.sh crew --leader <task-id>
#   crew lists every crewmate recorded under <task-id> (the leader= line
#   bin/fm-spawn.sh --leader writes; bin/fm-lead-lib.sh owns the chain), one
#   per line, sorted by id:
#     <id> kind=<ship|scout> mode=<mode|-> endpoint=<alive|dead|unknown> window=<endpoint>
#   endpoint is the same cheap presence read the session-start digest uses, not
#   a full state read; bin/fm-crew-state.sh <id> owns the crewmate's current
#   state. A leader with no crewmates prints one "no crewmates recorded" line
#   to stderr and exits 0. A leader with no record in this home, a missing
#   --leader, or an unknown verb is refused with exit 1.
# FM_HOME must be explicit, exactly as for bin/fm-send.sh: a leader's view must
# never silently resolve against another home. FM_STATE_OVERRIDE points the
# state directory elsewhere for tests.
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
[ -n "$VERB" ] || { echo "error: a verb is required (crew); see fm-lead.sh --help" >&2; exit 1; }
shift

LEADER=
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      leader) LEADER=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --leader) want_value=leader ;;
    --leader=*) LEADER=${a#--leader=} ;;
    *) echo "error: unknown argument '$a'; see fm-lead.sh --help" >&2; exit 1 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --leader requires a value" >&2; exit 1; }
[ -n "$LEADER" ] || { echo "error: --leader <task-id> is required; a leader names itself, fm-lead never guesses" >&2; exit 1; }
case "$LEADER" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: '$LEADER' is not a task id" >&2; exit 1 ;;
esac

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
  *)
    echo "error: unknown verb '$VERB' (crew); see fm-lead.sh --help" >&2
    exit 1
    ;;
esac
