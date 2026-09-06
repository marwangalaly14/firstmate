#!/usr/bin/env bash
# tests/fm-send-led-channel.test.sh - while a leader exists, First Mate's
# channel to a working crewmate carries lifecycle and the captain's words only.
#
# bin/fm-send.sh refuses ordinary text, typed text and --resolve-key to a
# target whose record names a leader that holds a live agent, and prints the
# leader's steer command instead, unless the send carries one of three marks,
# each recorded in the inbox record's header: --from-leader <id> matching the
# recorded leader (bin/fm-lead.sh passes it), --captain <n|line> (whose
# delivered line fm-send reads from the brief's "## Captain's intent", the
# sender only pointing at it by number or by naming it exactly, so no work
# can ride along with a captain line and no fragment of one can be chosen),
# or --lifecycle
# <relaunch|teardown|handover|escalation> (whose delivered line fm-send
# composes from the action itself, with the sender's own words riding beside
# it, bounded and labelled, as --note, so no typed instruction can wear a
# lifecycle mark). --key stays open (Enter, Escape and C-c are lifecycle).
# A dead or missing leader reopens the channel; an unled
# crewmate is untouched. The contract lives in fm-send's header ("The led
# channel").
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SEND="$ROOT/bin/fm-send.sh"
LEAD="$ROOT/bin/fm-lead.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-led-channel)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

write_task() {  # <home> <id> [meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nBuild the smaller half first.\n\n## Firstmate spec\nNone.\n' > "$home/data/$id/brief.md"
}

# make_home <name>: HOME_DIR, FAKEBIN; lead-a leads c1 and c2, lead-b leads
# nobody, u1 is led by nobody.
make_home() {
  HOME_DIR="$TMP_ROOT/$1/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$1")
  make_fake_chain_tmux "$FAKEBIN"
  write_task "$HOME_DIR" lead-a "leads=1"
  write_task "$HOME_DIR" lead-b "leads=1"
  write_task "$HOME_DIR" c1 "leader=lead-a"
  write_task "$HOME_DIR" c2 "leader=lead-a"
  write_task "$HOME_DIR" u1
}

run_send() {  # <home> [ENV=val...] -- <fm-send args...>: sets RC, OUT, ERR
  local home=$1
  shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$home/send.log"
  OUT=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_LOG="$home/send.log" \
    FM_FAKE_STATE="$home/state" FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} "$SEND" "$@" 2>"$home/send.err")
  RC=$?
  ERR=$(cat "$home/send.err")
}

run_lead() {  # <home> -- <fm-lead args...>: sets RC, OUT, ERR
  local home=$1
  shift 2
  : > "$home/send.log"
  OUT=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_LOG="$home/send.log" \
    FM_FAKE_STATE="$home/state" FM_SEND_SETTLE=0 "$LEAD" "$@" 2>"$home/lead.err")
  RC=$?
  ERR=$(cat "$home/lead.err")
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

record_header() {  # <record>: the header lines before --
  sed '/^--$/,$d' "$1"
}

records() {  # <home> <id>: the count of inbox records (0 when no inbox)
  find "$1/state/$2.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

assert_refused_as_led() {  # <what> : RC/ERR from the last run_send
  [ "$RC" -ne 0 ] || fail "$1: must be refused (exit 0):"$'\n'"$OUT"
  assert_contains "$ERR" "c1 is led by lead-a" "$1: the refusal names the leader"
  assert_contains "$ERR" "lifecycle and the captain's words only" "$1: the refusal states the rule"
  assert_contains "$ERR" "bin/fm-lead.sh steer --leader lead-a c1" "$1: the refusal prints the leader's steer command"
  assert_contains "$ERR" "--lifecycle <relaunch|teardown|handover|escalation>" "$1: the refusal names the lifecycle mark"
  assert_contains "$ERR" "--captain" "$1: the refusal names the captain mark"
  assert_contains "$ERR" "nothing was sent" "$1: the refusal says nothing went out"
}

# --- 1. plain text, typed text and an answer to a led crewmate are refused ----
test_plain_typed_and_answers_to_a_led_crewmate_are_refused() {
  local home
  make_home refuse; home=$HOME_DIR
  run_send "$home" -- c1 "rebase onto main first"
  assert_refused_as_led "plain text"
  [ "$(records "$home" c1)" -eq 0 ] || fail "a refused send writes no record"
  [ ! -s "$home/send.log" ] || fail "a refused send rings no doorbell:"$'\n'"$(cat "$home/send.log")"
  run_send "$home" -- c1 "/compact the failing test"
  assert_refused_as_led "typed text"
  [ ! -s "$home/send.log" ] || fail "a refused typed send types nothing"
  printf 'blocked: [key=stuck] the suite loops on the same failure\n' > "$home/state/c1.status"
  run_send "$home" -- c1 --resolve-key stuck "drop the retry loop"
  assert_refused_as_led "an answer to the leader's door"
  [ "$(records "$home" c1)" -eq 0 ] || fail "a refused answer writes no record"
  ! grep -q 'resolved' "$home/state/c1.status" || fail "a refused answer closes nothing"
  pass "plain text, typed text and --resolve-key to a led crewmate are refused with the leader's steer command and the two marks named; nothing is written, rung or closed"
}

# --- 2. the leader's own mark ------------------------------------------------
test_the_leaders_mark_lands_and_the_wrong_leader_is_refused() {
  local home rec
  make_home leader; home=$HOME_DIR
  run_send "$home" -- c1 --from-leader lead-b "rebase onto main first"
  [ "$RC" -ne 0 ] || fail "--from-leader naming the wrong leader must be refused"
  assert_contains "$ERR" "c1 is led by lead-a, not lead-b" "the refusal names both"
  [ "$(records "$home" c1)" -eq 0 ] || fail "the wrong leader writes no record"
  run_send "$home" -- c1 --from-leader lead-a "rebase onto main first"
  [ "$RC" -eq 0 ] || fail "the recorded leader's mark must land: $ERR"
  rec="$home/state/c1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer is a durable record"
  assert_contains "$(record_header "$rec")" "mark=from-leader:lead-a" "the record's header carries the leader's mark"
  [ "$(inbox_body "$rec")" = "rebase onto main first" ] || fail "the body is the text verbatim"
  assert_contains "$(cat "$home/send.log")" "Firstmate instruction waiting" "the doorbell rings"
  run_send "$home" -- c1 --from-leader lead-a "/compact the failing test"
  [ "$RC" -eq 0 ] || fail "the leader's trim order rides the typed plane: $ERR"
  assert_contains "$(cat "$home/send.log")" "/compact the failing test" "the order is typed"
  run_send "$home" -- u1 --from-leader lead-a "rebase onto main first"
  [ "$RC" -ne 0 ] || fail "--from-leader to an unled crewmate must be refused"
  assert_contains "$ERR" "u1 has no leader" "the refusal says the target is unled"
  run_send "$home" -- c1 --from-leader "" "x"
  [ "$RC" -ne 0 ] || fail "--from-leader without an id must be refused"
  pass "--from-leader matching the record lands with mark=from-leader:<id> in the header, on the inbox and typed planes; the wrong leader, an unled target and a missing id are refused"
}

# --- 3. the captain's words are SELECTED from the brief, never typed --------
test_the_captains_words_are_selected_from_the_brief() {
  local home rec line
  make_home captain; home=$HOME_DIR
  line="Ship the smaller half first, the rest can wait."
  : > "$home/data/c1/brief.md"
  run_send "$home" -- c1 --captain 1
  [ "$RC" -ne 0 ] || fail "--captain must be refused while the brief carries no intent section"
  assert_contains "$ERR" "## Captain's intent" "the refusal names the brief's section"
  assert_contains "$ERR" "$home/data/c1/brief.md" "the refusal names the brief"
  assert_contains "$ERR" "verbatim" "the refusal says the words go in verbatim first"
  [ "$(records "$home" c1)" -eq 0 ] || fail "an unselectable send writes no record"
  # appended under Captain's intent, as the rule has First Mate do
  printf '# Task\n## Captain'"'"'s intent\nBuild the smaller half first.\n\n%s\n\nYes.\n\n## Firstmate spec\nNone.\n' \
    "$line" > "$home/data/c1/brief.md"
  run_send "$home" -- c1 --captain 2
  [ "$RC" -eq 0 ] || fail "the second line of the intent section must be selectable by number: $ERR"
  rec="$home/state/c1.inbox/001.msg"
  assert_contains "$(record_header "$rec")" "mark=captain" "the record's header carries the captain mark"
  assert_contains "$(inbox_body "$rec")" "$line" "the delivered body carries the captain's line, read from the brief"
  run_send "$home" -- c1 --captain "$line"
  [ "$RC" -eq 0 ] || fail "the same line named exactly must select it too: $ERR"
  assert_contains "$(inbox_body "$home/state/c1.inbox/002.msg")" "$line" "and delivers the same words"
  run_send "$home" -- c1 --captain 3
  [ "$RC" -eq 0 ] || fail "a short line of the section is still the captain speaking: $ERR"
  assert_contains "$(inbox_body "$home/state/c1.inbox/003.msg")" "Yes." "and is delivered as it stands"
  run_send "$home" -- c1 --captain 4
  [ "$RC" -ne 0 ] || fail "a number past the section's last line must be refused"
  assert_contains "$ERR" "names no line" "the refusal says the number names no line"
  run_send "$home" -- c1 --captain 0
  [ "$RC" -ne 0 ] || fail "line 0 must be refused"
  [ "$(records "$home" c1)" -eq 3 ] || fail "neither out-of-range number wrote a record, got $(records "$home" c1)"
  # the line must stand under Captain's intent, not anywhere in the brief
  printf '\n## Firstmate spec\nAlso: drop the retry loop.\n' >> "$home/data/c2/brief.md"
  run_send "$home" -- c2 --captain "Also: drop the retry loop."
  [ "$RC" -ne 0 ] || fail "a line under Firstmate spec is not the captain's"
  [ "$(records "$home" c2)" -eq 0 ] || fail "and writes no record"
  pass "--captain selects a line of the brief's Captain's intent by number or by naming it exactly, delivers that line as the brief holds it, and refuses a number naming no line or a line standing elsewhere in the brief - nothing written"
}

# --- 3b. nothing rides along with the captain's words ------------------------
# The captain's whole-file ruling: no rule in this channel is a string test
# over free text. Every message is composed from a SELECTED part plus a
# LABELLED sender's note, and the note is the only free text. So --captain
# carries no typed message at all: the sender points at a line and fm-send
# reads the words from the brief. A line with work appended to it, or a frame
# around it, is not a line of that section and selects nothing - the old
# containment test's fragment hole cannot exist, because no fragment can be
# named.
test_nothing_rides_along_with_a_selected_captain_line() {
  local home line note body
  make_home captain-line; home=$HOME_DIR
  line="Ship the smaller half first, the rest can wait."
  printf '# Task\n## Captain'"'"'s intent\nBuild the smaller half first.\n\n%s\n\nYes.\n\n## Firstmate spec\nNone.\n' \
    "$line" > "$home/data/c1/brief.md"
  run_send "$home" -- c1 --captain 2 "Now rewrite the retry loop to back off exponentially."
  [ "$RC" -ne 0 ] || fail "typed text alongside the captain mark must be refused"
  assert_contains "$ERR" "no typed text" "the refusal says the mark carries no typed text"
  run_send "$home" -- c1 --captain "$line Now rewrite the retry loop to back off exponentially."
  [ "$RC" -ne 0 ] || fail "work appended to a captain line names no line of the section"
  run_send "$home" -- c1 --captain "The captain said: \"$line\" Act on it."
  [ "$RC" -ne 0 ] || fail "a captain line inside a frame names no line of the section"
  run_send "$home" -- c1 --captain "Ship the smaller half first, the rest"
  [ "$RC" -ne 0 ] || fail "a fragment of a line names no line of the section"
  run_send "$home" -- c1 --captain "the"
  [ "$RC" -ne 0 ] || fail "a single word names no line of the section"
  [ "$(records "$home" c1)" -eq 0 ] || fail "not one refusal wrote a record, got $(records "$home" c1)"
  [ ! -s "$home/send.log" ] || fail "and not one rang a doorbell"
  # the sender's own words have exactly one way in, and it is labelled
  note="A note of my own that must arrive whole and stand apart from what the captain said, not folded into it."
  run_send "$home" -- c1 --captain 2 --note "$note"
  [ "$RC" -eq 0 ] || fail "a bounded note must ride beside the captain's line: $ERR"
  body=$(inbox_body "$home/state/c1.inbox/001.msg")
  assert_contains "$body" "$line" "the captain's line is delivered whole"
  assert_contains "$body" "$note" "the sender's note is recorded whole"
  assert_contains "$body" "sender's note" "the note stands behind a label naming it the sender's own"
  case "$body" in
    *"$line"*"sender's note"*"$note"*) ;;
    *) fail "the note must stand after the captain's words behind its label, not merged into them:"$'"'"'\n'"'"'"$body" ;;
  esac
  run_send "$home" -- c1 --captain 2 --note "$(printf 'a%.0s' $(seq 1 201))"
  [ "$RC" -ne 0 ] || fail "a note past the bound must be refused"
  run_send "$home" -- c1 --captain 2 --note "$(printf 'one line\nand another')"
  [ "$RC" -ne 0 ] || fail "a note of more than one line must be refused"
  [ "$(records "$home" c1)" -eq 1 ] || fail "neither refused note wrote a record, got $(records "$home" c1)"
  pass "the captain mark carries no typed text at all: a line with work appended, a frame around one, a fragment and a single word each select nothing and write nothing, while the sender's own words ride only as a bounded one-line note, recorded whole and standing after a label naming them the sender's, never merged into the captain's"
}

# --- 4. lifecycle marks, --key, and one mark at a time ------------------------
test_lifecycle_marks_land_and_are_recorded() {
  local home
  make_home lifecycle; home=$HOME_DIR
  run_send "$home" -- c1 --lifecycle relaunch
  [ "$RC" -eq 0 ] || fail "--lifecycle relaunch must land: $ERR"
  assert_contains "$(record_header "$home/state/c1.inbox/001.msg")" "mark=lifecycle:relaunch" "the record's header carries the lifecycle mark and its action"
  run_send "$home" -- c1 --lifecycle reboot "x"
  [ "$RC" -ne 0 ] || fail "--lifecycle outside the allowlist must be refused"
  assert_contains "$ERR" "relaunch, teardown, handover, escalation" "the refusal names the allowlist"
  printf 'blocked: [key=stuck] the suite loops on the same failure\n' > "$home/state/c1.status"
  run_send "$home" -- c1 --resolve-key stuck --lifecycle escalation --note "the leader has been silent 40 minutes"
  [ "$RC" -eq 0 ] || fail "an escalated door is First Mate's to answer with --lifecycle escalation: $ERR"
  assert_contains "$(cat "$home/state/c1.status")" 'resolved [key=stuck]: answered:' "the door closes"
  assert_contains "$(record_header "$home/state/c1.inbox/002.msg")" "mark=lifecycle:escalation" "the answer's record carries the mark"
  run_send "$home" -- c1 --key Enter
  [ "$RC" -eq 0 ] || fail "--key stays open to a led crewmate (Enter is lifecycle): $ERR"
  run_send "$home" -- c1 --lifecycle relaunch --from-leader lead-a "x"
  [ "$RC" -ne 0 ] || fail "two marks on one send must be refused"
  assert_contains "$ERR" "one mark" "the refusal says one mark at a time"
  run_send "$home" -- c1 --lifecycle relaunch --key Enter
  [ "$RC" -ne 0 ] || fail "a mark with --key must be refused (a key is lifecycle already)"
  pass "--lifecycle <action> lands with mark=lifecycle:<action>, answers an escalated door, refuses actions outside the allowlist; --key stays open; one mark per send and none with --key"
}

# --- 4b. the lifecycle body is generated, the note rides beside it labelled ----
# The captain's ruling: no typed instruction can wear a lifecycle mark, so the
# delivered line is composed from the ACTION and a sender's note is bounded,
# labelled and never merged into it. Proved both directions - a work
# instruction under a lifecycle mark is refused before anything is written or
# rung, and a generated line with a note lands with the note behind its label.
test_the_lifecycle_body_is_generated_and_a_note_rides_beside_it() {
  local home note plain withnote teardown_body tail
  make_home lifecyclebody; home=$HOME_DIR
  run_send "$home" -- c1 --lifecycle relaunch "rebase onto main and re-run the failing test before you do anything else"
  [ "$RC" -ne 0 ] || fail "a typed work instruction under a lifecycle mark must be refused, got:"$'\n'"$OUT"
  assert_contains "$ERR" "composes its own line from the action" "the refusal says the body is generated"
  assert_contains "$ERR" "--note" "the refusal points at the note"
  assert_contains "$ERR" "Nothing was sent" "the refusal says nothing went out"
  [ "$(records "$home" c1)" -eq 0 ] || fail "a refused lifecycle send writes no record"
  [ ! -s "$home/send.log" ] || fail "a refused lifecycle send rings no doorbell:"$'\n'"$(cat "$home/send.log")"

  run_send "$home" -- c1 --lifecycle relaunch
  [ "$RC" -eq 0 ] || fail "a lifecycle send with no text lands on its generated line: $ERR"
  plain=$(inbox_body "$home/state/c1.inbox/001.msg")
  [ -n "$plain" ] || fail "the generated lifecycle line is not empty"
  run_send "$home" -- c1 --lifecycle teardown
  [ "$RC" -eq 0 ] || fail "teardown lands: $ERR"
  teardown_body=$(inbox_body "$home/state/c1.inbox/002.msg")
  [ "$teardown_body" != "$plain" ] || fail "the line is composed FROM the action: relaunch and teardown must not read alike"

  note="lead-b picks this up at 14:00"
  run_send "$home" -- c1 --lifecycle relaunch --note "$note"
  [ "$RC" -eq 0 ] || fail "a generated lifecycle line with a note lands: $ERR"
  withnote=$(inbox_body "$home/state/c1.inbox/003.msg")
  [ "${withnote#"$plain"}" != "$withnote" ] \
    || fail "the generated line is unchanged by the note and stands first, got:"$'\n'"$withnote"
  tail=${withnote#"$plain"}
  assert_contains "$tail" "sender's note" "the note rides under a label naming it the sender's own words"
  [ "${tail%"$note"}" != "$tail" ] \
    || fail "the note stands last, behind its label, never merged into the generated line: $tail"
  case "$plain" in *"$note"*) fail "the note is never merged into the generated line" ;; esac

  run_send "$home" -- c1 --lifecycle relaunch --note "$(printf 'x%.0s' $(seq 1 201))"
  [ "$RC" -ne 0 ] || fail "a note past the bound must be refused"
  assert_contains "$ERR" "the bound is 200" "the refusal names the bound"
  run_send "$home" -- c1 --lifecycle relaunch --note "first line
second line"
  [ "$RC" -ne 0 ] || fail "a multi-line note must be refused"
  run_send "$home" -- c1 --note "$note"
  [ "$RC" -ne 0 ] || fail "--note without a lifecycle mark must be refused"
  assert_contains "$ERR" "needs --lifecycle" "the refusal says the note needs its action"
  [ "$(records "$home" c1)" -eq 3 ] || fail "no refusal after the three landed sends wrote a record"
  pass "a typed work instruction under a lifecycle mark is refused before anything is written or rung; the delivered line is composed from the action itself, and a sender's note is bounded to one line of 200 characters, delivered behind a label naming it the sender's own words and never merged into the generated line"
}

# --- 5. a dead or missing leader reopens the channel; the unled are untouched --
test_a_dead_or_missing_leader_reopens_the_channel() {
  local home rec
  make_home reopen; home=$HOME_DIR
  run_send "$home" FM_FAKE_GONE_WINDOWS=fm-lead-a -- c1 "rebase onto main first"
  [ "$RC" -eq 0 ] || fail "with the leader dead, plain text lands as today: $ERR"
  rec="$home/state/c1.inbox/001.msg"
  ! grep -q '^mark=' "$rec" || fail "an unmarked send records no mark line:"$'\n'"$(record_header "$rec")"
  rm "$home/state/lead-a.meta"
  run_send "$home" -- c2 "rebase onto main first"
  [ "$RC" -eq 0 ] || fail "with the leader's record gone, plain text lands: $ERR"
  run_send "$home" -- u1 "rebase onto main first"
  [ "$RC" -eq 0 ] || fail "an unled crewmate is untouched: $ERR"
  ! grep -q '^mark=' "$home/state/u1.inbox/001.msg" || fail "no mark on an unled crewmate's record"
  run_send "$home" -- u1 --lifecycle teardown --note "landing is confirmed; cleanup follows"
  [ "$RC" -eq 0 ] || fail "a lifecycle mark to an unled crewmate is accepted and recorded: $ERR"
  assert_contains "$(record_header "$home/state/u1.inbox/002.msg")" "mark=lifecycle:teardown" "the mark is recorded even where nothing required it"
  pass "a dead leader or a missing leader record reopens the channel with no mark line; an unled crewmate is untouched and still records a mark it was given"
}

# --- 6. fm-lead passes the leader's mark ------------------------------------
test_fm_lead_steer_and_trim_carry_the_mark() {
  local home
  make_home lead; home=$HOME_DIR
  run_lead "$home" -- steer --leader lead-a c1 "rebase onto main first"
  [ "$RC" -eq 0 ] || fail "fm-lead steer to an own live crewmate lands: $ERR"
  assert_contains "$(record_header "$home/state/c1.inbox/001.msg")" "mark=from-leader:lead-a" "the steer's record carries the leader's mark"
  run_lead "$home" -- trim --leader lead-a c1 the failing test
  [ "$RC" -eq 0 ] || fail "fm-lead trim types its order and returns without waiting: $RC $ERR"
  assert_contains "$(cat "$home/send.log")" "/compact the failing test" "the trim order is typed"
  pass "fm-lead steer records mark=from-leader:<leader>; fm-lead trim types its order through the same mark"
}

test_plain_typed_and_answers_to_a_led_crewmate_are_refused
test_the_leaders_mark_lands_and_the_wrong_leader_is_refused
test_the_captains_words_are_selected_from_the_brief
test_nothing_rides_along_with_a_selected_captain_line
test_lifecycle_marks_land_and_are_recorded
test_the_lifecycle_body_is_generated_and_a_note_rides_beside_it
test_a_dead_or_missing_leader_reopens_the_channel
test_fm_lead_steer_and_trim_carry_the_mark

echo "# all fm-send-led-channel tests passed"
