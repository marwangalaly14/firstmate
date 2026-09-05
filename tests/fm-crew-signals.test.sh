#!/usr/bin/env bash
# tests/fm-crew-signals.test.sh - the chain's transcript signals: a led
# crewmate's stall, loop or drift candidate rings its leader once per episode.
#
# bin/fm-crew-signals.sh reads the crewmate's card (bin/fm-crew-vitals.sh
# --json over a synthetic transcript, a worktree and a logbook) and rings the
# leader named by the crewmate's meta through bin/fm-send.sh: a loop (the same
# command three times in the last 30 calls, or an A-B-A-B bounce), a stall (busy
# with nothing new for FM_STUCK_CALL_SECS), a drift candidate
# (FM_DRIFT_TOKENS spent since the last commit with no logbook change over that
# spend) and a trim the leader ordered that nothing answered inside
# FM_LEAD_ORDER_STALE_SECS. The ledger data/<id>/signals/index keeps one row per signal and
# signature, so the same episode is silent and a new signature rings again; an
# unled crewmate never rings; a logbook that claims progress does not quiet a
# loop the transcript shows; a dead leader gets one failed row and no send.
# bin/fm-watch.sh runs the check once per FM_SIGNAL_CHECK_SECS per led crewmate
# from its poll and never wakes First Mate for it. The detector is driven
# directly; the watcher runs as a real subprocess over the chain's fake tmux.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/transcript-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/transcript-helpers.sh"
# shellcheck source=bin/fm-logbook-lib.sh
. "$ROOT/bin/fm-logbook-lib.sh"

SIGNALS="$ROOT/bin/fm-crew-signals.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-signals)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
NOW=$(date +%s)   # the real clock: the ledger, the watcher and the card all read it

write_task() {  # <home> <id> [meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
}

# make_home <name>: HOME_DIR, STATE, DATA, FAKEBIN, CASE_ENV; lead-a leads c1
# and c2, u1 is led by nobody. Every crewmate gets a worktree whose one commit
# is 3,000 s old and a transcript that starts empty.
make_home() {
  HOME_DIR="$TMP_ROOT/$1/home"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  mkdir -p "$STATE" "$DATA"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$1")
  make_fake_chain_tmux "$FAKEBIN"
  make_fake_crew_state "$FAKEBIN" >/dev/null
  write_task "$HOME_DIR" lead-a "leads=1"
  write_task "$HOME_DIR" c1 "leader=lead-a"
  write_task "$HOME_DIR" c2 "leader=lead-a"
  write_task "$HOME_DIR" u1
  local id
  for id in c1 c2 u1; do
    make_worktree "$TMP_ROOT/$1/wt-$id" $((NOW - 3000))
    printf 'worktree=%s\n' "$TMP_ROOT/$1/wt-$id" >> "$STATE/$id.meta"
    : > "$HOME_DIR/$id.jsonl"
    printf '%s\tstartup\ts-%s\t%s\t?\t?\n' "$((NOW - 3600))" "$id" "$HOME_DIR/$id.jsonl" >> "$DATA/$id/sessions.log"
  done
  CASE_ENV=(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
    FM_FAKE_STATE="$STATE" FM_SEND_LOG="$HOME_DIR/send.log" FM_SEND_SETTLE=0
    FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
    FM_FAKE_CAPTURE_COUNT="$HOME_DIR/capture.count")
}

transcript() { printf '%s/%s.jsonl' "$HOME_DIR" "$1"; }  # <id>

# A loop: the same command three times, the last one seconds ago.
plant_loop() {  # <id> [command]
  local cmd=${2:-bash tests/x.test.sh} t
  t=$(transcript "$1")
  {
    row_assistant $((NOW - 90)) m1 100 0 0 10 "$(tool_bash "$cmd")"
    row_assistant $((NOW - 60)) m2 100 0 0 10 "$(tool_bash "$cmd")"
    row_assistant $((NOW - 30)) m3 100 0 0 10 "$(tool_bash "$cmd")"
  } >> "$t"
}

run_signals() {  # [ENV=val...] -- <task-id>: sets RC, OUT, ERR
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env "${CASE_ENV[@]}" ${envs[@]+"${envs[@]}"} "$SIGNALS" "$HOME_DIR" "$1" 2> "$HOME_DIR/signals.err")
  RC=$?
  ERR=$(cat "$HOME_DIR/signals.err")
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

inbox_count() {  # <id>
  local n=0 f
  for f in "$STATE/$1.inbox"/*.msg; do [ -f "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

newest_inbox_body() {  # <id>
  local f last=
  for f in "$STATE/$1.inbox"/*.msg; do [ -f "$f" ] && last=$f; done
  [ -n "$last" ] || return 1
  inbox_body "$last"
}

# The ledger's rows as "<signal> <result>" words, one per line.
ledger_rows() {  # <id>
  [ -f "$DATA/$1/signals/index" ] || return 0
  cut -f2,4 "$DATA/$1/signals/index" | tr '\t' ' '
}

ledger_count() {  # <id>
  [ -f "$DATA/$1/signals/index" ] || { printf 0; return 0; }
  grep -c . "$DATA/$1/signals/index" || true
}

queue_records() {
  [ -f "$STATE/.wake-queue" ] || { printf 0; return 0; }
  grep -c . "$STATE/.wake-queue" || true
}

# --- 1-3. a loop rings once; the episode is silent; a new signature rings ----
test_loop_rings_once_per_episode() {
  local body t
  make_home loop
  plant_loop c1
  run_signals -- c1
  [ "$RC" -eq 0 ] || fail "the detector exits 0, got $RC: $ERR"
  [ "$OUT" = "loop	rung	loop 3x Bash bash tests/x.test.sh in the last 30 calls" ] \
    || fail "a planted loop is reported as rung, got: '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the loop rings the leader once, inbox has $(inbox_count lead-a) records"
  body=$(newest_inbox_body lead-a)
  assert_contains "$body" "signal: c1 loop: loop 3x Bash bash tests/x.test.sh in the last 30 calls" "the ring opens with the signal line"
  assert_contains "$body" "  last call  Bash \`bash tests/x.test.sh\`" "the ring carries the crewmate's card"
  assert_contains "$body" "FM_HOME=$HOME_DIR bin/fm-lead.sh steer --leader lead-a c1 \"<one line>\"" "the ring says how to steer"
  assert_contains "$body" "never from the crewmate's report; the judgment is yours" "the ring says what it is"
  [ "$(ledger_rows c1)" = "loop rung" ] || fail "the ledger records the ring, got: $(ledger_rows c1)"
  [ "$(awk -F '\t' 'NF != 6 { bad = 1 } END { exit bad }' "$DATA/c1/signals/index"; echo $?)" = 0 ] \
    || fail "a ledger row has six tab-separated fields, got: $(cat "$DATA/c1/signals/index")"
  [ "$(inbox_count u1)" -eq 0 ] && [ ! -e "$STATE/c1.inbox" ] || fail "nothing reaches the crewmate or anyone else"

  # The same episode, checked again: silent, no second record, no second row.
  run_signals -- c1
  [ "$OUT" = "loop	silent	loop 3x Bash bash tests/x.test.sh in the last 30 calls" ] \
    || fail "the same episode is silent on the next check, got: '$OUT'"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the same episode does not ring twice, inbox has $(inbox_count lead-a)"
  [ "$(ledger_count c1)" -eq 1 ] || fail "the same episode adds no row, ledger has $(ledger_count c1)"

  # The loop keeps going (a fourth run of the same command): still the same episode.
  t=$(transcript c1)
  row_assistant $((NOW - 20)) m4 100 0 0 10 "$(tool_bash 'bash tests/x.test.sh')" >> "$t"
  run_signals -- c1
  assert_contains "$OUT" "loop	silent	loop 4x" "a growing count is the same episode"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "a growing count does not ring again"

  # A new shape, an A-B-A-B bounce, is a new signature and rings again.
  {
    row_assistant $((NOW - 16)) m5 100 0 0 10 "$(tool_bash 'ls')"
    row_assistant $((NOW - 15)) m6 100 0 0 10 "$(tool_bash 'pwd')"
    row_assistant $((NOW - 14)) m7 100 0 0 10 "$(tool_bash 'ls')"
    row_assistant $((NOW - 13)) m8 100 0 0 10 "$(tool_bash 'pwd')"
    row_assistant $((NOW - 12)) m9 100 0 0 10 "$(tool_bash 'ls')"
    row_assistant $((NOW - 11)) m10 100 0 0 10 "$(tool_bash 'pwd')"
    row_assistant $((NOW - 10)) m11 100 0 0 10 "$(tool_bash 'ls')"
    row_assistant $((NOW - 9)) m12 100 0 0 10 "$(tool_bash 'pwd')"
  } >> "$t"
  run_signals -- c1
  [ "$OUT" = "loop	rung	alternates 4x Bash ls / Bash pwd in the last 30 calls" ] \
    || fail "a new signature rings again, got: '$OUT'"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "the new episode rings the leader, inbox has $(inbox_count lead-a)"
  [ "$(ledger_rows c1)" = "loop rung
loop rung" ] || fail "the ledger has one row per episode, got: $(ledger_rows c1)"
  pass "a planted loop rings the leader once with the card and how to steer; the same episode is silent while it grows; a new signature rings again"
}

# --- 4. a stall rings while busy; an idle crewmate of the same age does not --
test_stall_rings_only_while_busy() {
  local t
  make_home stall
  # c1: a tool call in flight for 1,000 s.
  t=$(transcript c1)
  row_assistant $((NOW - 1000)) m1 100 0 0 10 "$(tool_bash 'bash tests/slow.test.sh')" >> "$t"
  # c2: a finished turn 1,000 s ago, waiting for input.
  t=$(transcript c2)
  { row_assistant $((NOW - 1100)) m1 100 0 0 10 "$(tool_bash 'ls')"; row_assistant $((NOW - 1000)) m2 100 0 0 10; } >> "$t"

  run_signals FM_STUCK_CALL_SECS=900 -- c1
  case "$OUT" in
    "stall	rung	busy with nothing new for 17m (bound 15m); last call Bash \`bash tests/slow.test.sh\`") ;;
    *) fail "a call in flight past the bound rings a stall, got: '$OUT' ($ERR)" ;;
  esac
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the stall rings the leader"
  assert_contains "$(newest_inbox_body lead-a)" "signal: c1 stall: busy with nothing new for 17m" "the ring names the stall"
  [ "$(cut -f3 "$DATA/c1/signals/index")" = "$((NOW - 1000))" ] \
    || fail "the stall's signature is when the quiet began, got: $(cut -f3 "$DATA/c1/signals/index")"

  run_signals FM_STUCK_CALL_SECS=900 -- c2
  [ -z "$OUT" ] || fail "a finished turn is not a stall however old, got: '$OUT'"
  [ ! -e "$DATA/c2/signals" ] || fail "an idle crewmate gets no ledger"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "an idle crewmate does not ring"

  # Below the bound the same call in flight is not a stall.
  run_signals FM_STUCK_CALL_SECS=2000 -- c1
  [ -z "$OUT" ] || fail "a call in flight under the bound is not a stall, got: '$OUT'"

  # A prompt the model has not answered is busy too.
  t=$(transcript c2)
  row_user $((NOW - 950)) >> "$t"
  run_signals FM_STUCK_CALL_SECS=900 -- c2
  assert_contains "$OUT" "stall	rung	busy with nothing new for 16m" "a prompt the model has not answered past the bound is a stall"
  pass "a call in flight past the bound rings a stall with when the quiet began as its signature; a finished turn of the same age never does; under the bound nothing rings"
}

# --- 5. a drift candidate rings; a logbook change over the spend quiets it ---
test_drift_candidate_rings_without_a_logbook_change() {
  local t logbook
  make_home drift
  # 6,000 fresh tokens since the 3,000 s old commit; the logbook is the template.
  t=$(transcript c1)
  {
    row_assistant $((NOW - 2000)) m1 1000 1000 0 100 "$(tool_bash 'ls')"
    row_assistant $((NOW - 1500)) m2 1000 1000 0 100 "$(tool_bash 'pwd')"
    row_assistant $((NOW - 1000)) m3 1000 500 0 100 "$(tool_bash 'ls -a')"
    row_assistant $((NOW - 10)) m4 100 0 0 100
  } >> "$t"
  logbook=$(fm_logbook_path "$DATA" c1)
  fm_logbook_template c1 > "$logbook"

  run_signals FM_DRIFT_TOKENS=5000 -- c1
  case "$OUT" in
    "drift?	rung	6.0K tokens since the last commit (50m) with no logbook change over that spend (bound 5.0K; logbook untouched)") ;;
    *) fail "spend past the bound with an untouched logbook rings drift?, got: '$OUT' ($ERR)" ;;
  esac
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "drift? rings the leader"
  assert_contains "$(newest_inbox_body lead-a)" "signal: c1 drift?: 6.0K tokens since the last commit" "the ring names the candidate"
  [ "$(ledger_rows c1)" = "drift? rung" ] || fail "the ledger records the candidate, got: $(ledger_rows c1)"

  # The crewmate writes its logbook now: the spend since that change is nil,
  # so there is no candidate at all.
  printf '## Done\n- the tests pass\n## Next\n- the docs\n' > "$logbook"
  run_signals FM_DRIFT_TOKENS=5000 -- c1
  [ -z "$OUT" ] || fail "a logbook change over the spend quiets the candidate, got: '$OUT'"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "no ring after the logbook change"

  # A logbook last changed before the spend: the candidate is back, as a new
  # episode (the change it measures from moved).
  set_mtime "$logbook" $((NOW - 2500))
  run_signals FM_DRIFT_TOKENS=5000 -- c1
  case "$OUT" in
    "drift?	rung	6.0K tokens since the last commit (50m) with no logbook change over that spend (bound 5.0K; logbook 42m old)") ;;
    *) fail "spend past the bound since the logbook's last change rings drift? again, got: '$OUT'" ;;
  esac
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "the new episode rings"
  [ "$(ledger_count c1)" -eq 2 ] || fail "two episodes, two rows, got $(ledger_count c1)"

  # A commit lands: the spend since it is nil; silent.
  GIT_COMMITTER_DATE="@$NOW" git -C "$TMP_ROOT/drift/wt-c1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m landed --date="@$NOW"
  run_signals FM_DRIFT_TOKENS=5000 -- c1
  [ -z "$OUT" ] || fail "a fresh commit quiets the candidate, got: '$OUT'"
  pass "spend past the bound since the last commit with no logbook change rings drift? once per episode; a logbook change over the spend, or a commit, quiets it"
}

# --- 6. an unled crewmate never rings ----------------------------------------
test_unled_crewmate_never_rings() {
  make_home unled
  plant_loop u1
  run_signals FM_STUCK_CALL_SECS=1 FM_DRIFT_TOKENS=1 -- u1
  [ "$RC" -eq 0 ] || fail "an unled crewmate exits 0, got $RC: $ERR"
  [ -z "$OUT" ] || fail "an unled crewmate prints nothing, got: '$OUT'"
  [ ! -e "$DATA/u1/signals" ] || fail "an unled crewmate gets no ledger"
  [ ! -s "$HOME_DIR/send.log" ] || fail "nothing was sent anywhere: $(cat "$HOME_DIR/send.log")"
  [ "$(inbox_count lead-a)" -eq 0 ] || fail "no leader was rung"
  # And a crewmate whose transcript has not begun yields nothing either.
  rm -f "$DATA/c1/sessions.log"
  run_signals FM_STUCK_CALL_SECS=1 -- c1
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "no transcript, no signal, got rc=$RC '$OUT'"
  # Usage is the one non-zero exit.
  env "${CASE_ENV[@]}" "$SIGNALS" "$HOME_DIR" >/dev/null 2>&1; [ $? -eq 2 ] || fail "a missing task id exits 2"
  pass "an unled crewmate never rings and gets no ledger; a transcript that has not begun yields nothing; only usage exits non-zero"
}

# --- 7. the logbook's claim does not quiet the transcript's loop -------------
test_transcript_beats_the_report() {
  local logbook
  make_home report
  plant_loop c1
  logbook=$(fm_logbook_path "$DATA" c1)
  printf '## Done\n- all tests green, the story is finished\n## Next\n- open the PR\n' > "$logbook"
  run_signals -- c1
  assert_contains "$OUT" "loop	rung	loop 3x Bash bash tests/x.test.sh" "the loop rings although the logbook claims the work is done"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the leader is rung"
  assert_not_contains "$(newest_inbox_body lead-a)" "all tests green" "nothing the crewmate wrote enters the ring"
  pass "a logbook that claims progress does not quiet the loop the transcript shows: the detector reads the transcript, not the report"
}

# --- 7b. an ordered trim's summary row is not a stall ------------------------
test_a_trim_summary_is_not_a_stall() {
  local t
  make_home trimmed
  # The leader ordered a trim: the call, the boundary, then the harness's own
  # summary row, older than the bound. The crewmate idles at its prompt.
  t=$(transcript c1)
  {
    row_assistant $((NOW - 2000)) m1 100 0 0 10 "$(tool_bash 'ls')"
    row_boundary $((NOW - 1100)) manual 150000 20000
    row_summary $((NOW - 1000))
  } >> "$t"
  run_signals FM_STUCK_CALL_SECS=900 -- c1
  [ "$RC" -eq 0 ] || fail "the detector exits 0, got $RC: $ERR"
  [ -z "$OUT" ] || fail "a crewmate idle at its prompt after an ordered trim rings no stall, got: '$OUT'"
  [ ! -e "$DATA/c1/signals" ] || fail "and gets no ledger"
  [ "$(inbox_count lead-a)" -eq 0 ] || fail "the leader is not rung for a trimmed, idle crewmate"
  pass "a transcript ending in the harness's own trim summary rings no stall once FM_STUCK_CALL_SECS has passed: the crewmate is idle at its prompt, not wedged"
}

# --- 6b. a crewmate waiting on a live helper is not stalled ------------------
test_a_live_helper_holds_the_stall_but_never_disables_it() {
  local t
  make_home helper
  # c1 dispatched a Task 1,000 s ago - past the bound - and its helper is
  # still writing, the newest row 100 s old.
  t=$(transcript c1)
  {
    row_assistant $((NOW - 1000)) m1 150 0 120000 0 "$(tool_task 'read the spec')"
    row_sidechain $((NOW - 300)) s1 1000 0 2500 15 "$(tool_read /w/spec.md)"
    row_sidechain $((NOW - 100)) s2 1000 0 2500 15 "$(tool_read /w/spec.md)"
  } >> "$t"
  run_signals FM_STUCK_CALL_SECS=900 -- c1
  [ "$RC" -eq 0 ] || fail "the detector exits 0, got $RC: $ERR"
  [ -z "$OUT" ] || fail "a crewmate whose helper is still writing is not stalled, got: '$OUT'"
  [ "$(inbox_count lead-a)" -eq 0 ] || fail "and the leader is not rung"
  # c2 dispatched the same call and nothing has been written since: the alarm
  # must still ring, or the fix would have silenced it rather than made it true.
  t=$(transcript c2)
  row_assistant $((NOW - 1000)) m1 150 0 120000 0 "$(tool_task 'read the spec')" >> "$t"
  run_signals FM_STUCK_CALL_SECS=900 -- c2
  assert_contains "$OUT" "stall	rung	busy with nothing new for 17m" "with no helper row since the dispatch the stall still rings"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the stall rings the leader once"
  pass "a crewmate waiting on a helper that is still writing rings no stall past the bound; with nothing written since its own dispatch the stall rings exactly as before - the alarm is made true, never disabled"
}

# --- 7c. the ring carries no word the crewmate wrote -------------------------
test_the_ring_carries_no_logbook_words() {
  local logbook body card
  make_home ring-words
  plant_loop c1
  logbook=$(fm_logbook_path "$DATA" c1)
  printf '## Done\n- all tests green, the story is finished\n## Next\n- MARKER-THE-CREWMATE-WROTE-THIS\n' > "$logbook"
  # The leader's own card shows the line; the ring must not carry it.
  card=$(env "${CASE_ENV[@]}" "$ROOT/bin/fm-crew-vitals.sh" c1) || fail "the card must be readable"
  assert_contains "$card" "MARKER-THE-CREWMATE-WROTE-THIS" "the card the leader reads by hand keeps the logbook's next line"
  run_signals -- c1
  assert_contains "$OUT" "loop	rung" "the loop rings"
  body=$(newest_inbox_body lead-a)
  assert_contains "$body" "last call  Bash" "the ring still carries the card read from the outside"
  assert_not_contains "$body" "MARKER-THE-CREWMATE-WROTE-THIS" "the crewmate's own logbook words never enter the ring"
  assert_not_contains "$body" "all tests green" "nor anything else it wrote"
  pass "the ring carries the card read from the outside and none of the crewmate's own logbook words; the full card keeps them for the leader to read by hand"
}

# --- 8. the watcher runs the check on its cadence and never wakes First Mate --
test_watcher_rings_from_its_poll_and_stays_quiet() {
  local WOUT WPID i
  make_home watcher
  plant_loop c1
  WOUT="$HOME_DIR/watch.out"
  : > "$WOUT"
  # A cadence longer than the case: the first poll checks, no later poll may.
  env "${CASE_ENV[@]}" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=999 FM_SIGNAL_CHECK_SECS=999999 "$WATCH" > "$WOUT" 2> "$HOME_DIR/watch.err" &
  WPID=$!
  i=0
  until [ "$(ledger_count c1)" -ge 1 ] || [ "$i" -ge 40 ]; do sleep 0.25; i=$((i + 1)); done
  [ "$(ledger_rows c1)" = "loop rung" ] || { kill "$WPID" 2>/dev/null; fail "the watcher's poll rings a led crewmate's loop, ledger: $(ledger_rows c1); err: $(tail -5 "$HOME_DIR/watch.err")"; }
  [ "$(inbox_count lead-a)" -eq 1 ] || { kill "$WPID" 2>/dev/null; fail "the leader was rung once from the poll"; }
  assert_grep "signal check c1: loop	rung	loop 3x Bash bash tests/x.test.sh" "$STATE/.watch-triage.log" "the triage log carries the verdict"
  # Five polls later: no wake, no second ring, and no second check either
  # (the cadence, not the poll, decides when the transcript is read again).
  sleep 5
  kill -0 "$WPID" 2>/dev/null || fail "the watcher is still running (no wake for a signal), out: $(cat "$WOUT")"
  [ "$(ledger_count c1)" -eq 1 ] || { kill "$WPID" 2>/dev/null; fail "no second ring, ledger: $(ledger_rows c1)"; }
  [ "$(inbox_count lead-a)" -eq 1 ] || { kill "$WPID" 2>/dev/null; fail "still one record"; }
  [ "$(queue_records)" -eq 0 ] || { kill "$WPID" 2>/dev/null; fail "First Mate is not woken for a signal, queue: $(cat "$STATE/.wake-queue")"; }
  [ ! -e "$DATA/u1/signals" ] || { kill "$WPID" 2>/dev/null; fail "the poll checks led crewmates only"; }
  [ "$(grep -c 'signal check c1:' "$STATE/.watch-triage.log")" -eq 1 ] || { kill "$WPID" 2>/dev/null; fail "the check runs once per cadence, not once per poll: $(grep -c 'signal check c1:' "$STATE/.watch-triage.log") checks in the log"; }
  kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
  pass "the watcher's poll runs the check for led crewmates only, once per cadence, rings the loop once, logs the verdict, and never wakes First Mate"
}

# --- 9. a dead leader gets one failed row and no send -----------------------
# --- 11. an ordered trim that never happened rings its leader, once ---------
# The other half of the trim loop: the crewmate's own hook carries it on when
# the trim happens, and when no trim ever happens the order stands unanswered
# in the ledger and this check tells the leader.
test_a_trim_order_that_was_never_answered_rings_the_leader() {
  local body
  make_home stale-order
  mkdir -p "$DATA/c1/trims" "$DATA/c2/trims"
  # An order given 500 s ago that nothing has answered: past the 430 s bound.
  printf 'ordered\t%s\tlead-a\tkeep the spec\n' "$((NOW - 500))" > "$DATA/c1/trims/index"
  run_signals FM_VITALS_NOW="$NOW" -- c1
  [ "$RC" -eq 0 ] || fail "the detector exits 0, got $RC: $ERR"
  [ "$OUT" = "trim-order	rung	an ordered trim never happened: leader lead-a ordered it 8m ago and no trim event has arrived since (bound 7m)" ] \
    || fail "a stale order rings the leader with the age and the bound, got: '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the stale order rings the leader once, inbox has $(inbox_count lead-a)"
  body=$(newest_inbox_body lead-a)
  assert_contains "$body" "signal: c1 trim-order: an ordered trim never happened: leader lead-a ordered it 8m ago" "the ring names the crewmate and how long ago the order was given"
  assert_contains "$body" "no trim event has arrived since" "and that no trim ever came"
  assert_contains "$body" "FM_HOME=$HOME_DIR bin/fm-lead.sh trim --leader lead-a c1" "the ring says how to order it again"
  assert_not_contains "$body" "keep the spec" "the leader's own focus is not read back to it as news"
  [ "$(ledger_rows c1)" = "trim-order rung" ] || fail "the ledger records the ring, got: $(ledger_rows c1)"
  [ "$(inbox_count c1)" -eq 0 ] || fail "nothing reaches the crewmate"
  # The same order, checked again: one episode, one ring.
  run_signals FM_VITALS_NOW="$((NOW + 600))" -- c1
  assert_contains "$OUT" "trim-order	silent	" "the same order is silent on the next check, got: '$OUT'"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the same order does not ring twice, inbox has $(inbox_count lead-a)"
  [ "$(ledger_count c1)" -eq 1 ] || fail "and adds no row, ledger has $(ledger_count c1)"

  # A crewmate mid-turn has an order that is waiting, not one that was lost:
  # a typed /compact runs at its next turn boundary, so however old the order
  # is, a busy crewmate never rings this signal.
  mkdir -p "$DATA/c2/trims"
  printf 'ordered\t%s\tlead-a\tkeep the spec\n' "$((NOW - 5000))" > "$DATA/c2/trims/index"
  row_assistant $((NOW - 60)) m1 100 0 0 10 "$(tool_bash 'bash tests/slow.test.sh')" >> "$(transcript c2)"
  run_signals FM_VITALS_NOW="$NOW" -- c2
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "a busy crewmate never rings a stale order, got rc=$RC '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "and nothing is sent for it, inbox has $(inbox_count lead-a)"
  [ ! -e "$DATA/c2/signals" ] || fail "and no row is written for it"
  # The same ledger the moment the crewmate's turn ends: the order is lost, and
  # this rings.
  row_assistant $((NOW - 50)) m2 100 0 0 10 >> "$(transcript c2)"
  run_signals FM_VITALS_NOW="$NOW" -- c2
  assert_contains "$OUT" "trim-order	rung	an ordered trim never happened: leader lead-a ordered it 83m ago" "the same order rings once the crewmate is idle"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "the idle crewmate's stale order rings the leader, inbox has $(inbox_count lead-a)"
  [ "$(ledger_rows c2)" = "trim-order rung" ] || fail "the ledger records the ring, got: $(ledger_rows c2)"
  : > "$(transcript c2)"
  rm -rf "$DATA/c2/signals"

  # An order inside the bound is an ordinary slow trim: nothing rings.
  printf 'ordered\t%s\tlead-a\tkeep the spec\n' "$((NOW - 100))" > "$DATA/c2/trims/index"
  run_signals FM_VITALS_NOW="$NOW" -- c2
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "an order inside the bound rings nothing, got rc=$RC '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "and sends nothing, inbox has $(inbox_count lead-a)"
  [ "$(ledger_count c2)" -eq 0 ] || fail "and writes no row, ledger has $(ledger_count c2)"

  # An order the crewmate's trim answered inside the bound never rings, at any
  # later age: the trim line cleared it.
  {
    printf 'ordered\t%s\tlead-a\tkeep the spec\n' "$((NOW - 5000))"
    printf '1\tmanual\t%s\t120000\t-\tordered:lead-a\n' "$((NOW - 4900))"
  } > "$DATA/c2/trims/index"
  run_signals FM_VITALS_NOW="$NOW" -- c2
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "an answered order never rings, however old, got rc=$RC '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "and sends nothing, inbox has $(inbox_count lead-a)"
  # An order the leader itself abandoned is closed too.
  {
    printf 'ordered\t%s\tlead-a\tkeep the spec\n' "$((NOW - 5000))"
    printf 'order-failed\t%s\n' "$((NOW - 4990))"
  } > "$DATA/c2/trims/index"
  run_signals FM_VITALS_NOW="$NOW" -- c2
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "an order-failed line closes the order, got rc=$RC '$OUT' ($ERR)"
  [ "$(queue_records)" -eq 0 ] || fail "First Mate is not woken for any of it"
  pass "an ordered trim nothing answered rings its leader once past the bound, naming the crewmate, the age and that no trim event came, and only while the crewmate is idle: a busy one is never reported however old the order, and an order inside the bound, one a trim answered and one the leader abandoned ring nobody"
}

# --- an automatic trim does not answer the leader's order --------------------
# The leader's /compact is queued behind the crewmate's turn; the harness's own
# auto-trim window can be crossed first. That automatic trim is not the trim
# the leader ordered, so the order still stands and this signal still owes the
# leader a ring when the queued /compact never runs.
test_an_automatic_trim_does_not_answer_the_order() {
  make_home auto-order
  mkdir -p "$DATA/c1/trims"
  {
    printf 'ordered\t%s\tlead-a\tkeep the spec\n' "$((NOW - 500))"
    printf '1\tauto\t%s\t138000\t-\n' "$((NOW - 400))"
  } > "$DATA/c1/trims/index"
  run_signals FM_VITALS_NOW="$NOW" -- c1
  [ "$RC" -eq 0 ] || fail "the detector exits 0, got $RC: $ERR"
  assert_contains "$OUT" "trim-order	rung	an ordered trim never happened: leader lead-a ordered it 8m ago" \
    "an automatic trim leaves the order standing, so the stale ring still fires"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "the leader is rung once, inbox has $(inbox_count lead-a)"
  # The ordered manual trim that follows answers it: silent from then on, at
  # any later age.
  printf '2\tmanual\t%s\t120000\t-\tordered:lead-a\n' "$((NOW - 300))" >> "$DATA/c1/trims/index"
  rm -rf "$DATA/c1/signals"
  run_signals FM_VITALS_NOW="$((NOW + 5000))" -- c1
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "the ordered manual trim closes the order, got rc=$RC '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "and rings nobody again, inbox has $(inbox_count lead-a)"
  [ "$(queue_records)" -eq 0 ] || fail "First Mate is not woken for any of it"
  pass "an automatic trim never answers a leader's order - the stale ring still owes the leader one - and the manual trim the leader ordered closes it"
}

# --- the writer and the reader resolve data/ the same way --------------------
# FM_DATA_OVERRIDE points data/ somewhere other than $FM_HOME/data. The order
# bin/fm-lead.sh writes must be the order this check reads: a writer that built
# its path from FM_HOME alone would drop the order into a file nothing ever
# opens - no nudge, no ring, no error, nothing for a leader to notice.
test_an_order_lands_where_the_check_reads_it() {
  local elsewhere ordered_at
  make_home order-elsewhere
  elsewhere="$TMP_ROOT/order-elsewhere/elsewhere-data"
  cp -R "$DATA" "$elsewhere"
  ordered_at=$(date +%s)
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$elsewhere" \
    FM_FAKE_STATE="$STATE" FM_SEND_LOG="$HOME_DIR/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-lead.sh" trim --leader lead-a c1 keep the spec \
    >/dev/null 2>"$HOME_DIR/lead.err" \
    || fail "the leader's trim order must land under the override:"$'\n'"$(cat "$HOME_DIR/lead.err")"
  run_signals FM_DATA_OVERRIDE="$elsewhere" FM_VITALS_NOW="$((ordered_at + 500))" -- c1
  [ "$RC" -eq 0 ] || fail "the detector exits 0, got $RC: $ERR"
  assert_contains "$OUT" "trim-order	rung	an ordered trim never happened: leader lead-a" \
    "the check reads the order the leader wrote, wherever data/ was pointed"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "and rings the leader once, inbox has $(inbox_count lead-a)"
  [ "$(queue_records)" -eq 0 ] || fail "First Mate is not woken for it"
  pass "with data/ pointed away from FM_HOME, the order bin/fm-lead.sh writes is the order the signals check reads: writer and reader resolve the directory the same way"
}

test_dead_leader_is_recorded_once() {
  make_home dead
  plant_loop c1
  run_signals FM_FAKE_GONE_WINDOWS=fm-lead-a -- c1
  [ "$OUT" = "loop	failed:leader-dead	loop 3x Bash bash tests/x.test.sh in the last 30 calls" ] \
    || fail "a dead leader is a failed ring, got: '$OUT' ($ERR)"
  [ "$(inbox_count lead-a)" -eq 0 ] || fail "nothing is sent to a dead leader"
  [ ! -s "$HOME_DIR/send.log" ] || fail "no doorbell rang"
  [ "$(ledger_rows c1)" = "loop failed:leader-dead" ] || fail "the ledger records the failure, got: $(ledger_rows c1)"
  run_signals FM_FAKE_GONE_WINDOWS=fm-lead-a -- c1
  assert_contains "$OUT" "loop	silent" "the failed episode is not retried every check"
  [ "$(ledger_count c1)" -eq 1 ] || fail "one row for the failed episode, got $(ledger_count c1)"
  # A leader whose record is gone: no-record, once.
  rm -f "$STATE/lead-a.meta"
  rm -rf "$DATA/c1/signals"
  run_signals -- c1
  assert_contains "$OUT" "loop	failed:leader-no-record" "a leader with no record is a failed ring"
  [ "$(queue_records)" -eq 0 ] || fail "no wake record either way"
  pass "a dead or unrecorded leader gets one failed row and no send; the episode is not retried on every check; First Mate is not woken"
}

test_loop_rings_once_per_episode
test_stall_rings_only_while_busy
test_drift_candidate_rings_without_a_logbook_change
test_unled_crewmate_never_rings
test_transcript_beats_the_report
test_a_trim_summary_is_not_a_stall
test_a_live_helper_holds_the_stall_but_never_disables_it
test_the_ring_carries_no_logbook_words
test_watcher_rings_from_its_poll_and_stays_quiet
test_a_trim_order_that_was_never_answered_rings_the_leader
test_an_automatic_trim_does_not_answer_the_order
test_an_order_lands_where_the_check_reads_it
test_dead_leader_is_recorded_once
