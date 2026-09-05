#!/usr/bin/env bash
# bin/fm-logbook-lib.sh - a crewmate's logbook: the file it thinks with.
#
# Sourced by bin/fm-spawn.sh (which creates data/<id>/logbook.md from the
# template at every ship or scout launch, fresh or relaunch, when the file is
# absent, for story crewmates and branch leaders alike) and by bin/fm-brief.sh
# (which names the file in the scaffold). Nothing else spells the path or the
# four headings.
#
# The logbook is the crewmate's own: Done, Next, Open, Decisions, rewritten in
# place at natural checkpoints, under 40 lines. Nobody reads it to count
# anything, and nothing here or anywhere in the fleet asks the crewmate for a
# number: stuck and drift are read from the transcript, never from this file.
# A trimmed session gets it reprinted on its task card (bin/fm-task-card.sh,
# from the claude SessionStart hook), the vitals card reads its age, and a
# leader reads it against the story's acceptance criteria when it judges
# drift. It survives teardown with the brief and the report, because
# bin/fm-teardown.sh never removes data/<id>.
#
# fm_logbook_path <data> <id>      -> <data>/<id>/logbook.md
# fm_logbook_template <id>         -> the template text on stdout
# fm_logbook_init <data> <id>      -> create the file from the template when it is
#                                     absent; an existing one is never touched;
#                                     prints nothing; 1 only when it cannot write

fm_logbook_path() {  # <data> <id>
  printf '%s/%s/logbook.md\n' "$1" "$2"
}

fm_logbook_template() {  # <id>
  cat <<EOF
# Logbook: $1

Yours to think with: rewrite it in place at natural checkpoints, under 40 lines. Nobody reads it to count anything.

## Done

## Next

## Open

## Decisions
EOF
}

fm_logbook_init() {  # <data> <id>
  local data=${1:-} id=${2:-} path tmp
  [ -n "$data" ] && [ -n "$id" ] || { echo "error: fm_logbook_init needs <data> <id>" >&2; return 1; }
  path=$(fm_logbook_path "$data" "$id")
  [ ! -e "$path" ] || return 0
  mkdir -p "$data/$id" || { echo "error: cannot create $data/$id for the logbook" >&2; return 1; }
  tmp="$path.${BASHPID:-$$}.tmp"
  fm_logbook_template "$id" > "$tmp" || { rm -f -- "$tmp"; echo "error: cannot write $path" >&2; return 1; }
  # A second launch racing this one keeps whichever file landed first.
  if [ -e "$path" ]; then rm -f -- "$tmp"; return 0; fi
  mv -- "$tmp" "$path" || { rm -f -- "$tmp"; echo "error: cannot place $path" >&2; return 1; }
  return 0
}
