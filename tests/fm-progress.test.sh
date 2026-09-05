#!/usr/bin/env bash
# tests/fm-progress.test.sh - the epic branch leader's progress report and the
# fleet bar.
#
# bin/fm-progress.sh scaffold prints the six parts every leader reports in -
# the goal line in the captain's words, a twenty-cell bar in a code block with
# the estimate as a percentage, DONE ticked, IN FLIGHT unticked with who holds
# it, QUEUED FILED BY NAME, and "What the bar means" - from the leader's brief,
# its own logbook and the crewmates' cards, never from a crewmate's words. fleet
# rolls every leader's saved report into one bar of the same shape. bar renders
# the cells. A report, never a gate: nothing here refuses a leader for its
# numbers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/transcript-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/transcript-helpers.sh"

PROGRESS="$ROOT/bin/fm-progress.sh"
TMP_ROOT=$(fm_test_tmproot fm-progress)
NOW=$(date +%s)
HOME_DIR="$TMP_ROOT/none-yet"; STATE="$HOME_DIR/state"; DATA="$HOME_DIR/data"
mkdir -p "$STATE" "$DATA"

write_task() {  # <home> <id> [meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
}

make_home() {  # <name>: HOME_DIR, STATE, DATA
  HOME_DIR="$TMP_ROOT/$1"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  mkdir -p "$STATE" "$DATA"
}

run_progress() {  # [args...]: sets RC, OUT, ERR
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$PROGRESS" "$@" 2> "$HOME_DIR/err")
  RC=$?
  ERR=$(cat "$HOME_DIR/err")
}

# The order of the six parts, as line numbers; fails when one is missing.
part_line() {  # <fixed string>
  printf '%s\n' "$OUT" | grep -n -F -m1 -- "$1" | cut -d: -f1
}

test_bar_renders_twenty_cells() {
  run_progress bar 45
  [ "$OUT" = "[#########...........] 45%" ] || fail "45% is nine of twenty cells, got '$OUT'"
  run_progress bar 0
  [ "$OUT" = "[....................] 0%" ] || fail "0% is an empty bar, got '$OUT'"
  run_progress bar 100
  [ "$OUT" = "[####################] 100%" ] || fail "100% is a full bar, got '$OUT'"
  run_progress bar 3
  [ "$OUT" = "[#...................] 3%" ] || fail "3% rounds to one cell, got '$OUT'"
  run_progress bar 101
  [ "$RC" -eq 1 ] && [ -z "$OUT" ] || fail "101 is refused, got rc=$RC '$OUT'"
  run_progress bar half
  [ "$RC" -eq 1 ] || fail "a word is refused"
  pass "bar renders twenty cells from a whole percentage, rounding to the nearest cell, and refuses anything else"
}

test_scaffold_carries_the_six_parts() {
  local goal bar done_line flight queued means t
  make_home six
  write_task "$HOME_DIR" lead-a "leads=1"
  write_task "$HOME_DIR" c1 "leader=lead-a"
  write_task "$HOME_DIR" c2 "leader=lead-a"
  write_task "$HOME_DIR" u1
  cat > "$DATA/lead-a/brief.md" <<'EOF'
You are crewmate `lead-a`.

# Task
## Captain's intent
The branch leader manages its crewmates' memory.
More words the captain said.

## Firstmate spec
Build it small.
EOF
  cat > "$DATA/lead-a/logbook.md" <<'EOF'
# Logbook: lead-a

## Done
- Crewmates trim at the 140K line with a keep-set (7ea43a4), proved live.
- A leader's steer lands in the crewmate's inbox and is measured (landed 99e8821 after a6d3c9e).

## Next
- Ring the leader from the transcript on a stall or a loop.

## Open
- Whether the fleet bar weights by size.

## Decisions
- Measurement, never enforcement.
EOF
  # c1 has a transcript (a card); c2 has none.
  t="$HOME_DIR/c1.jsonl"
  row_assistant $((NOW - 120)) m1 60000 0 0 200 "$(tool_bash 'ls')" > "$t"
  printf '%s\tstartup\ts-c1\t%s\t?\t?\n' "$((NOW - 3600))" "$t" > "$DATA/c1/sessions.log"
  make_worktree "$HOME_DIR/wt-c1" $((NOW - 600))
  printf 'worktree=%s\n' "$HOME_DIR/wt-c1" >> "$STATE/c1.meta"
  printf 'working: on the fresh head\n' > "$STATE/c1.status"
  # A crewmate's own words never enter the report.
  printf '# Logbook: c1\n\n## Done\n- everything is finished and green\n\n## Next\n- open the PR\n' > "$DATA/c1/logbook.md"

  run_progress scaffold lead-a --estimate 45
  [ "$RC" -eq 0 ] || fail "scaffold exits 0, got $RC: $ERR"
  goal=$(part_line "Goal: The branch leader manages its crewmates' memory.")
  bar=$(part_line "[#########...........] 45%")
  done_line=$(part_line "DONE")
  flight=$(part_line "IN FLIGHT")
  queued=$(part_line "QUEUED, FILED BY NAME")
  means=$(part_line "What the bar means:")
  [ -n "$goal" ] && [ -n "$bar" ] && [ -n "$done_line" ] && [ -n "$flight" ] && [ -n "$queued" ] && [ -n "$means" ] \
    || fail "the six parts are all present (goal=$goal bar=$bar done=$done_line flight=$flight queued=$queued means=$means):"$'\n'"$OUT"
  [ "$goal" -lt "$bar" ] && [ "$bar" -lt "$done_line" ] && [ "$done_line" -lt "$flight" ] && [ "$flight" -lt "$queued" ] && [ "$queued" -lt "$means" ] \
    || fail "the six parts come in the Hand's order, got goal=$goal bar=$bar done=$done_line flight=$flight queued=$queued means=$means"
  # 2. the bar sits in a code block
  [ "$(printf '%s\n' "$OUT" | sed -n "$((bar - 1))p")" = '```' ] && [ "$(printf '%s\n' "$OUT" | sed -n "$((bar + 1))p")" = '```' ] \
    || fail "the bar is in a code block:"$'\n'"$OUT"
  # 3. DONE: ticked, one per logbook line, commit ids struck out
  assert_contains "$OUT" "- [x] Crewmates trim at the 140K line with a keep-set, proved live." "a Done line is ticked with its commit id struck out"
  assert_contains "$OUT" "- [x] A leader's steer lands in the crewmate's inbox and is measured." "two commit ids in one line are both struck out"
  assert_not_contains "$OUT" "7ea43a4" "no commit id survives"
  assert_not_contains "$OUT" "99e8821" "no commit id survives (landed)"
  assert_not_contains "$OUT" "a6d3c9e" "no commit id survives (after)"
  [ "$(printf '%s\n' "$OUT" | grep -c '^- \[x\] ')" -eq 2 ] || fail "exactly the logbook's two Done lines are ticked"
  # 4. IN FLIGHT: unticked, the leader's Next line held by the leader, one line per crewmate held by it
  assert_contains "$OUT" "- [ ] Ring the leader from the transcript on a stall or a loop. - held by lead-a" "the leader's Next line is in flight, held by the leader"
  assert_contains "$OUT" "- [ ] {story} - next: {the next step} - held by c1 (head 60K, last commit 10m ago, last status working)" "a crewmate with a card is in flight with its numbers"
  assert_contains "$OUT" "- [ ] {story} - next: {the next step} - held by c2 (no card: the transcript has not begun)" "a crewmate without a card is still in flight"
  assert_not_contains "$OUT" "u1" "an unled task is not the leader's"
  assert_not_contains "$OUT" "everything is finished" "nothing a crewmate wrote enters the report"
  assert_not_contains "$OUT" "open the PR" "not the crewmate's next step either"
  # 5 and 6: the placeholders the leader fills
  assert_contains "$OUT" "- [ ] {a queued story, by name; group them; none started}" "queued stories are filed by name, none started"
  assert_contains "$OUT" "What the bar means: {what the epic can do today, in one or two sentences} {what the missing part buys}" "the closing paragraph names what to write"
  pass "a generated report carries the six parts in order: the goal in the captain's words, a twenty-cell bar in a code block, DONE ticked without commit ids, IN FLIGHT unticked with who holds it, QUEUED FILED BY NAME, and What the bar means; nothing a crewmate wrote enters it"
}

test_scaffold_without_inputs_says_what_is_missing() {
  make_home bare
  write_task "$HOME_DIR" lead-b "leads=1"
  run_progress scaffold lead-b
  [ "$RC" -eq 0 ] || fail "a leader with no records still gets a scaffold, got $RC: $ERR"
  assert_contains "$OUT" "[....................] ?%   <- give --estimate <pct>: your judgement of what is done, weighted by what is left, never by story count" "without an estimate the bar is empty and asks for one"
  assert_contains "$OUT" "Goal: {the goal the epic was given, in the captain's words - the brief's Captain's intent is empty}" "no brief, the goal is a placeholder"
  assert_contains "$OUT" "- [x] {nothing under ## Done in the logbook yet}" "no logbook, DONE says so"
  assert_contains "$OUT" "- [ ] {nothing under ## Next in the logbook and no crewmates recorded}" "no Next and no crewmates, IN FLIGHT says so"
  # A brief whose intent is still the scaffold's placeholder is not a goal.
  printf '# Task\n## Captain'"'"'s intent\n{TASK}\n\n## Firstmate spec\n' > "$DATA/lead-b/brief.md"
  run_progress scaffold lead-b --estimate 10
  assert_contains "$OUT" "Goal: {the goal the epic was given" "an unfilled intent is not a goal"
  run_progress scaffold lead-b --estimate 120
  [ "$RC" -eq 1 ] || fail "an estimate over 100 is refused, got rc=$RC"
  run_progress scaffold nobody --estimate 10
  [ "$RC" -eq 1 ] && [ -n "$ERR" ] || fail "an unrecorded leader is refused with a reason"
  run_progress scaffold
  [ "$RC" -eq 1 ] || fail "a missing leader id is refused"
  OUT=$(FM_STATE_OVERRIDE="$STATE" "$PROGRESS" scaffold lead-b 2>/dev/null); [ $? -eq 1 ] || fail "no FM_HOME, no report"
  pass "with no brief, logbook, estimate or crewmates the scaffold names each missing input; bad estimates, unknown leaders and a missing FM_HOME are refused"
}

# A commit id is a hex word that MIXES digits and a-f letters; a plain long
# number a leader's own line names is not one.
test_only_a_mixed_hex_word_is_struck_from_done() {
  local out
  make_home strike
  write_task "$HOME_DIR" lead-s "leads=1"
  cat > "$DATA/lead-s/logbook.md" <<'EOF'
# Logbook: lead-s

## Done
- Cut the crewmate's fresh head from 1560000 to 1400000 tokens.
- The order at epoch 1757100000 was typed into the pane.
- The keep-set landed in 7ea43a4, proved live.
- The steer is measured (99e8821).
EOF
  run_progress scaffold lead-s --estimate 20
  [ "$RC" -eq 0 ] || fail "scaffold exits 0, got $RC: $ERR"
  assert_contains "$OUT" "- [x] Cut the crewmate's fresh head from 1560000 to 1400000 tokens." \
    "a plain long number survives word for word: it is not a commit id"
  assert_contains "$OUT" "- [x] The order at epoch 1757100000 was typed into the pane." \
    "an epoch - what this project's own ledgers record - survives word for word"
  assert_contains "$OUT" "- [x] The keep-set landed, proved live." \
    "a mixed hex word is struck with the preposition that introduced it, leaving no double space"
  assert_contains "$OUT" "- [x] The steer is measured." \
    "a parenthesised commit id leaves no stray parenthesis or space before the stop"
  assert_not_contains "$OUT" "7ea43a4" "no commit id survives"
  assert_not_contains "$OUT" "99e8821" "nor a parenthesised one"
  pass "the DONE section strikes only a hex word that mixes digits and a-f letters: a plain long number and an epoch survive word for word, a real commit id goes with its preposition and leaves no double space or stray parenthesis"
}

test_fleet_rolls_the_leaders_bars_into_one() {
  local first fence
  make_home fleet
  write_task "$HOME_DIR" lead-a "leads=1"
  write_task "$HOME_DIR" lead-b "leads=1"
  write_task "$HOME_DIR" lead-c "leads=1"
  write_task "$HOME_DIR" c1 "leader=lead-a"
  fence='```'
  # lead-a has three stories done, lead-b one: a fleet bar weighted by story
  # count would read 50%; the mean of the two bars is 60%.
  printf 'Goal: The branch leader manages its crewmates memory.\n\n%s\n[########............] 40%%\n%s\n\nDONE\n- [x] one\n- [x] two\n- [x] three\n' "$fence" "$fence" > "$DATA/lead-a/progress.md"
  printf 'Goal: Extraction of the harness.\n\n%s\n[################....] 80%%\n%s\n\nDONE\n- [x] one\n' "$fence" "$fence" > "$DATA/lead-b/progress.md"
  run_progress fleet
  [ "$RC" -eq 0 ] || fail "fleet exits 0, got $RC: $ERR"
  assert_contains "$OUT" "Fleet: 3 epic branch leader(s), 2 with a saved report" "the count of leaders and reports"
  assert_contains "$OUT" "[############........] 60%" "the fleet bar is the mean of the saved bars, 40 and 80, never weighted by story count"
  first=$(printf '%s\n' "$OUT" | grep -n -F -m1 '[############........] 60%' | cut -d: -f1)
  [ "$(printf '%s\n' "$OUT" | sed -n "$((first - 1))p")" = '```' ] || fail "the fleet bar is in a code block"
  assert_contains "$OUT" "[########............] 40%  lead-a  The branch leader manages its crewmates memory." "each leader's bar, percentage and goal follow"
  assert_contains "$OUT" "[################....] 80%  lead-b  Extraction of the harness." "the second leader"
  assert_contains "$OUT" "[....................]  --%  lead-c  (no saved report: data/lead-c/progress.md has no bar line)" "a leader without a report is listed and left out of the mean"
  assert_not_contains "$OUT" "c1" "a crewmate is not a leader"
  # A home with no leaders says so and exits 0.
  make_home none
  write_task "$HOME_DIR" u1
  run_progress fleet
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "no leaders, nothing to roll up, got rc=$RC '$OUT'"
  assert_contains "$ERR" "no epic branch leaders recorded" "and it says so"
  pass "fleet rolls every leader's saved bar into one bar of the same shape, the plain mean, with one line per leader and the ones without a report named"
}

test_bar_renders_twenty_cells
test_scaffold_carries_the_six_parts
test_scaffold_without_inputs_says_what_is_missing
test_only_a_mixed_hex_word_is_struck_from_done
test_fleet_rolls_the_leaders_bars_into_one
