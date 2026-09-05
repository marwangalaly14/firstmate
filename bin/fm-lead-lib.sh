#!/usr/bin/env bash
# bin/fm-lead-lib.sh - the branch-leader chain: which task of this home leads
# which crewmates, and the four-crewmate ceiling.
#
# Sourced by bin/fm-spawn.sh (--leader), bin/fm-lead.sh, bin/fm-crew-vitals.sh
# and bin/fm-trim-event.sh. Callers must have sourced bin/fm-backend.sh first
# (fm_meta_get, fm_backend_of_meta, fm_backend_target_of_meta,
# fm_backend_agent_alive, fm_backend_target_exists).
#
# The chain is one meta line, written only by fm-spawn and removed with the
# record by teardown:
#   leader=<task-id>   in state/<crewmate>.meta - the task of this home that
#                      briefs, steers and supervises this crewmate.
# A crewmate is "recorded under" a leader while its meta carries that line; a
# dead pane keeps its record (and its slot) until the record is torn down,
# because a crewmate with unlanded work is still the leader's to recover.
#
# A leader is a ship or scout task of this home that was spawned as one
# (bin/fm-spawn.sh --leads writes leads=1 into its record and leaves its trim
# window where the harness puts it; bin/fm-compact-lib.sh), whose record
# exists, whose endpoint holds a live agent, and which is not itself led
# (chains are one level deep). A secondmate never leads this home's crewmates.
#
# "Holds a live agent" is bin/fm-backend.sh's recovery-grade read
# (fm_backend_agent_alive: the exact window inventory plus the foreground
# process), not the digest's cheap presence read alone: on tmux 3.7 that cheap
# read (display-message -t session:window) answers for the session's current
# window when the named window is gone, so a killed leader window would read
# as alive. Where the recovery-grade read cannot classify (an ambiguous or
# unreadable foreground, a backend without a classifier) the cheap read
# decides, as it does for the digest's "endpoint: alive" line.
#
# FM_LEAD_MAX_CREW (4) is the ceiling on recorded crewmates per leader; the
# spawn takes the fifth only after one of the four is torn down. The spawn
# serializes the count and the publication under state/.lead-<leader>.lock so
# two spawns under one leader cannot both count three.
#
# fm_lead_crew_of <state-dir> <leader-id>
#   Prints the ids of every task recorded under <leader-id>, sorted, one per
#   line; prints nothing when there are none.
# fm_lead_leader_state <state-dir> <leader-id>
#   Prints exactly one of:
#     alive       - a ship or scout task of this home with a present endpoint.
#     dead        - the record exists but its endpoint is absent.
#     no-record   - no state/<leader-id>.meta in this home.
#     secondmate  - the record is a secondmate's.
#     led <id>    - the record is itself led by <id>.
#     not-leader  - the record carries no leads=1: a story crewmate.
# fm_lead_check_chain <state-dir> <leader-id> <new-id>
#   Returns 0 when <new-id> may be recorded under <leader-id>; otherwise prints
#   one refusal line to stderr and returns 1. The refusal names the leader, the
#   cause, and for the ceiling the crewmates already recorded.
# fm_lead_lock_path <state-dir> <leader-id>
#   Prints the per-leader lock directory the spawn holds from its count to its
#   publication.

FM_LEAD_MAX_CREW=4

fm_lead_crew_of() {  # <state-dir> <leader-id>
  local state=$1 leader=$2 meta id
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(fm_meta_get "$meta" leader)" = "$leader" ] || continue
    printf '%s\n' "$id"
  done | sort
}

fm_lead_endpoint_state() {  # <meta-file> <task-id> -> alive|dead|unknown
  local meta=$1 id=$2 window target backend
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || { printf 'unknown'; return 0; }
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  case "$(fm_backend_agent_alive "$backend" "${target:-$window}" 2>/dev/null)" in
    alive) printf 'alive'; return 0 ;;
    dead) printf 'dead'; return 0 ;;
  esac
  if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

fm_lead_leader_state() {  # <state-dir> <leader-id>
  local state=$1 leader=$2 meta led
  meta="$state/$leader.meta"
  [ -f "$meta" ] || { printf 'no-record'; return 0; }
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || { printf 'secondmate'; return 0; }
  led=$(fm_meta_get "$meta" leader)
  [ -z "$led" ] || { printf 'led %s' "$led"; return 0; }
  [ "$(fm_meta_get "$meta" leads)" = 1 ] || { printf 'not-leader'; return 0; }
  case "$(fm_lead_endpoint_state "$meta" "$leader")" in
    alive) printf 'alive' ;;
    *) printf 'dead' ;;
  esac
}

fm_lead_check_chain() {  # <state-dir> <leader-id> <new-id>
  local state=$1 leader=$2 new=$3 leader_state crew count
  if [ "$leader" = "$new" ]; then
    echo "error: task $new cannot name itself as its leader" >&2
    return 1
  fi
  leader_state=$(fm_lead_leader_state "$state" "$leader")
  case "$leader_state" in
    alive) ;;
    no-record)
      echo "error: leader $leader has no task record in this home (state/$leader.meta); a leader is a live task of the home spawning under it" >&2
      return 1 ;;
    dead)
      echo "error: leader $leader's endpoint is dead; relaunch the leader before spawning crewmates under it" >&2
      return 1 ;;
    secondmate)
      echo "error: leader $leader is a secondmate; a secondmate leads its own home's crewmates, never this home's" >&2
      return 1 ;;
    led*)
      echo "error: leader $leader is itself led by ${leader_state#led }; a chain is one level deep, so a led crewmate cannot lead" >&2
      return 1 ;;
    not-leader)
      echo "error: leader $leader was not spawned as a leader (--leads); only a task recorded with leads=1 may lead, so spawn the leader with --leads before spawning crewmates under it" >&2
      return 1 ;;
    *)
      echo "error: leader $leader's record reads '$leader_state'; refusing to chain under it" >&2
      return 1 ;;
  esac
  crew=$(fm_lead_crew_of "$state" "$leader")
  count=0
  [ -z "$crew" ] || count=$(printf '%s\n' "$crew" | wc -l | tr -d ' ')
  if [ "$count" -ge "$FM_LEAD_MAX_CREW" ]; then
    echo "error: leader $leader already leads $count crewmates ($(printf '%s\n' "$crew" | tr '\n' ' ' | sed 's/ $//')); the ceiling is $FM_LEAD_MAX_CREW, so tear one down or finish it before spawning $new under this leader" >&2
    return 1
  fi
  return 0
}

fm_lead_lock_path() {  # <state-dir> <leader-id>
  printf '%s/.lead-%s.lock\n' "$1" "$2"
}
