#!/usr/bin/env bash
# bin/fm-progress.sh - the epic branch leader's progress report, in the one
# shape every leader reports in, and the fleet bar First Mate rolls them into.
# Usage: FM_HOME=<home> fm-progress.sh scaffold <leader-id> [--estimate <pct>]
#        FM_HOME=<home> fm-progress.sh fleet
#        fm-progress.sh bar <pct>
#   scaffold prints the report's six parts, filled from the leader's own
#   records and nothing the crewmates wrote, for the leader to finish and save
#   as data/<leader-id>/progress.md:
#     1. one line naming the goal the epic was given, in the captain's words:
#        the first line under "## Captain's intent" in data/<leader-id>/brief.md;
#     2. a progress bar in a code block, twenty cells, with the estimate as a
#        percentage - --estimate <pct>, the leader's own judgement weighted by
#        what is left, never by story count; without it the bar is empty and
#        says so;
#     3. DONE - one ticked box per line under "## Done" in the leader's
#        logbook, data/<leader-id>/logbook.md, with commit ids struck out
#        (a line reads as what changed for a person, never as a commit);
#     4. IN FLIGHT - one unticked box per line under "## Next" in the leader's
#        logbook, held by the leader, and one per crewmate recorded under the
#        leader (bin/fm-crew-vitals.sh --leader: its head, last commit and
#        status word), held by that crewmate, with the next step left for
#        the leader to write;
#     5. QUEUED, FILED BY NAME - unticked, grouped, none started; the names
#        are the leader's to fill;
#     6. one closing paragraph, "What the bar means": what the epic can do
#        today and what the missing part buys, the leader's to write.
#   The report is written from the leader's logbook and the vitals, never from
#   the crewmates' words: nothing under a crewmate's own logbook, report or
#   status enters it. It is a report, never a gate: nothing here stops,
#   scores or ranks anyone.
#   fleet reads every leader's saved report (every task recorded with leads=1
#   whose data/<id>/progress.md holds a bar line) and prints one fleet bar,
#   the plain mean of the leaders' percentages, then one line per leader: its
#   bar, its percentage and its goal line; a leader without a saved report is
#   listed as such and left out of the mean. The same shape, one level up.
#   bar prints the twenty-cell bar for <pct> (0-100): [#####...............] 25%
# FM_HOME must be explicit, as for bin/fm-lead.sh; FM_STATE_OVERRIDE and
# FM_DATA_OVERRIDE point the directories elsewhere for tests.
# Reads: state/<id>.meta, data/<leader-id>/{brief.md,logbook.md,progress.md},
# the cards. Writes: nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

CELLS=20

render_bar() {  # <pct> -> [####................] 20%
  local pct=$1 filled i out='['
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pct" -le 100 ] || return 1
  filled=$(( (pct * CELLS + 50) / 100 ))
  i=0
  while [ "$i" -lt "$CELLS" ]; do
    if [ "$i" -lt "$filled" ]; then out="$out#"; else out="$out."; fi
    i=$((i + 1))
  done
  printf '%s] %s%%\n' "$out" "$pct"
}

VERB=${1:-}
case "$VERB" in
  -h|--help|help|'') usage; [ -n "$VERB" ] && exit 0; exit 2 ;;
  bar)
    render_bar "${2:-}" && exit 0
    echo "error: bar needs a whole number from 0 to 100, got '${2:-}'" >&2
    exit 1 ;;
  scaffold|fleet) ;;
  *) echo "error: unknown verb '$VERB' (scaffold, fleet, bar); see fm-progress.sh --help" >&2; exit 1 ;;
esac
shift

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-progress refuses to read a fleet without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lead-lib.sh
. "$SCRIPT_DIR/fm-lead-lib.sh"

# The lines of one "## <name>" section of a markdown file, without the list
# marker; empty when the section is empty or absent.
section_lines() {  # <file> <name>
  [ -f "$1" ] || return 0
  awk -v name="$2" '
    /^## / { f = ($0 == "## " name) ; next }
    f && NF { sub(/^[-*] */, ""); print }
  ' "$1"
}

# A commit id is not news: strike it out of a line that names what changed for
# a person. A word is a commit id only when it is made of [0-9a-f], is 7 to 40
# characters long, AND mixes at least one digit with at least one a-f letter -
# a plain long number ("epoch 1757100000", "1400000 tokens") and an all-letter
# word ("effaced") are words, not hashes. The honest cost: an all-digit or
# all-letter hash is not struck, which is rare and harmless, because this is a
# report and never a gate.
#
# THE RULE. Removing a commit id removes, as one unit:
#   - the id itself;
#   - any brackets that wrapped it and are left empty;
#   - the separator that directly introduced it (a space, or a comma and a
#     space);
#   - and the introducer word - after, in, at, as, landed, commit, from, to -
#     when the id followed it through nothing but those separators and
#     brackets.
# What remains must be a grammatical sentence: no doubled space, no space
# before . , ; : or ), no ",." and no ",,", no empty "()", and no bracket left
# without its partner. tests/fm-progress.test.sh asserts that as an invariant
# over every introducer, separator and bracketing, not as a list of examples.
#
# How it is done: the awk pass drops the id, the separator and the introducer,
# and leaves the brackets it emptied where they stood so they still meet their
# partners; the sed that follows removes the empty parenthetical, collapses
# doubled spaces and drops a space before a stop. A separator made of anything
# but spaces, commas and brackets is not a separator this rule knows, so the
# id alone goes and the text around it is left untouched. The commit-id
# predicate needs a look at the whole token, which portable ERE cannot
# express, which is why the strike is an awk pass at all.
strike_commit_ids() {
  awk '
    function is_commit(t) {
      return (t ~ /^[0-9a-f]+$/) && (length(t) >= 7) && (length(t) <= 40) \
        && (t ~ /[0-9]/) && (t ~ /[a-f]/)
    }
    {
      rest = $0; out = ""
      while (match(rest, /[0-9A-Za-z]+/)) {
        pre = substr(rest, 1, RSTART - 1)
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (length(pre) > 0) prev = substr(pre, length(pre), 1)
        else if (length(out) > 0) prev = substr(out, length(out), 1)
        else prev = ""
        # A hash is struck only where the text lets one stand: at the start of
        # the line or after a space, "(" or ",", never inside a longer word.
        if (is_commit(tok) && (prev == "" || prev == " " || prev == "(" || prev == ",")) {
          kept = out pre
          tail = kept
          sub(/^.*[0-9A-Za-z]/, "", tail)
          head = substr(kept, 1, length(kept) - length(tail))
          if (tail ~ /^[ ,()]*$/) {
            brackets = tail
            gsub(/[^()]/, "", brackets)
            word = head
            sub(/^.*[^0-9A-Za-z]/, "", word)
            if (word ~ /^(after|in|at|as|landed|commit|from|to)$/) {
              sub(/[0-9A-Za-z]+$/, "", head)
              sub(/[ ,]+$/, "", head)
            }
            out = head (head == "" ? "" : " ") brackets
          } else {
            out = kept
          }
        } else {
          out = out pre tok
        }
      }
      print out rest
    }' \
  | sed -E \
    -e 's/\( *(, *)*\)//g' \
    -e 's/\( *, */(/g' \
    -e 's/ +([.,;:)])/\1/g' \
    -e 's/  +/ /g' \
    -e 's/^ +//' \
    -e 's/ +$//'
}

k_of() {  # <tokens> -> 91K | 3.1K | 512 | ?
  local n=$1 h
  case "$n" in ''|null|*[!0-9]*) printf '?'; return 0 ;; esac
  if [ "$n" -ge 9950 ]; then printf '%sK' $(((n + 500) / 1000))
  elif [ "$n" -ge 1000 ]; then h=$(((n + 50) / 100)); printf '%s.%sK' $((h / 10)) $((h % 10))
  else printf '%s' "$n"; fi
}

age_of() {  # <seconds> -> 40s | 22m | 3h | 2d | ?
  local d=$1
  case "$d" in ''|null|*[!0-9]*) printf '?'; return 0 ;; esac
  if [ "$d" -lt 90 ]; then printf '%ss' "$d"
  elif [ "$d" -lt 5400 ]; then printf '%sm' $(((d + 30) / 60))
  elif [ "$d" -lt 172800 ]; then printf '%sh' $(((d + 1800) / 3600))
  else printf '%sd' $(((d + 43200) / 86400)); fi
}

case "$VERB" in
  scaffold)
    LEADER=
    ESTIMATE=
    want=
    for a in "$@"; do
      if [ -n "$want" ]; then ESTIMATE=$a; want=; continue; fi
      case "$a" in
        --estimate) want=1 ;;
        --estimate=*) ESTIMATE=${a#--estimate=} ;;
        -*) echo "error: unknown argument '$a'; see fm-progress.sh --help" >&2; exit 1 ;;
        *) [ -z "$LEADER" ] || { echo "error: one leader id only, got '$LEADER' and '$a'" >&2; exit 1; }; LEADER=$a ;;
      esac
    done
    [ -z "$want" ] || { echo "error: --estimate requires a value" >&2; exit 1; }
    [ -n "$LEADER" ] || { echo "error: scaffold needs the leader's task id; see fm-progress.sh --help" >&2; exit 1; }
    case "$LEADER" in *[!A-Za-z0-9._-]*|.|..) echo "error: '$LEADER' is not a task id" >&2; exit 1 ;; esac
    [ -f "$STATE/$LEADER.meta" ] || { echo "error: no task record for $LEADER in this home (state/$LEADER.meta)" >&2; exit 1; }
    if [ -n "$ESTIMATE" ]; then
      BAR=$(render_bar "$ESTIMATE") || { echo "error: --estimate needs a whole number from 0 to 100, got '$ESTIMATE'" >&2; exit 1; }
    else
      BAR="$(render_bar 0 | sed 's/ 0%$//') ?%   <- give --estimate <pct>: your judgement of what is done, weighted by what is left, never by story count"
    fi
    BRIEF="$DATA/$LEADER/brief.md"
    GOAL=
    if [ -f "$BRIEF" ]; then
      GOAL=$(awk '/^## Captain.s intent$/ { f = 1; next } f && /^## / { exit } f && NF { print; exit }' "$BRIEF")
    fi
    [ -n "$GOAL" ] && [ "$GOAL" != "{TASK}" ] || GOAL="{the goal the epic was given, in the captain's words - the brief's Captain's intent is empty}"
    LOGBOOK="$DATA/$LEADER/logbook.md"
    DONE_LINES=$(section_lines "$LOGBOOK" Done | strike_commit_ids)
    NEXT_LINES=$(section_lines "$LOGBOOK" Next)

    printf 'Goal: %s\n\n' "$GOAL"
    fence='```'
    printf '%s\n%s\n%s\n\n' "$fence" "$BAR" "$fence"
    printf 'DONE\n'
    if [ -n "$DONE_LINES" ]; then
      printf '%s\n' "$DONE_LINES" | sed 's/^/- [x] /'
    else
      printf -- '- [x] {nothing under ## Done in the logbook yet}\n'
    fi
    printf '\nIN FLIGHT\n'
    if [ -n "$NEXT_LINES" ]; then
      printf '%s\n' "$NEXT_LINES" | sed "s/^/- [ ] /; s/\$/ - held by $LEADER/"
    fi
    crew=$(fm_lead_crew_of "$STATE" "$LEADER")
    if [ -n "$crew" ]; then
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        card=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-vitals.sh" "$id" --json 2>/dev/null) || card=
        [ -z "$card" ] || [ "$(printf '%s' "$card" | jq -r '.transcript // empty')" != "" ] || card=
        if [ -n "$card" ]; then
          head=$(printf '%s' "$card" | jq -r '.head // "?"')
          commit=$(printf '%s' "$card" | jq -r '.commit_age // "?"')
          word=$(printf '%s' "$card" | jq -r '.status // "?"')
          printf -- '- [ ] {story} - next: {the next step} - held by %s (head %s, last commit %s ago, last status %s)\n' \
            "$id" "$(k_of "$head")" "$(age_of "$commit")" "$word"
        else
          printf -- '- [ ] {story} - next: {the next step} - held by %s (no card: the transcript has not begun)\n' "$id"
        fi
      done <<EOF
$crew
EOF
    fi
    [ -n "$NEXT_LINES" ] || [ -n "$crew" ] || printf -- '- [ ] {nothing under ## Next in the logbook and no crewmates recorded}\n'
    printf '\nQUEUED, FILED BY NAME\n'
    printf -- '- [ ] {a queued story, by name; group them; none started}\n'
    printf '\nWhat the bar means: {what the epic can do today, in one or two sentences} {what the missing part buys}\n'
    ;;
  fleet)
    [ $# -eq 0 ] || { echo "error: fleet takes no arguments; see fm-progress.sh --help" >&2; exit 1; }
    leaders=
    for m in "$STATE"/*.meta; do
      [ -f "$m" ] || continue
      [ "$(fm_meta_get "$m" leads 2>/dev/null)" = 1 ] || continue
      id=${m##*/}; id=${id%.meta}
      leaders="$leaders$id"$'\n'
    done
    [ -n "$leaders" ] || { echo "no epic branch leaders recorded in this home (leads=1)" >&2; exit 0; }
    sum=0; n=0; rows=
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      report="$DATA/$id/progress.md"
      pct=
      [ ! -f "$report" ] || pct=$(sed -n 's/^\[[#.]\{20\}\] \([0-9][0-9]*\)%.*$/\1/p' "$report" | head -n 1)
      if [ -n "$pct" ] && [ "$pct" -le 100 ]; then
        goal=$(sed -n 's/^Goal: //p' "$report" | head -n 1)
        rows="$rows$(render_bar "$pct")  $id  ${goal:-(no goal line)}"$'\n'
        sum=$((sum + pct)); n=$((n + 1))
      else
        rows="${rows}[....................]  --%  $id  (no saved report: data/$id/progress.md has no bar line)"$'\n'
      fi
    done <<EOF
$leaders
EOF
    fence='```'
    printf 'Fleet: %s epic branch leader(s), %s with a saved report\n\n%s\n' "$(printf '%s' "$leaders" | grep -c .)" "$n" "$fence"
    if [ "$n" -gt 0 ]; then render_bar $(((sum + n / 2) / n)); else printf '[....................] --%%\n'; fi
    printf '%s\n\n%s' "$fence" "$rows"
    ;;
esac
exit 0
