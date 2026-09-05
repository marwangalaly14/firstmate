#!/usr/bin/env bash
# bin/fm-crew-vitals.sh - one card per crewmate, read from the outside.
# Usage: FM_HOME=<home> fm-crew-vitals.sh <task-id> [--line|--json]
#        FM_HOME=<home> fm-crew-vitals.sh --leader <task-id> [--line|--json]
#        FM_HOME=<home> fm-crew-vitals.sh --all [--line|--json]
#   The card is four lines, designed for a leader with four crewmates, not forty:
#     <id>  <last status event>  head 91K (start 60K, peak 138K, mark 140K)  trims 1 auto  turns 212
#       last call  Bash `bash tests/fm-spawn.test.sh`  40s ago    repeats none
#       tokens     46K since last commit (82m)   logbook 22m   spend 3.1K/turn
#       next       "prove the excluded file never lands on the branch"   (logbook)
#   --line prints the first line only; --json prints every field as one JSON
#   object per crewmate. --leader lists the crewmates recorded under that
#   leader (the leader= line bin/fm-spawn.sh --leader writes); --all lists every
#   ship and scout task recorded in this home. A field that cannot be read
#   prints ? and never a number.
# What each field reads, and nothing else:
#   head, start, peak, turns, trims, last call, repeats, spend: the live transcript,
#     the newest line of data/<id>/sessions.log (bin/fm-session-event.sh writes
#     it from the claude SessionStart hook). Every assistant row's usage gives
#     the head (input + cache creation + cache read + output, the harness's own
#     count); start is the head at the first request, what the crewmate
#     carried before any work (the brief, the memory files, the launch);
#     a turn is one model request (assistant rows sharing one message
#     id are one turn); a trim is a compact_boundary row, and the head at a
#     trim is the last assistant usage before that row, never the row's
#     preTokens (bin/fm-compact-lib.sh says why); spend is the new tokens the
#     model processed (input + cache creation + output, cache reads excluded);
#     repeats looks at the last 30 tool calls for the same tool with the same
#     input three or more times (loop), the same file read five or more times
#     (reads), or an A-B-A-B alternation four times (alternates).
#   the status word: the state of the last line of state/<id>.status, an
#     EVENT, not current state; bin/fm-crew-state.sh owns the current state.
#   mark: trim_mark= in state/<id>.meta; a leader has none by design.
#   since last commit: the age of HEAD in the task's recorded worktree, and the
#     spend since that commit's time.
#   logbook: the age of data/<id>/logbook.md, or untouched while it is still
#     bin/fm-logbook-lib.sh's template; next: its first line under ## Next.
#   Nothing here reads the crewmate's own report, and nothing here stops,
#   warns or throttles anyone: the numbers judge the machinery, never the
#   worker. Stuck, loop and drift verdicts belong to the leader.
# FM_HOME must be explicit, exactly as for bin/fm-lead.sh; FM_STATE_OVERRIDE and
# FM_DATA_OVERRIDE point the directories elsewhere for tests, and FM_VITALS_NOW
# fixes the clock (epoch seconds) so ages are reproducible.
# Reads: state/<id>.meta, state/<id>.status, data/<id>/sessions.log, the
# transcript, the worktree's git log, data/<id>/logbook.md. Writes: nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-crew-vitals refuses to read a fleet without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required to read a transcript" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lead-lib.sh
. "$SCRIPT_DIR/fm-lead-lib.sh"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"
# fm_path_mtime, the fleet's portable mtime read (BSD stat -f, GNU stat -c;
# never the `-f || -c` fallback, because GNU `stat -f` is filesystem status
# and prints a dump instead of failing).
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FORMAT=card
SCOPE=
TARGET=
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    TARGET=$a; want_value=; continue
  fi
  case "$a" in
    --line) FORMAT=line ;;
    --json) FORMAT=json ;;
    --leader) SCOPE=leader; want_value=leader ;;
    --leader=*) SCOPE=leader; TARGET=${a#--leader=} ;;
    --all) SCOPE=all ;;
    --*) echo "error: unknown argument '$a'; see fm-crew-vitals.sh --help" >&2; exit 1 ;;
    *)
      [ -z "$TARGET" ] && [ -z "$SCOPE" ] || { echo "error: one task id, or --leader <id>, or --all" >&2; exit 1; }
      SCOPE=one; TARGET=$a ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --leader requires a value" >&2; exit 1; }
[ -n "$SCOPE" ] || { echo "error: a task id, --leader <id> or --all is required; see fm-crew-vitals.sh --help" >&2; exit 1; }
if [ -n "$TARGET" ]; then
  case "$TARGET" in
    *[!A-Za-z0-9._-]*|.|..) echo "error: '$TARGET' is not a task id" >&2; exit 1 ;;
  esac
fi

NOW=${FM_VITALS_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) echo "error: FM_VITALS_NOW must be epoch seconds" >&2; exit 1 ;; esac

age_of() {  # <epoch> -> 40s | 22m | 3h | 2d
  local then=$1 d
  case "$then" in ''|*[!0-9]*) printf '?'; return 0 ;; esac
  d=$((NOW - then))
  [ "$d" -ge 0 ] || d=0
  if [ "$d" -lt 90 ]; then printf '%ss' "$d"
  elif [ "$d" -lt 5400 ]; then printf '%sm' $(((d + 30) / 60))
  elif [ "$d" -lt 172800 ]; then printf '%sh' $(((d + 1800) / 3600))
  else printf '%sd' $(((d + 43200) / 86400)); fi
}

k_of() {  # <tokens> -> 91K | 3.1K | 512 | ?
  local n=$1 h
  case "$n" in ''|null|*[!0-9]*) printf '?'; return 0 ;; esac
  if [ "$n" -ge 9950 ]; then printf '%sK' $(((n + 500) / 1000))
  elif [ "$n" -ge 1000 ]; then h=$(((n + 50) / 100)); printf '%s.%sK' $((h / 10)) $((h % 10))
  else printf '%s' "$n"; fi
}

# The last status event's state word: "working [key=x]: note" -> working.
last_status_state() {  # <id>
  local f="$STATE/$1.status" line
  [ -f "$f" ] || { printf 'silent'; return 0; }
  line=$(tail -n 1 "$f" 2>/dev/null)
  [ -n "$line" ] || { printf 'silent'; return 0; }
  line=${line%%:*}
  line=${line%% *}
  [ -n "$line" ] || line='?'
  printf '%s' "$line"
}

live_transcript() {  # <id> -> path or empty
  local log="$DATA/$1/sessions.log" line
  [ -f "$log" ] || return 0
  line=$(tail -n 1 "$log" 2>/dev/null)
  printf '%s' "$line" | awk -F '\t' '{print $4}'
}

# One pass over the transcript. Every number the card shows comes out of this
# jq program as one JSON object; the shell only formats.
read_transcript() {  # <path> <commit-epoch|""> <logbook-epoch|"">
  local path=$1 commit_epoch=${2:-} logbook_epoch=${3:-}
  jq -R -n -c --arg commit "$commit_epoch" --arg logbook "$logbook_epoch" '
    def ts: (.timestamp // "") | if . == "" then null else (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) end;
    def total(u): ((u.input_tokens // 0) + (u.cache_creation_input_tokens // 0) + (u.cache_read_input_tokens // 0) + (u.output_tokens // 0));
    def fresh(u): ((u.input_tokens // 0) + (u.cache_creation_input_tokens // 0) + (u.output_tokens // 0));
    # The salient part of a call: the command, the file (with its offset, so a
    # big file read in chunks is not a repeat), the pattern, the prompt, else
    # the whole input. A tool description the model rewrites each time is not
    # part of it.
    def salient(t):
      (t.input // {}) as $i
      | if ($i.command? // null) != null then ($i.command | tostring)
        elif ($i.file_path? // null) != null then (($i.file_path | tostring) + (if ($i.offset? // null) != null then " @" + ($i.offset | tostring) else "" end))
        elif ($i.pattern? // null) != null then ($i.pattern | tostring)
        elif ($i.prompt? // null) != null then ($i.prompt | tostring)
        else ($i | tojson) end
      | gsub("\n"; " ");
    def sig(t): (t.name // "?") + " " + salient(t);
    def file_of(t): ((t.input // {}).file_path // "") | tostring;
    def short(t): salient(t) | .[0:60];
    def epoch_or_null($s): if $s == "" then null else ($s | tonumber) end;
    reduce (inputs | fromjson? // empty) as $r (
      {head: null, first_head: null, peak: 0, turns: 0, spend: 0, spend_since_commit: 0, spend_since_logbook: 0,
       last_msg: null, last_ts: null, trims: [], calls: [], rows: 0, last_head_before_boundary: null};
      .rows += 1
      | if $r.type == "assistant" and ($r.message.usage? // null) != null then
          ($r.message.usage) as $u
          | (total($u)) as $t
          | .head = $t
          | .first_head = (if .first_head == null then $t else .first_head end)
          | .peak = (if $t > .peak then $t else .peak end)
          | .last_ts = (($r | ts) // .last_ts)
          | (($r.message.id // $r.uuid // null)) as $mid
          | if $mid != .last_msg then
              .last_msg = $mid
              | .turns += 1
              | .spend += fresh($u)
              | (epoch_or_null($commit)) as $c
              | (epoch_or_null($logbook)) as $l
              | (($r | ts) // 0) as $rt
              | .spend_since_commit += (if $c != null and $rt > $c then fresh($u) else 0 end)
              | .spend_since_logbook += (if $l != null and $rt > $l then fresh($u) else 0 end)
            else . end
          | .calls += [ ($r.message.content // []) | if type == "array" then map(select(.type == "tool_use") | {name: (.name // "?"), sig: sig(.), file: file_of(.), short: short(.), ts: ($r | ts)}) else [] end ] | .calls |= flatten
          | .calls |= (if length > 30 then .[-30:] else . end)
        elif $r.type == "system" and $r.subtype == "compact_boundary" then
          .trims += [{trigger: ($r.compactMetadata.trigger // "?"), head_before: .head, pre: ($r.compactMetadata.preTokens // null), post: ($r.compactMetadata.postTokens // null), ts: ($r | ts)}]
        else . end
    )
    | .last_call = (if (.calls | length) > 0 then .calls[-1] else null end)
    | .calls as $c
    | (
        # loop: the same tool with the same input three or more times
        ($c | group_by(.sig) | map({sig: .[0].sig, name: .[0].name, short: .[0].short, n: length}) | map(select(.n >= 3)) | sort_by(-.n) | .[0] // null) as $loop
        # reads: the same file read five or more times
        | ($c | map(select(.name == "Read" and .file != "")) | group_by(.file) | map({short: (.[0].file | .[0:60]), n: length}) | map(select(.n >= 5)) | sort_by(-.n) | .[0] // null) as $reads
        # alternates: A-B-A-B four times in a row
        | ([range(0; ($c | length) - 7)] | map(. as $i | $c[$i:$i+8] | map(.sig) | select(.[0] != .[1] and .[0] == .[2] and .[2] == .[4] and .[4] == .[6] and .[1] == .[3] and .[3] == .[5] and .[5] == .[7]) | {a: $c[$i], b: $c[$i+1]}) | .[-1] // null) as $alt
        # An A-B-A-B bounce also repeats A four times; the bounce is the better name.
        | .repeats = (
            if $alt != null then {kind: "alternates", n: 4, what: ($alt.a.name + " " + $alt.a.short + " / " + $alt.b.name + " " + $alt.b.short)}
            elif $loop != null then {kind: "loop", n: $loop.n, what: ($loop.name + " " + $loop.short)}
            elif $reads != null then {kind: "reads", n: $reads.n, what: $reads.short}
            else {kind: "none", n: 0, what: ""} end)
      )
    | del(.last_msg) | del(.calls)
  ' "$path" 2>/dev/null
}

vitals_json() {  # <id> -> one JSON object on stdout
  local id=$1 meta status mark worktree commit_epoch commit_age logbook logbook_epoch logbook_state next transcript tj
  meta="$STATE/$id.meta"
  status=$(last_status_state "$id")
  mark=$(fm_meta_get "$meta" trim_mark)
  worktree=$(fm_meta_get "$meta" worktree)
  commit_epoch=
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    commit_epoch=$(git -C "$worktree" log -1 --format=%ct HEAD 2>/dev/null || true)
    case "$commit_epoch" in *[!0-9]*) commit_epoch= ;; esac
  fi
  logbook=$(fm_logbook_path "$DATA" "$id")
  logbook_epoch=
  logbook_state=missing
  next=
  if [ -f "$logbook" ]; then
    logbook_epoch=$(fm_path_mtime "$logbook")
    if [ "$(cat "$logbook")" = "$(fm_logbook_template "$id")" ]; then
      logbook_state=untouched
    else
      logbook_state=written
      next=$(awk '/^## Next/{f=1; next} /^## /{f=0} f && NF {print; exit}' "$logbook" | sed 's/^[-*] *//')
    fi
  fi
  transcript=$(live_transcript "$id")
  tj=
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    tj=$(read_transcript "$transcript" "$commit_epoch" "$logbook_epoch")
  fi
  [ -n "$tj" ] || tj='null'
  jq -n -c \
    --arg id "$id" --arg status "$status" --arg mark "$mark" --arg worktree "$worktree" \
    --arg commit_epoch "$commit_epoch" --arg logbook_epoch "$logbook_epoch" --arg logbook_state "$logbook_state" \
    --arg next "$next" --arg transcript "$transcript" --argjson t "$tj" --argjson now "$NOW" '
    def num($s): if $s == "" then null else ($s | tonumber) end;
    {
      id: $id,
      status: $status,
      transcript: (if $transcript == "" then null else $transcript end),
      head: ($t.head // null),
      start: ($t.first_head // null),
      peak: (if $t == null then null else $t.peak end),
      mark: (num($mark)),
      turns: (if $t == null then null else $t.turns end),
      trims: (if $t == null then null else ($t.trims | map({trigger, head_before, pre, post, ts})) end),
      last_call: (if $t == null then null else $t.last_call end),
      last_call_age: (if $t == null or $t.last_call == null or $t.last_call.ts == null then null else ($now - $t.last_call.ts) end),
      repeats: (if $t == null then null else $t.repeats end),
      spend: (if $t == null then null else $t.spend end),
      spend_per_turn: (if $t == null or $t.turns == 0 then null else (($t.spend / $t.turns) | floor) end),
      commit_epoch: (num($commit_epoch)),
      commit_age: (if $commit_epoch == "" then null else ($now - ($commit_epoch | tonumber)) end),
      spend_since_commit: (if $t == null or $commit_epoch == "" then null else $t.spend_since_commit end),
      logbook: $logbook_state,
      logbook_epoch: (num($logbook_epoch)),
      logbook_age: (if $logbook_epoch == "" then null else ($now - ($logbook_epoch | tonumber)) end),
      spend_since_logbook: (if $t == null or $logbook_epoch == "" then null else $t.spend_since_logbook end),
      next: (if $next == "" then null else $next end),
      worktree: (if $worktree == "" then null else $worktree end),
      now: $now
    }'
}

print_card() {  # <json> <card|line>
  local j=$1 fmt=$2 id status head start peak mark turns trims_n trims_auto trims_manual trims_word
  local call_name call_short call_age rep_kind rep_n rep_what rep_word spend_c commit_age logbook logbook_age rate next
  id=$(printf '%s' "$j" | jq -r '.id')
  status=$(printf '%s' "$j" | jq -r '.status')
  head=$(k_of "$(printf '%s' "$j" | jq -r '.head // empty')")
  start=$(k_of "$(printf '%s' "$j" | jq -r '.start // empty')")
  peak=$(k_of "$(printf '%s' "$j" | jq -r '.peak // empty')")
  mark=$(printf '%s' "$j" | jq -r '.mark // empty')
  if [ -n "$mark" ]; then mark=$(k_of "$mark"); else mark=none; fi
  turns=$(printf '%s' "$j" | jq -r '.turns // "?"')
  trims_n=$(printf '%s' "$j" | jq -r '.trims | if . == null then "?" else length end')
  if [ "$trims_n" = "?" ]; then
    trims_word='?'
  elif [ "$trims_n" -eq 0 ]; then
    trims_word='0'
  else
    trims_auto=$(printf '%s' "$j" | jq -r '[.trims[] | select(.trigger == "auto")] | length')
    trims_manual=$(printf '%s' "$j" | jq -r '[.trims[] | select(.trigger == "manual")] | length')
    if [ "$trims_manual" -eq 0 ]; then trims_word="$trims_n auto"
    elif [ "$trims_auto" -eq 0 ]; then trims_word="$trims_n manual"
    else trims_word="$trims_n ($trims_auto auto, $trims_manual manual)"; fi
  fi
  printf '%s  %s  head %s (start %s, peak %s, mark %s)  trims %s  turns %s\n' "$id" "$status" "$head" "$start" "$peak" "$mark" "$trims_word" "$turns"
  [ "$fmt" = line ] && return 0
  call_name=$(printf '%s' "$j" | jq -r '.last_call.name // empty')
  if [ -n "$call_name" ]; then
    call_short=$(printf '%s' "$j" | jq -r '.last_call.short // ""')
    call_age=$(age_of "$(printf '%s' "$j" | jq -r '.last_call.ts // empty')")
    printf "  last call  %s \`%s\`  %s ago" "$call_name" "$call_short" "$call_age"
  else
    printf '  last call  ?'
  fi
  rep_kind=$(printf '%s' "$j" | jq -r '.repeats.kind // "?"')
  case "$rep_kind" in
    none) rep_word='repeats none' ;;
    '?') rep_word='repeats ?' ;;
    *) rep_n=$(printf '%s' "$j" | jq -r '.repeats.n'); rep_what=$(printf '%s' "$j" | jq -r '.repeats.what'); rep_word="$rep_kind ${rep_n}x $rep_what" ;;
  esac
  printf '    %s\n' "$rep_word"
  spend_c=$(k_of "$(printf '%s' "$j" | jq -r '.spend_since_commit // empty')")
  commit_age=$(age_of "$(printf '%s' "$j" | jq -r '.commit_epoch // empty')")
  logbook=$(printf '%s' "$j" | jq -r '.logbook')
  case "$logbook" in
    written) logbook_age=$(age_of "$(printf '%s' "$j" | jq -r '.logbook_epoch // empty')") ;;
    untouched) logbook_age=untouched ;;
    *) logbook_age='?' ;;
  esac
  rate=$(k_of "$(printf '%s' "$j" | jq -r '.spend_per_turn // empty')")
  printf '  tokens     %s since last commit (%s)   logbook %s   spend %s/turn\n' "$spend_c" "$commit_age" "$logbook_age" "$rate"
  next=$(printf '%s' "$j" | jq -r '.next // empty')
  if [ -n "$next" ]; then
    printf '  next       "%s"   (logbook)\n' "$next"
  else
    printf '  next       -   (nothing under ## Next in the logbook)\n'
  fi
}

ids=
case "$SCOPE" in
  one)
    [ -f "$STATE/$TARGET.meta" ] || { echo "error: no task record for $TARGET in this home (state/$TARGET.meta)" >&2; exit 1; }
    ids=$TARGET ;;
  leader)
    [ -f "$STATE/$TARGET.meta" ] || { echo "error: no task record for $TARGET in this home (state/$TARGET.meta)" >&2; exit 1; }
    ids=$(fm_lead_crew_of "$STATE" "$TARGET")
    [ -n "$ids" ] || { echo "no crewmates recorded under $TARGET" >&2; exit 0; } ;;
  all)
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      case "$(fm_meta_get "$meta" kind)" in ship|scout) ids="$ids$(basename "$meta" .meta)"$'\n' ;; esac
    done
    ids=$(printf '%s' "$ids" | sort)
    [ -n "$ids" ] || { echo "no ship or scout task recorded in this home" >&2; exit 0; } ;;
esac

first=1
while IFS= read -r id; do
  [ -n "$id" ] || continue
  j=$(vitals_json "$id")
  case "$FORMAT" in
    json) printf '%s\n' "$j" ;;
    line) print_card "$j" line ;;
    *)
      [ "$first" -eq 1 ] || printf '\n'
      print_card "$j" card ;;
  esac
  first=0
done <<EOF
$ids
EOF
exit 0
