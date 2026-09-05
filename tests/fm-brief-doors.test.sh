#!/usr/bin/env bash
# tests/fm-brief-doors.test.sh - the crewmate's surface for the chain: its own
# id and brief path, the two doors upward, the leader named, the crewmate
# contract paragraph, the sub-agent reading habit, and not one word about the
# machinery that measures it.
#
# bin/fm-brief.sh's ship and scout scaffolds carry, right after the Task
# section, "# Your story, and the two times you speak up": the story-size
# pushback before beginning (needs-decision [key=story-size]) and the stuck
# door (blocked [key=stuck]), answered in the inbox by the leader that
# --leader names, or by First Mate when there is none. --leader accepts only
# a task recorded with leads=1 in this home's state. The crewmate contract
# paragraph says who the crewmate reports to, the landing order on a project
# that runs the loop, and the three commands never run on a session's own
# judgement. A secondmate charter carries none of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-doors)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Words that would tell the crewmate about the machinery that measures it.
MACHINERY_WORDS='trim|compact|context window|token|budget|ledger|telemetry|autoCompact|head size'

make_home() {  # <name>: sets HOME_DIR
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
}

scaffold() {  # <home> <id> <args...>: sets RC, OUT
  local home=$1
  shift
  OUT=$(FM_HOME="$home" "$BRIEF" "$@" 2>&1); RC=$?
}

doors_section() {  # <brief>: the doors section's lines
  awk '/^# Your story, and the two times you speak up$/{f=1; print; next} f && /^# /{exit} f' "$1"
}

# --- 1. the doors, right after the story, First Mate named without a leader ---
test_ship_and_scout_briefs_carry_the_two_doors() {
  local home id brief section status_file line_after_task
  make_home doors; home=$HOME_DIR
  status_file="'$home/state/ID.status'"
  for id_args in "d1:--mode no-mistakes" "d2:--mode direct-PR" "d3:--mode local-only" "d4:--scout"; do
    id=${id_args%%:*}
    # shellcheck disable=SC2086  # the args are a fixed word list
    scaffold "$home" "$id" proj ${id_args#*:}
    [ "$RC" -eq 0 ] || fail "$id: scaffold must exit 0:"$'\n'"$OUT"
    brief="$home/data/$id/brief.md"
    [ "$(grep -c -x '# Your story, and the two times you speak up' "$brief")" -eq 1 ] || fail "$id: exactly one doors section"
    # right after the Task section: the next top-level heading after "# Task" is the doors
    line_after_task=$(awk '/^# Task$/{f=1; next} f && /^# /{print; exit}' "$brief")
    [ "$line_after_task" = "# Your story, and the two times you speak up" ] || fail "$id: the doors must follow the Task section, got '$line_after_task'"
    section=$(doors_section "$brief")
    assert_contains "$section" "If this story is too big to be ONE story and you can see two smaller vertical ones, say so now and stop:" "$id: the first door is the story-size pushback before beginning"
    assert_contains "$section" "echo \"needs-decision: [key=story-size] {the two halves you see}\" >> ${status_file//ID/$id}" "$id: the first door's exact line, with this task's status file"
    assert_contains "$section" "Otherwise begin. From then on you do not surface until the story is done and self-verified," "$id: after the first door the crewmate works"
    assert_contains "$section" "except when you are stuck in a loop or drifting from the story:" "$id: the second door is stuck or drifting"
    assert_contains "$section" "echo \"blocked: [key=stuck] {what you tried, what you see}\" >> ${status_file//ID/$id}" "$id: the second door's exact line, with this task's status file"
    assert_contains "$section" "First Mate answers in your inbox." "$id: without a leader, First Mate answers"
    assert_not_contains "$section" "Your leader" "$id: no leader is named when none was given"
    [ "$(printf '%s\n' "$section" | grep -c -E 'key=')" -eq 2 ] || fail "$id: exactly two keyed doors, got:"$'\n'"$section"
    # One shape for blocked in the whole brief: every instruction to write a
    # blocked line (the door, rule 4, rule 5, rule 7, the isolation stop) is
    # the keyed stuck door, so whoever answers closes each with one key.
    [ "$(grep -c 'blocked: ' "$brief")" -ge 4 ] || fail "$id: the brief's blocked instructions, got:"$'\n'"$(grep -n 'blocked: ' "$brief")"
    [ "$(grep -c 'blocked: ' "$brief")" -eq "$(grep -c 'blocked: \[key=stuck\] ' "$brief")" ] \
      || fail "$id: blocked is spelled one way, the keyed stuck door, got:"$'\n'"$(grep -n 'blocked: ' "$brief" | grep -v 'key=stuck')"
  done
  pass "every ship mode and the scout scaffold carry the two doors right after the story, keyed story-size and stuck, with this task's status file, answered by First Mate when no leader is named; blocked is spelled one way in the whole brief"
}

# --- 2. --leader names a recorded leader, refuses anything else --------------
test_leader_is_named_and_must_be_a_recorded_leader() {
  local home brief section
  make_home leader; home=$HOME_DIR
  fm_write_meta "$home/state/lead-a.meta" "window=firstmate:fm-lead-a" "kind=ship" "leads=1"
  fm_write_meta "$home/state/plain.meta" "window=firstmate:fm-plain" "kind=ship"
  scaffold "$home" c1 proj --mode no-mistakes --leader lead-a
  [ "$RC" -eq 0 ] || fail "--leader naming a recorded leader must scaffold:"$'\n'"$OUT"
  brief="$home/data/c1/brief.md"
  section=$(doors_section "$brief")
  assert_contains "$section" "Your leader, \`lead-a\`, answers in your inbox; First Mate reaches you there only with lifecycle and the captain's words." "the leader is named as the one who answers"
  assert_not_contains "$section" "First Mate answers in your inbox." "with a leader, First Mate is not the one who answers"
  assert_contains "$(cat "$brief")" "same obstacle twice, append \`blocked: [key=stuck] {why}\` and stop; your leader will help." "rule 5 names the leader"
  assert_contains "$(cat "$brief")" "Your leader will reply with the decision." "rule 6 names the leader"
  assert_contains "$(cat "$brief")" "Your leader (\`lead-a\`) steers you through durable message files" "the inbox section names the leader as the one who steers"
  assert_contains "$(cat "$brief")" "First Mate reaches this inbox only with lifecycle actions and the captain's words." "the inbox section limits First Mate to lifecycle and the captain's words"
  assert_not_contains "$(cat "$brief")" "and firstmate steer you" "with a leader, First Mate does not steer the work"
  scaffold "$home" c2 proj --scout --leader lead-a
  [ "$RC" -eq 0 ] || fail "--leader on a scout must scaffold:"$'\n'"$OUT"
  assert_contains "$(doors_section "$home/data/c2/brief.md")" "Your leader, \`lead-a\`, answers" "a scout under a leader names it too"
  scaffold "$home" c3 proj --mode no-mistakes --leader plain
  [ "$RC" -ne 0 ] || fail "--leader naming a task without leads=1 must be refused"
  assert_contains "$OUT" "plain was not spawned as a leader (--leads)" "the refusal names the missing flag"
  [ ! -e "$home/data/c3/brief.md" ] || fail "a refused scaffold leaves no brief"
  scaffold "$home" c4 proj --mode no-mistakes --leader ghost
  [ "$RC" -ne 0 ] || fail "--leader naming a task with no record must be refused"
  assert_contains "$OUT" "ghost has no record in this home" "the refusal names the missing record"
  scaffold "$home" c5 proj --mode no-mistakes --leader
  [ "$RC" -ne 0 ] || fail "--leader without a value must be refused"
  scaffold "$home" sm1 --secondmate proj --leader lead-a
  [ "$RC" -ne 0 ] || fail "--leader on a secondmate charter must be refused"
  assert_contains "$OUT" "--leader applies only to crewmate ship or scout briefs" "the charter refusal says where --leader applies"
  pass "--leader names the recorded leader in the doors, rule 5, rule 6 and the inbox section; a task without leads=1, an unrecorded id, a missing value and a secondmate charter are refused"
}

# --- 3. the crewmate contract paragraph ---------------------------------------
test_crewmate_contract_paragraph() {
  local home id brief section
  make_home contract; home=$HOME_DIR
  for id_args in "k1:--mode no-mistakes" "k2:--mode direct-PR" "k3:--mode local-only" "k4:--scout"; do
    id=${id_args%%:*}
    # shellcheck disable=SC2086  # the args are a fixed word list
    scaffold "$home" "$id" proj ${id_args#*:}
    [ "$RC" -eq 0 ] || fail "$id: scaffold must exit 0:"$'\n'"$OUT"
    brief="$home/data/$id/brief.md"
    [ "$(grep -c -x '# Crewmate contract' "$brief")" -eq 1 ] || fail "$id: exactly one crewmate contract section"
    section=$(awk '/^# Crewmate contract$/{f=1; print; next} f && /^# /{exit} f' "$brief")
    assert_contains "$section" "You report to your leader or to First Mate, never to the captain" "$id: who the crewmate reports to"
    assert_contains "$section" "On a project that runs the loop, land work in its order: \`session\` first, then push your branch, \`preview\`, get a reading, append your ready line, and STOP before \`stage\`" "$id: the landing order"
    assert_contains "$section" "Never run \`release\`, \`gc --prune\` or \`gc --abandon\` on your own judgement: only on the captain's word, carried in this brief or given in the conversation you are in." "$id: the three commands"
    assert_contains "$section" "On a project without that loop, the Definition of done below is the whole landing." "$id: a project without the loop"
    assert_contains "$section" "Before you believe a clean result from a check you wrote, plant a fault and watch it go red." "$id: plant a fault before believing a clean result"
    [ "$(printf '%s\n' "$section" | grep -c -v '^#' | tr -d ' ')" -le 6 ] || fail "$id: the contract is one short paragraph, got:"$'\n'"$section"
  done
  pass "every ship mode and the scout scaffold carry the crewmate contract: report to your leader or First Mate never the captain, the landing order with STOP before stage, release and gc never on the session's own judgement, plant a fault before believing a clean result"
}

# --- 4. the crewmate knows its own id and brief; reads long files through a sub-agent ---
test_identity_line_and_reading_habit() {
  local home id brief
  make_home identity; home=$HOME_DIR
  for id_args in "i1:--mode no-mistakes" "i2:--scout"; do
    id=${id_args%%:*}
    # shellcheck disable=SC2086  # the args are a fixed word list
    scaffold "$home" "$id" proj ${id_args#*:}
    [ "$RC" -eq 0 ] || fail "$id: scaffold must exit 0:"$'\n'"$OUT"
    brief="$home/data/$id/brief.md"
    [ "$(head -1 "$brief")" = "You are crewmate \`$id\`: an autonomous worker agent managed by firstmate; this brief lives at \`$brief\`. Work on your own; do not wait for a human." ] \
      || fail "$id: the first line names the crewmate and its brief, got: $(head -1 "$brief")"
    assert_contains "$(doors_section "$brief")" "Read long files and long command output through a sub-agent that returns only what you asked, rather than reading them yourself." "$id: the sub-agent reading habit closes the doors section"
    [ "$(sed -n '/^# Your logbook$/,/^$/p' "$brief" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 4 ] || fail "$id: the logbook section stays four lines"
  done
  pass "ship and scout briefs open by naming the crewmate's id and the brief's own path, and ask for long reads through a sub-agent"
}

# --- 5. nothing about the machinery; a charter has none of this ----------------
test_no_machinery_words_and_the_charter_is_untouched() {
  local home id brief masked
  make_home words; home=$HOME_DIR
  fm_write_meta "$home/state/lead-a.meta" "window=firstmate:fm-lead-a" "kind=ship" "leads=1"
  for id_args in "w1:--mode no-mistakes" "w2:--mode direct-PR" "w3:--mode local-only" "w4:--scout" "w5:--mode no-mistakes --leader lead-a"; do
    id=${id_args%%:*}
    # shellcheck disable=SC2086  # the args are a fixed word list
    scaffold "$home" "$id" proj ${id_args#*:}
    [ "$RC" -eq 0 ] || fail "$id: scaffold must exit 0:"$'\n'"$OUT"
    brief="$home/data/$id/brief.md"
    masked=$(sed "s#$home#<home>#g" "$brief")
    printf '%s\n' "$masked" | grep -q -i -E "$MACHINERY_WORDS" \
      && fail "$id: the brief must not mention the machinery, got: $(printf '%s\n' "$masked" | grep -i -E "$MACHINERY_WORDS")"
  done
  FM_SECONDMATE_CHARTER='Supervise the proj domain.' scaffold "$home" sm2 --secondmate proj
  [ "$RC" -eq 0 ] || fail "a secondmate charter must still scaffold:"$'\n'"$OUT"
  brief="$home/data/sm2/brief.md"
  assert_not_contains "$(cat "$brief")" "two times you speak up" "a charter has no doors"
  assert_not_contains "$(cat "$brief")" "# Crewmate contract" "a charter has no crewmate contract"
  assert_not_contains "$(cat "$brief")" "key=story-size" "a charter has no story-size door"
  pass "no ship, scout or led brief says trim, compact, context window, token, budget, ledger or telemetry; a secondmate charter carries no doors and no contract"
}

test_ship_and_scout_briefs_carry_the_two_doors
test_leader_is_named_and_must_be_a_recorded_leader
test_crewmate_contract_paragraph
test_identity_line_and_reading_habit
test_no_machinery_words_and_the_charter_is_untouched

echo "# all fm-brief-doors tests passed"
