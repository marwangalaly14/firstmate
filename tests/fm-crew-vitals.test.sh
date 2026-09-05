#!/usr/bin/env bash
# tests/fm-crew-vitals.test.sh - one card per crewmate, from the outside.
#
# bin/fm-crew-vitals.sh reads the live transcript named by data/<id>/sessions.log,
# the last status event, the task record, the worktree's last commit and the
# logbook, and prints a four-line card (or --line, or --json) whose every number
# is reproducible from synthetic inputs under a fixed clock (FM_VITALS_NOW).
# A field that cannot be read prints ? and never a number.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-logbook-lib.sh
. "$ROOT/bin/fm-logbook-lib.sh"
# shellcheck source=tests/transcript-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/transcript-helpers.sh"

VITALS="$ROOT/bin/fm-crew-vitals.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-vitals)
NOW=1757100000   # 2026-09-05T19:20:00Z, the fixed clock every case runs under

# A home with one recorded task and its inputs.
make_home() {  # <name> -> home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

write_task() {  # <home> <id> <kind> [meta lines...]
  local home=$1 id=$2 kind=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=$kind" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
}

point_transcript() {  # <home> <id> <transcript-path>
  printf '%s\tstartup\ts-%s\t%s\t?\t?\n' "$((NOW - 3600))" "$2" "$3" >> "$1/data/$2/sessions.log"
}

run_vitals() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_VITALS_NOW="$NOW" "$VITALS" "$@" 2>&1
}

# --- the full card with known numbers ----------------------------------------

test_known_transcript_yields_the_exact_card() {
  local home t wt out expected j
  home=$(make_home exact)
  wt="$home/wt-c1"
  make_worktree "$wt" $((NOW - 4920))           # last commit 82 minutes ago
  write_task "$home" c1 ship "worktree=$wt" "trim_mark=140000"
  printf 'working: setup done\nworking [key=half]: half the story\n' > "$home/state/c1.status"
  t="$home/c1.jsonl"
  {
    row_noise
    row_user $((NOW - 7000))
    # three requests before the trim: heads 60000, 90000, 138000 (the peak)
    row_assistant $((NOW - 6900)) m1 50000 0 0 10000 "$(tool_bash 'npm install')"
    row_assistant $((NOW - 6000)) m2 1000 79000 0 10000 "$(tool_read /w/a.md)"
    row_assistant $((NOW - 5000)) m3 8000 0 120000 10000 "$(tool_bash 'bash tests/fm-spawn.test.sh')"
    row_boundary $((NOW - 4990)) auto 152000 20000
    # after the trim and after the commit at NOW-4920: two requests, head 91000
    row_assistant $((NOW - 3000)) m4 20000 0 0 1000 "$(tool_bash 'git status')"
    # a split message: two rows, one usage, one turn
    row_assistant $((NOW - 40)) m5 25000 0 65000 1000 "$(tool_bash 'bash tests/fm-spawn.test.sh')"
    row_assistant $((NOW - 40)) m5 25000 0 65000 1000
  } > "$t"
  point_transcript "$home" c1 "$t"
  fm_logbook_init "$home/data" c1
  printf '# Logbook: c1\n\n## Done\n- half\n\n## Next\n- prove the excluded file never lands on the branch\n- then the rest\n\n## Open\n\n## Decisions\n' > "$(fm_logbook_path "$home/data" c1)"
  set_mtime "$(fm_logbook_path "$home/data" c1)" $((NOW - 1320))   # 22 minutes ago
  out=$(run_vitals "$home" c1) || fail "vitals must succeed:"$'\n'"$out"
  # shellcheck disable=SC2016 # The backticks are the card's own text, not a command.
  expected='c1  working  head 91K (start 60K, peak 138K, mark 140K)  trims 1 auto  turns 5
  last call  Bash `bash tests/fm-spawn.test.sh`  40s ago    repeats none
  tokens     47K since last commit (82m)   logbook 22m   spend 43K/turn
  next       "prove the excluded file never lands on the branch"   (logbook)'
  [ "$out" = "$expected" ] || fail "the card must match exactly; got:"$'\n'"$out"$'\n'"expected:"$'\n'"$expected"
  out=$(run_vitals "$home" c1 --line) || fail "--line must succeed"
  [ "$out" = 'c1  working  head 91K (start 60K, peak 138K, mark 140K)  trims 1 auto  turns 5' ] || fail "--line is the first line, got: $out"
  j=$(run_vitals "$home" c1 --json) || fail "--json must succeed"
  [ "$(printf '%s' "$j" | jq -r '.head')" = 91000 ] || fail "json head, got $(printf '%s' "$j" | jq -r '.head')"
  [ "$(printf '%s' "$j" | jq -r '.peak')" = 138000 ] || fail "json peak"
  [ "$(printf '%s' "$j" | jq -r '.start')" = 60000 ] || fail "json start is the head at the first request, got $(printf '%s' "$j" | jq -r '.start')"
  [ "$(printf '%s' "$j" | jq -r '.turns')" = 5 ] || fail "json turns count requests, not rows"
  [ "$(printf '%s' "$j" | jq -r '.trims[0].head_before')" = 138000 ] || fail "the head at the trim is the last usage before the row, not preTokens (got $(printf '%s' "$j" | jq -r '.trims[0].head_before'))"
  [ "$(printf '%s' "$j" | jq -r '.trims[0].pre')" = 152000 ] || fail "preTokens is kept as the harness's own number"
  [ "$(printf '%s' "$j" | jq -r '.spend')" = 215000 ] || fail "spend excludes cache reads, got $(printf '%s' "$j" | jq -r '.spend')"
  [ "$(printf '%s' "$j" | jq -r '.spend_since_commit')" = 47000 ] || fail "spend since the commit counts requests after it, got $(printf '%s' "$j" | jq -r '.spend_since_commit')"
  [ "$(printf '%s' "$j" | jq -r '.spend_since_logbook')" = 26000 ] || fail "spend since the logbook change, got $(printf '%s' "$j" | jq -r '.spend_since_logbook')"
  [ "$(printf '%s' "$j" | jq -r '.last_call_age')" = 40 ] || fail "last call age"
  [ "$(printf '%s' "$j" | jq -r '.status')" = working ] || fail "status word"
  pass "a transcript with known numbers yields the exact card, line and json: head, peak, mark, one auto trim with the head before it, five turns from six rows, the last call and its age, spend since the commit and the logbook, the logbook's next line"
}

# --- the ? fields and the plain cases ------------------------------------------

test_no_boundary_missing_transcript_and_leader_mark() {
  local home t out j
  home=$(make_home plain)
  write_task "$home" p1 ship "trim_mark=140000"
  t="$home/p1.jsonl"
  { row_assistant $((NOW - 100)) m1 1000 0 0 100; row_assistant $((NOW - 50)) m2 2000 0 0 100 "$(tool_bash 'ls')"; } > "$t"
  point_transcript "$home" p1 "$t"
  out=$(run_vitals "$home" p1 --line) || fail "p1 must succeed"
  assert_contains "$out" "trims 0" "no boundary rows yields trims 0"
  assert_contains "$out" "head 2.1K (start 1.1K, peak 2.1K, mark 140K)" "small heads print with a decimal"
  assert_contains "$out" "p1  silent" "no status file prints silent"
  out=$(run_vitals "$home" p1)
  assert_contains "$out" "logbook ?" "a missing logbook prints ?"
  assert_contains "$out" "since last commit (?)" "no worktree prints ? for the commit age"
  assert_contains "$out" 'next       -' "no logbook means nothing under Next"
  # A task with no session record at all (another harness, or an older task).
  write_task "$home" p2 scout
  printf 'blocked [key=x]: waiting\n' > "$home/state/p2.status"
  out=$(run_vitals "$home" p2) || fail "p2 must succeed"
  assert_contains "$out" "p2  blocked  head ? (start ?, peak ?, mark none)  trims ?  turns ?" "no transcript prints ? for every transcript field and mark none without a mark"
  assert_contains "$out" "last call  ?" "no transcript, no last call"
  assert_contains "$out" "repeats ?" "no transcript, no repeats"
  j=$(run_vitals "$home" p2 --json)
  [ "$(printf '%s' "$j" | jq -r '.head')" = null ] || fail "json head is null, never a number, without a transcript"
  # A session record pointing at a transcript that is gone.
  write_task "$home" p3 ship "trim_mark=140000"
  point_transcript "$home" p3 "$home/gone.jsonl"
  out=$(run_vitals "$home" p3 --line)
  assert_contains "$out" "head ?" "a missing transcript file prints head ?"
  # A leader: same card, mark none, and its logbook untouched while it is the template.
  write_task "$home" L1 ship "leads=1"
  fm_logbook_init "$home/data" L1
  point_transcript "$home" L1 "$t"
  out=$(run_vitals "$home" L1)
  assert_contains "$out" "mark none" "a leader has no mark by design"
  assert_contains "$out" "logbook untouched" "the template counts as untouched"
  pass "no boundary rows print trims 0; a task without a session record, and one whose transcript is gone, print ? and json null; a leader prints mark none; an untouched logbook says so"
}

# --- repeats -------------------------------------------------------------------

test_head_rounds_to_the_nearest_hundred_across_a_thousand() {
  local home t out
  home=$(make_home rounding)
  write_task "$home" r1 ship "trim_mark=140000"
  t="$home/r1.jsonl"
  row_assistant $((NOW - 50)) m1 1850 0 0 100 > "$t"
  point_transcript "$home" r1 "$t"
  out=$(run_vitals "$home" r1 --line) || fail "r1 must succeed"
  assert_contains "$out" "head 2.0K (start 2.0K, peak 2.0K" "1950 tokens read 2.0K, not 1.0K"
  write_task "$home" r2 ship "trim_mark=140000"
  t="$home/r2.jsonl"
  row_assistant $((NOW - 50)) m1 9899 0 0 100 > "$t"
  point_transcript "$home" r2 "$t"
  out=$(run_vitals "$home" r2 --line) || fail "r2 must succeed"
  assert_contains "$out" "head 10K (start 10K, peak 10K" "9999 tokens read 10K, not 9.0K"
  pass "a head whose hundreds round up past 9 carries into the thousands: 1950 is 2.0K and 9999 is 10K"
}

test_planted_repeats_are_named() {
  local home t out i
  home=$(make_home repeats)
  # A loop: the same command six times.
  write_task "$home" r1 ship
  t="$home/r1.jsonl"
  {
    row_assistant $((NOW - 900)) m0 1000 0 0 10 "$(tool_bash 'ls')"
    for i in 1 2 3 4 5 6; do row_assistant $((NOW - 800 + i)) "m$i" 1000 0 0 10 "$(tool_bash 'npm test' "attempt $i")"; done
  } > "$t"
  point_transcript "$home" r1 "$t"
  out=$(run_vitals "$home" r1)
  assert_contains "$out" 'loop 6x Bash npm test' "six identical commands with different descriptions are one loop"
  # Chunked reads of one big file: not a loop, but five reads of the same file are named.
  write_task "$home" r2 ship
  t="$home/r2.jsonl"
  { for i in 1 2 3 4 5; do row_assistant $((NOW - 700 + i)) "m$i" 1000 0 0 10 "$(tool_read /w/big.md $((i * 2000)))"; done; } > "$t"
  point_transcript "$home" r2 "$t"
  out=$(run_vitals "$home" r2)
  assert_contains "$out" 'reads 5x /w/big.md' "five reads of one file at different offsets are named as reads, not a loop"
  # Four reads of the same file: nothing yet.
  write_task "$home" r3 ship
  t="$home/r3.jsonl"
  { for i in 1 2 3 4; do row_assistant $((NOW - 600 + i)) "m$i" 1000 0 0 10 "$(tool_read /w/big.md $((i * 2000)))"; done; } > "$t"
  point_transcript "$home" r3 "$t"
  out=$(run_vitals "$home" r3)
  assert_contains "$out" 'repeats none' "four chunked reads are not a repeat"
  # An A-B-A-B alternation four times.
  write_task "$home" r4 ship
  t="$home/r4.jsonl"
  { for i in 1 2 3 4; do
      row_assistant $((NOW - 500 + i * 2)) "ma$i" 1000 0 0 10 "$(tool_bash 'make build')"
      row_assistant $((NOW - 499 + i * 2)) "mb$i" 1000 0 0 10 "$(tool_read /w/Makefile)"
    done; } > "$t"
  point_transcript "$home" r4 "$t"
  out=$(run_vitals "$home" r4)
  assert_contains "$out" 'alternates 4x Bash make build / Read /w/Makefile' "an A-B-A-B alternation four times is named"
  # Only the last 30 calls count: an old loop scrolled out is forgotten.
  write_task "$home" r5 ship
  t="$home/r5.jsonl"
  {
    for i in 1 2 3; do row_assistant $((NOW - 400 + i)) "m$i" 1000 0 0 10 "$(tool_bash 'npm test')"; done
    for i in $(seq 1 30); do row_assistant $((NOW - 300 + i)) "n$i" 1000 0 0 10 "$(tool_bash "echo $i")"; done
  } > "$t"
  point_transcript "$home" r5 "$t"
  out=$(run_vitals "$home" r5)
  assert_contains "$out" 'repeats none' "a loop older than the last 30 calls is not reported"
  pass "a planted loop, five reads of one file, an A-B-A-B alternation are named; four chunked reads and a loop older than 30 calls are not"
}

# --- growth, partial lines, scopes -------------------------------------------

test_growth_changes_only_what_changed_and_partial_lines_are_skipped() {
  local home t j1 j2 changed
  home=$(make_home growth)
  write_task "$home" g1 ship "trim_mark=140000"
  t="$home/g1.jsonl"
  { row_assistant $((NOW - 200)) m1 1000 0 0 100 "$(tool_bash 'ls')"; row_assistant $((NOW - 150)) m2 2000 0 0 100; } > "$t"
  point_transcript "$home" g1 "$t"
  j1=$(run_vitals "$home" g1 --json)
  row_assistant $((NOW - 20)) m3 3000 0 0 100 "$(tool_bash 'pwd')" >> "$t"
  j2=$(run_vitals "$home" g1 --json)
  changed=$(jq -r -n --argjson a "$j1" --argjson b "$j2" '[$a | keys[] | select($a[.] != $b[.])] | sort | join(" ")')
  # m2 ended its turn (a text row); m3 is a call in flight, so busy and quiet_for move too.
  [ "$changed" = "busy head last_call last_call_age peak quiet_for spend spend_per_turn turns" ] \
    || fail "a grown transcript changes only the fields that changed, got: $changed"
  # A half-written trailing line (the harness mid-append) is skipped, not fatal.
  printf '{"type":"assistant","uuid":"partial","timestamp":"2026-09' >> "$t"
  [ "$(run_vitals "$home" g1 --json | jq -c 'del(.now)')" = "$(printf '%s' "$j2" | jq -c 'del(.now)')" ] \
    || fail "a partial trailing line must not change the numbers or fail the read"
  pass "a transcript that grew changes only head, peak, turns, spend, rate, the last call and busy/quiet_for; a partial trailing line is skipped"
}

test_scopes_and_refusals() {
  local home t out
  home=$(make_home scopes)
  t="$home/t.jsonl"
  row_assistant $((NOW - 10)) m1 1000 0 0 10 > "$t"
  write_task "$home" L1 ship "leads=1"
  write_task "$home" a1 ship "leader=L1" "trim_mark=140000"
  write_task "$home" a2 scout "leader=L1" "trim_mark=140000"
  write_task "$home" b1 ship "trim_mark=140000"
  write_task "$home" sm secondmate
  for id in L1 a1 a2 b1; do point_transcript "$home" "$id" "$t"; done
  out=$(run_vitals "$home" --leader L1 --line) || fail "--leader must succeed"
  [ "$(printf '%s\n' "$out" | cut -d' ' -f1 | tr '\n' ' ')" = "a1 a2 " ] || fail "--leader lists the leader's crewmates in id order, got:"$'\n'"$out"
  out=$(run_vitals "$home" --all --line) || fail "--all must succeed"
  [ "$(printf '%s\n' "$out" | cut -d' ' -f1 | tr '\n' ' ')" = "L1 a1 a2 b1 " ] || fail "--all lists every ship and scout task, never a secondmate, got:"$'\n'"$out"
  out=$(run_vitals "$home" --all)
  [ "$(printf '%s\n' "$out" | grep -c '^$')" -eq 3 ] || fail "cards are separated by one blank line"
  out=$(run_vitals "$home" --leader b1 --line); status=$?
  [ "$status" -eq 0 ] || fail "a leader without crewmates exits 0"
  assert_contains "$out" "no crewmates recorded under b1" "a leader without crewmates says so"
  out=$(run_vitals "$home" nope) && fail "an unknown id must be refused"
  assert_contains "$out" "no task record for nope" "the refusal names the missing record"
  out=$(FM_VITALS_NOW="$NOW" "$VITALS" a1 2>&1) && fail "a missing FM_HOME must be refused"
  assert_contains "$out" "FM_HOME is not set" "the refusal names FM_HOME"
  out=$(run_vitals "$home" a1 --bogus) && fail "an unknown flag must be refused"
  out=$(run_vitals "$home" 'a;b') && fail "a bad id must be refused"
  out=$("$VITALS" --help) || fail "--help exits 0"
  assert_contains "$out" "one card per crewmate" "--help prints the header"
  pass "--leader lists a leader's crewmates, --all every ship and scout task and no secondmate, cards are blank-line separated, and a missing home, record, or bad argument is refused"
}

test_known_transcript_yields_the_exact_card
test_no_boundary_missing_transcript_and_leader_mark
test_head_rounds_to_the_nearest_hundred_across_a_thousand
test_planted_repeats_are_named
test_growth_changes_only_what_changed_and_partial_lines_are_skipped
test_scopes_and_refusals

echo "# all fm-crew-vitals tests passed"
