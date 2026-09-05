#!/usr/bin/env bash
# tests/fm-lead-route-up.test.sh - the chain: a led crewmate's door is its
# leader's.
#
# bin/fm-lead-relay.sh rings each NEW keyed door line of a led crewmate
# (needs-decision or blocked carrying a [key=<slug>] token; leader= in its
# meta) into its leader's steering inbox through bin/fm-send.sh, once, and
# writes what it did into the crewmate's door ledger, data/<id>/doors/index,
# behind a cursor. bin/fm-watch.sh then holds the door with the leader: the
# crewmate's status span made only of rung doors, and its bare turn-end, are
# absorbed (no wake record, a triage-log line) while the leader's endpoint is
# alive and the door is open; a dead leader, a failed ring, an unled crewmate
# or any other captain-relevant line in the span surfaces exactly as before; a
# door held past FM_LEADER_ESCALATE_SECS, or whose leader dies holding it,
# wakes First Mate once (an escalated row); a door the status log closes is
# recorded answered. The relay is driven
# directly; the watcher runs as a real subprocess over a stubbed tmux whose
# inventory and pane command decide who is alive, with a pane that changes on
# every capture so the stale backbone never enters the picture.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

RELAY="$ROOT/bin/fm-lead-relay.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-lead-route-up)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

DOOR='needs-decision: [key=story-size] mem-12 is two stories, not one; split it?'
BLOCK='blocked: [key=stuck] the document gate refuses the playbook trigger'
WORKING_STATE='state: working · source: run-step · validating (running)'
IDLE_STATE='state: idle · source: none · stopped at its door'

# The fake tmux the chain suites drive the leader's liveness with (its shape
# is tests/wake-helpers.sh's make_fake_chain_tmux; the inventory and the pane
# command decide who is alive, and the doorbell lands in FM_SEND_LOG).
make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  make_fake_chain_tmux "$fakebin"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$fakebin"
}

write_task() {  # <home> <id> [meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
}

# make_home <name>: HOME_DIR, STATE, DATA, FAKEBIN; lead-a leads c1 and c3,
# lead-b leads c2, u1 is led by nobody.
make_home() {
  HOME_DIR="$TMP_ROOT/$1/home"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  mkdir -p "$STATE" "$DATA"
  FAKEBIN=$(make_fakebin "$TMP_ROOT/$1")
  write_task "$HOME_DIR" lead-a "leads=1"
  write_task "$HOME_DIR" lead-b "leads=1"
  write_task "$HOME_DIR" c1 "leader=lead-a"
  write_task "$HOME_DIR" c2 "leader=lead-b"
  write_task "$HOME_DIR" c3 "leader=lead-a"
  write_task "$HOME_DIR" u1
  set_case_env
}

# The environment every relay and watcher of a case runs under (CASE_ENV, set
# by make_home): the fake tmux first on PATH, this home explicit for fm-send,
# the case's state and data, a provably-working crew unless a case says
# otherwise. Used as `env "${CASE_ENV[@]}" ...` directly, never through a
# function, so a backgrounded watcher's pid is the watcher's own.
set_case_env() {
  CASE_ENV=(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
    FM_FAKE_STATE="$STATE" FM_SEND_LOG="$HOME_DIR/send.log" FM_SEND_SETTLE=0
    FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" FM_FAKE_CREW_STATE="$WORKING_STATE"
    FM_FAKE_CAPTURE_COUNT="$HOME_DIR/capture.count")
}

run_relay() {  # [ENV=val...] -- <task-id>: sets RC and ERR
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env "${CASE_ENV[@]}" ${envs[@]+"${envs[@]}"} "$RELAY" "$HOME_DIR" "$1" > "$HOME_DIR/relay.out" 2> "$HOME_DIR/relay.err"
  RC=$?
  ERR=$(cat "$HOME_DIR/relay.err")
  [ ! -s "$HOME_DIR/relay.out" ] || fail "the relay prints nothing on stdout, got:"$'\n'"$(cat "$HOME_DIR/relay.out")"
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

inbox_count() {  # <id>
  local n=0 f
  for f in "$STATE/$1.inbox"/*.msg; do [ -f "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# The ledger's rows as "<result> <key>" words, one per line.
door_rows() {  # <id>
  [ -f "$DATA/$1/doors/index" ] || return 0
  cut -f2,4 "$DATA/$1/doors/index" | tr '\t' ' '
}

queue_records() {
  [ -f "$STATE/.wake-queue" ] || { printf 0; return 0; }
  grep -c . "$STATE/.wake-queue" || true
}

# 0 when the queue holds at least one record and every record is a signal
# wake on <key> (the watcher lists a file once per scan of the grace window,
# so a surfaced signal may carry two records; both are the same wake).
queue_is_signal_on() {  # <key>
  [ "$(queue_records)" -ge 1 ] || return 1
  [ "$(grep -c . "$STATE/.wake-queue")" = "$(grep -c $'\tsignal\t'"$1"$'\t' "$STATE/.wake-queue")" ]
}

# The watcher as a real subprocess; tight poll and grace, no check or
# heartbeat cadence, a wedge threshold this file never reaches. WPID and WOUT.
watch_bg() {  # [ENV=val...]
  WOUT="$HOME_DIR/watch.out"
  : > "$WOUT"
  env "${CASE_ENV[@]}" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=999 "$@" "$WATCH" > "$WOUT" 2> "$HOME_DIR/watch.err" &
  WPID=$!
}

reap() { kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; }

# What the watcher said, for a failure message: its wake line, its stderr,
# its triage log and the wake queue.
watch_report() {
  printf 'out: %s\nerr: %s\ntriage: %s\nqueue: %s' "$(cat "$WOUT" 2>/dev/null)" \
    "$(tail -20 "$HOME_DIR/watch.err" 2>/dev/null)" \
    "$(tail -20 "$STATE/.watch-triage.log" 2>/dev/null)" "$(cat "$STATE/.wake-queue" 2>/dev/null)"
}

# Present and acknowledge the queue the way a handling turn does (the shape
# tests/fm-watch-triage.test.sh uses), so a restarted watcher does not
# re-surface the wake it already handed over.
ack_stopped_cycle() {
  local err sequence generation
  err="$HOME_DIR/drain.err"
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

set_mtime() {  # <epoch> <file>
  local stamp
  if stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$2"
  else
    stamp=$(date -d "@$1" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$2"
  fi
}

# Wait until the watcher logs an absorb matching <needle>; 1 if it exits first
# (it surfaced instead), which is exactly the unheld shape.
wait_absorbed() {  # <needle> [limit-ticks]
  local i=0 limit=${2:-150}
  while [ "$i" -lt "$limit" ]; do
    grep -Fq "$1" "$STATE/.watch-triage.log" 2>/dev/null && return 0
    kill -0 "$WPID" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# 0 once the watcher has exited (it woke First Mate), 1 if it is still running
# after the budget.
wait_exit() {  # [limit-ticks]
  local i=0 limit=${1:-150}
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$WPID" 2>/dev/null || { wait "$WPID" 2>/dev/null || true; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Wait for a whole poll cycle of the live watcher (the beacon advancing past a
# fresh value; see tests/fm-watch-triage.test.sh); 1 if it exited.
wait_cycle() {
  local beat first now i=0
  beat="$STATE/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$WPID" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt 300 ]; do
    kill -0 "$WPID" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- 1. the relay: each keyed door reaches the leader once ------------------
test_relay_rings_each_keyed_door_once() {
  local body
  make_home ring
  printf 'working: reading the brief\n%s\n%s\n' "$DOOR" "$BLOCK" > "$STATE/c1.status"
  run_relay -- c1
  expect_code 0 "$RC" "the relay exits 0: $ERR"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "both doors are rung into the leader's inbox, got $(inbox_count lead-a) records"
  body=$(inbox_body "$STATE/lead-a.inbox/001.msg")
  [ "$(printf '%s\n' "$body" | sed -n '1p')" = 'door: c1 needs-decision [key=story-size] mem-12 is two stories, not one; split it?' ] \
    || fail "the first line names the crewmate, the verb, the key and the note, got:"$'\n'"$body"
  assert_contains "$body" "bin/fm-lead.sh steer --leader lead-a c1 --resolve-key story-size" "the second line is the exact steer that closes the door"
  assert_contains "$body" "or escalate it to First Mate in your status" "the leader's other way out is named"
  assert_contains "$body" "FM_HOME=$HOME_DIR " "the steer names this home, so it cannot resolve against another"
  body=$(inbox_body "$STATE/lead-a.inbox/002.msg")
  assert_contains "$body" "door: c1 blocked [key=stuck] the document gate refuses the playbook trigger" "a keyed blocked line is a door too"
  [ "$(grep -c . "$HOME_DIR/send.log")" -eq 2 ] || fail "one doorbell per door reaches the leader's pane, got:"$'\n'"$(cat "$HOME_DIR/send.log")"
  [ "$(door_rows c1 | tr '\n' ',')" = 'rung story-size,rung stuck,' ] || fail "the ledger records both rings, got:"$'\n'"$(door_rows c1)"
  [ "$(cut -f3 "$DATA/c1/doors/index" | sort -u)" = lead-a ] || fail "each row names the leader"
  [ "$(cut -f5 "$DATA/c1/doors/index" | sed -n '1p')" = "$DOOR" ] || fail "each row carries the status line itself"
  [ "$(cat "$DATA/c1/doors/cursor")" = 3 ] || fail "the cursor counts the status lines read, got $(cat "$DATA/c1/doors/cursor")"
  [ ! -e "$STATE/c1.inbox" ] || fail "nothing reaches the crewmate"
  run_relay -- c1
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "a second run rings nothing again (the cursor holds)"
  [ "$(door_rows c1 | wc -l | tr -d ' ')" -eq 2 ] || fail "a second run writes no row"
  printf 'resolved: [key=story-size] leader: one story\nworking: on it\nblocked: no key here, First Mate reads this one\n' >> "$STATE/c1.status"
  run_relay -- c1
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "a resolved line, a working note and an unkeyed blocked line are not doors; got $(inbox_count lead-a) records"
  [ "$(cat "$DATA/c1/doors/cursor")" = 6 ] || fail "the cursor still advances past them, got $(cat "$DATA/c1/doors/cursor")"
  printf 'needs-decision: [key=scope] drop the docs row?\n' >> "$STATE/c1.status"
  run_relay -- c1
  [ "$(inbox_count lead-a)" -eq 3 ] || fail "a new keyed door after the cursor is rung"
  [ "$(door_rows c1 | tail -1)" = 'rung scope' ] || fail "and recorded, got:"$'\n'"$(door_rows c1)"
  pass "relay: every new keyed door is rung into the leader's inbox exactly once, with the closing steer, and recorded in the ledger behind the cursor"
}

# --- 2. the relay reads exactly the lines its cursor will record -----------
# A ring takes real time (the doorbell plus FM_SEND_SETTLE) and the crewmate
# is live throughout it. Here the fake tmux appends a SECOND keyed door line
# the first time the doorbell is typed - the fork window, reproduced with no
# sleeping - and the relay must ring it on the NEXT run, once, never twice.
test_relay_rings_only_the_lines_it_counted() {
  make_home fork
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-under"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    if [ -n "${FM_FAKE_APPEND_ONCE_FILE:-}" ] && [ ! -f "${FM_FAKE_APPEND_ONCE_MARK:-/nonexistent}" ]; then
      : > "$FM_FAKE_APPEND_ONCE_MARK"
      printf '%s\n' "${FM_FAKE_APPEND_ONCE_LINE:-}" >> "$FM_FAKE_APPEND_ONCE_FILE"
    fi ;;
esac
exec "$(dirname "$0")/tmux-under" "$@"
SH
  chmod +x "$FAKEBIN/tmux"
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay FM_FAKE_APPEND_ONCE_FILE="$STATE/c1.status" FM_FAKE_APPEND_ONCE_MARK="$HOME_DIR/appended.once" \
    FM_FAKE_APPEND_ONCE_LINE="$BLOCK" -- c1
  expect_code 0 "$RC" "the relay exits 0: $ERR"
  [ -f "$HOME_DIR/appended.once" ] || fail "the fork window did not open: no line was appended while the relay was ringing"
  [ "$(grep -c . "$STATE/c1.status")" -eq 2 ] || fail "the crewmate's status file holds both door lines, got:"$'\n'"$(cat "$STATE/c1.status")"
  [ "$(door_rows c1 | tr '\n' ',')" = 'rung story-size,' ] || fail "the first run rings only the line it counted, got:"$'\n'"$(door_rows c1)"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "one record reaches the leader, got $(inbox_count lead-a)"
  [ "$(cat "$DATA/c1/doors/cursor")" = 1 ] || fail "the cursor claims exactly the line it read, got $(cat "$DATA/c1/doors/cursor")"
  run_relay -- c1
  expect_code 0 "$RC" "the second run exits 0: $ERR"
  [ "$(door_rows c1 | tr '\n' ',')" = 'rung story-size,rung stuck,' ] || fail "the second run rings the appended door exactly once, got:"$'\n'"$(door_rows c1)"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "one record per door line, got $(inbox_count lead-a)"
  [ "$(cat "$DATA/c1/doors/cursor")" = 2 ] || fail "the cursor now covers both lines, got $(cat "$DATA/c1/doors/cursor")"
  run_relay -- c1
  [ "$(door_rows c1 | wc -l | tr -d ' ')" -eq 2 ] || fail "a third run adds no row, got:"$'\n'"$(door_rows c1)"
  [ "$(inbox_count lead-a)" -eq 2 ] || fail "and no record"
  pass "relay: a door line appended while the relay is ringing is left to the next run, so every door is rung exactly once and the cursor claims exactly the lines that were read"
}

# --- 3. the relay: what is not a leader's door ------------------------------
test_relay_leaves_the_unled_alone() {
  make_home unled
  printf '%s\n' "$DOOR" > "$STATE/u1.status"
  run_relay -- u1
  expect_code 0 "$RC" "an unled crewmate's relay exits 0: $ERR"
  [ ! -e "$DATA/u1/doors" ] || fail "an unled crewmate gets no ledger"
  [ "$(inbox_count lead-a)$(inbox_count lead-b)" = 00 ] || fail "and rings nobody"
  [ ! -s "$HOME_DIR/send.log" ] || fail "no doorbell for an unled crewmate"
  run_relay -- nosuch
  expect_code 0 "$RC" "a task without a record exits 0 quietly"
  env "${CASE_ENV[@]}" "$RELAY" "$HOME_DIR" 'bad/id' >/dev/null 2>&1 && fail "a path-shaped task id is a usage error"
  env "${CASE_ENV[@]}" "$RELAY" "$HOME_DIR" >/dev/null 2>&1 && fail "a missing task id is a usage error"
  pass "relay: an unled crewmate, a task without a record and bad arguments ring nobody and write nothing"
}

# --- 4. the relay: a failure is recorded, never sent ------------------------
test_relay_records_failures_without_sending() {
  make_home failures
  printf '%s\n' "$DOOR" > "$STATE/c2.status"
  run_relay FM_FAKE_SHELL_WINDOWS=fm-lead-b -- c2
  expect_code 0 "$RC" "a dead leader is exit 0: $ERR"
  [ "$(door_rows c2)" = 'failed:leader-dead story-size' ] || fail "a leader whose pane fell to its shell is recorded dead, got:"$'\n'"$(door_rows c2)"
  [ "$(inbox_count lead-b)" -eq 0 ] || fail "nothing is sent to a dead leader"
  [ ! -s "$HOME_DIR/send.log" ] || fail "no doorbell for a dead leader"
  printf '%s\n' "$BLOCK" >> "$STATE/c2.status"
  run_relay FM_FAKE_GONE_WINDOWS=fm-lead-b -- c2
  [ "$(door_rows c2 | tail -1)" = 'failed:leader-dead stuck' ] || fail "a leader whose window is gone is dead too, got:"$'\n'"$(door_rows c2)"
  write_task "$HOME_DIR" c4 "leader=ghost"
  printf '%s\n' "$DOOR" > "$STATE/c4.status"
  run_relay -- c4
  [ "$(door_rows c4)" = 'failed:leader-no-record story-size' ] || fail "a leader without a record is recorded as such, got:"$'\n'"$(door_rows c4)"
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "$DOOR" > "$STATE/c1.status"
    mkdir -p "$STATE/lead-a.inbox"
    chmod 500 "$STATE/lead-a.inbox"
    run_relay -- c1
    chmod 700 "$STATE/lead-a.inbox"
    expect_code 0 "$RC" "a failed send is exit 0: $ERR"
    [ "$(door_rows c1)" = 'failed:send story-size' ] || fail "a send fm-send could not record is failed:send, got:"$'\n'"$(door_rows c1)"
    [ "$(inbox_count lead-a)" -eq 0 ] || fail "no record landed"
  fi
  printf '%s\n' "$DOOR" > "$STATE/c3.status"
  mkdir -p "$DATA/c3/doors/.lock"
  run_relay -- c3
  expect_code 0 "$RC" "a relay that meets a live lock steps aside: $ERR"
  [ -z "$(door_rows c3)" ] || fail "and rings nothing"
  set_mtime "$(( $(date +%s) - 300 ))" "$DATA/c3/doors/.lock"
  run_relay -- c3
  [ "$(door_rows c3)" = 'rung story-size' ] || fail "a lock older than two minutes is a crashed relay's and is taken over, got:"$'\n'"$(door_rows c3)"
  [ ! -d "$DATA/c3/doors/.lock" ] || fail "the lock is released on exit"
  pass "relay: a dead, gone or unrecorded leader and a send that did not land are ledger rows without a ring; a live lock steps aside, a stale one is taken over"
}

# --- 5. the watcher: a held door is not First Mate's wake ------------------
test_watcher_absorbs_a_held_door_and_its_turn_end() {
  make_home held
  # The hook shape: the Stop hook rang the door before the watcher saw it.
  printf '%s\nworking: waiting at the door\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "fixture: the door was rung"
  : > "$STATE/c1.turn-ended"
  watch_bg FM_FAKE_CREW_STATE_c1="$IDLE_STATE"
  wait_absorbed "absorbed door signal held by leader lead-a: $STATE/c1.status" \
    || fail "the crewmate's door line is absorbed while its leader holds the door; watcher out:"$'\n'"$(watch_report)"
  wait_absorbed "absorbed door signal held by leader lead-a: $STATE/c1.turn-ended" \
    || fail "and so is its turn-end (a crewmate stopping at its door is the expected shape)"
  [ "$(queue_records)" -eq 0 ] || fail "no wake record for a held door, got:"$'\n'"$(cat "$STATE/.wake-queue")"
  kill -0 "$WPID" 2>/dev/null || fail "the watcher keeps its cycle"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "a door the hook rang is not rung again by the watcher"
  wait_cycle || fail "the watcher stays alive over the next poll"
  wait_cycle || fail "and the one after"
  [ "$(queue_records)" -eq 0 ] || fail "the absorbed door is not re-read into a wake later"
  [ "$(grep -c 'absorbed door signal' "$STATE/.watch-triage.log")" -eq 2 ] || fail "each signal is absorbed once, got:"$'\n'"$(cat "$STATE/.watch-triage.log")"
  reap
  # The race shape: the crewmate wrote its door and the hook has not run yet;
  # the watcher rings it itself, once, then holds it.
  make_home held-race
  printf '%s\n' "$BLOCK" > "$STATE/c3.status"
  watch_bg
  wait_absorbed "absorbed door signal held by leader lead-a: $STATE/c3.status" \
    || fail "a door the hook has not rung is rung by the watcher and held; out:"$'\n'"$(watch_report)"
  [ "$(door_rows c3)" = 'rung stuck' ] || fail "the watcher's own ring is in the ledger, got:"$'\n'"$(door_rows c3)"
  [ "$(inbox_count lead-a)" -eq 1 ] || fail "and in the leader's inbox"
  [ "$(queue_records)" -eq 0 ] || fail "no wake record"
  reap
  pass "watcher: a led crewmate's door its live leader holds is absorbed with its turn-end - no wake, a triage line, rung once whether by the hook or the watcher"
}

# --- 5b. the absorb marks the bytes it judged, never the ones that arrived ---
# The window: leader_holds_signal reads the span, then the relay fork, fm-send
# and the settle run before leader_absorb_signals marks the file. A `done:`
# line the crewmate appends in that window was never classified, so it must
# not be marked classified - it must still wake First Mate.
test_absorb_marks_only_the_bytes_it_judged() {
  local driver out marked size
  make_home absorb-window
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  [ "$(door_rows c1)" = 'rung story-size' ] || fail "fixture: the door was rung to a live leader"
  # The watcher's own two halves, driven in order with the append between them.
  driver="$HOME_DIR/drive-absorb.sh"
  cat > "$driver" <<'SH'
set -u
# shellcheck source=/dev/null
. "$1"
f="$STATE/c1.status"
sf=$(fm_wake_signal_seen_path "$STATE" "$f")
sig=$(fm_wake_signal_sig "$f")
leader_holds_signal "$f" || { echo "DRIVER: the door was not held" >&2; exit 1; }
end=$FM_HELD_SPAN_END
printf 'done: PR ready, checks green
' >> "$f"
leader_absorb_signals "$sf$(printf '	')$sig$(printf '	')$f$(printf '	')$end$(printf '	')$FM_HELD_SPAN_IDENT"
printf 'judged=%s marked=%s size=%s
' "$end" "$(fm_wake_signal_seen_size "$STATE" "$f")"   "$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')"
SH
  out=$(env "${CASE_ENV[@]}" bash "$driver" "$ROOT/bin/fm-watch.sh" 2> "$HOME_DIR/driver.err") \
    || fail "the driver must run both halves: $out"$'\n'"$(cat "$HOME_DIR/driver.err")"
  marked=$(printf '%s' "$out" | sed -n 's/.*marked=\([0-9]*\).*/\1/p')
  size=$(printf '%s' "$out" | sed -n 's/.*size=\([0-9]*\).*/\1/p')
  [ -n "$marked" ] && [ -n "$size" ] || fail "the driver reports what it judged and marked, got: $out"
  [ "$marked" -lt "$size" ] || fail "the done: line's bytes are still unclassified after the absorb (marked=$marked, size=$size): $out"
  grep -Fq "absorbed door signal held by leader lead-a: $STATE/c1.status" "$STATE/.watch-triage.log" \
    || fail "the door itself was absorbed: $(cat "$STATE/.watch-triage.log" 2>/dev/null)"
  [ "$(queue_records)" -eq 0 ] || fail "the absorb wakes nobody by itself"
  # The next poll reads the unclassified bytes and wakes First Mate with them.
  watch_bg
  wait_exit || fail "the done: line the absorb never classified wakes First Mate at the next poll; out:"$'\n'"$(watch_report)"
  queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  pass "the chain absorb marks exactly the bytes leader_holds_signal judged: a done: line appended in the window between the span read and the mark stays unclassified and wakes First Mate at the next poll"
}

# --- 5c. the absorb marks the file it judged, never the one that replaced it -
# The same window, the other half of the record: the crewmate is torn down and
# respawned inside it, so the status log at absorb time is a DIFFERENT file.
# Binding the old file's offset to the new file's identity would mark the new
# log's first bytes as already read, and a door inside them would never be
# classified.
test_absorb_marks_nothing_when_the_status_file_was_replaced() {
  local driver out marked size
  make_home absorb-recreated
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  [ "$(door_rows c1)" = 'rung story-size' ] || fail "fixture: the door was rung to a live leader"
  driver="$HOME_DIR/drive-recreated.sh"
  cat > "$driver" <<'SH'
set -u
# shellcheck source=/dev/null
. "$1"
f="$STATE/c1.status"
sf=$(fm_wake_signal_seen_path "$STATE" "$f")
sig=$(fm_wake_signal_sig "$f")
leader_holds_signal "$f" || { echo "DRIVER: the door was not held" >&2; exit 1; }
end=$FM_HELD_SPAN_END
ident=$FM_HELD_SPAN_IDENT
# The teardown-and-respawn: a brand new file, same path, different inode.
rm -f "$f"
printf 'working: fresh session
done: PR ready, checks green
' > "$f"
leader_absorb_signals "$sf$(printf '\t')$sig$(printf '\t')$f$(printf '\t')$end$(printf '\t')$ident"
printf 'judged=%s marked=%s size=%s
' "$end" "$(fm_wake_signal_seen_size "$STATE" "$f")"   "$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')"
SH
  out=$(env "${CASE_ENV[@]}" bash "$driver" "$ROOT/bin/fm-watch.sh" 2> "$HOME_DIR/driver.err") \
    || fail "the driver must run both halves: $out"$'\n'"$(cat "$HOME_DIR/driver.err")"
  marked=$(printf '%s' "$out" | sed -n 's/.*marked=\([0-9]*\).*/\1/p')
  size=$(printf '%s' "$out" | sed -n 's/.*size=\([0-9]*\).*/\1/p')
  [ -n "$marked" ] && [ -n "$size" ] || fail "the driver reports what it judged and marked, got: $out"
  [ "$marked" -eq 0 ] || fail "a status file replaced inside the absorb window keeps every byte unread (marked=$marked, size=$size): $out"
  # And the proof it matters: the new log's own first bytes are still read.
  watch_bg
  wait_exit || fail "the new log's done: line is read at the next poll; out:"$'\n'"$(watch_report)"
  queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  pass "a status log recreated between the hold and the absorb is marked not at all: the carried identity belongs to the file that was judged, so the new log's first bytes stay unread and the done: line inside them still reaches First Mate"
}

# --- 5d. the hold refuses a file that changed under the span read -----------
# The narrower window inside leader_holds_signal itself: the end and the
# identity are taken, then the span is read. A teardown-and-respawn landing in
# there leaves the OLD file's byte count bound to a SHORTER new log, and the
# absorb would mark a position past its end - every line the crewmate writes
# below it is then skipped for good. The identity is read again after the
# span, so a file that changed under it is held not at all and marked not at
# all, and the new log is read from its first byte at the next poll.
test_hold_refuses_a_status_file_that_changed_under_the_span_read() {
  local driver out held marked
  make_home hold-swapped
  {
    printf '%s\n' "$DOOR"
    printf 'working: reading the spec and the epic master plan before the first commit\n'
    printf 'working: writing the story card and the definition of done for the branch\n'
  } > "$STATE/c1.status"
  run_relay -- c1
  [ "$(door_rows c1)" = 'rung story-size' ] || fail "fixture: the door was rung to a live leader"
  driver="$HOME_DIR/drive-swapped.sh"
  cat > "$driver" <<'SH'
set -u
# shellcheck source=/dev/null
. "$1"
f="$STATE/c1.status"
sf=$(fm_wake_signal_seen_path "$STATE" "$f")
sig=$(fm_wake_signal_sig "$f")
door=$(head -n 1 "$f")
# The teardown-and-respawn lands between the two reads: the identity call that
# captures the file's identity replaces it - with a shorter log of the same
# shape - the moment it has read it, so the span and the identity read after
# it belong to a different file.
eval "$(declare -f status_file_identity | sed '1s/^status_file_identity/settled_status_file_identity/')"
armed=0
status_file_identity() {
  local ident rc
  ident=$(settled_status_file_identity "$@"); rc=$?
  if [ "$armed" -eq 1 ]; then
    armed=0
    rm -f "$f"
    printf '%s\n' "$door" > "$f"
  fi
  printf '%s' "$ident"
  return $rc
}
armed=1
if leader_holds_signal "$f"; then held=yes; else held=no; fi
armed=0
[ "$held" = no ] || leader_absorb_signals "$sf$(printf '\t')$sig$(printf '\t')$f$(printf '\t')$FM_HELD_SPAN_END$(printf '\t')$FM_HELD_SPAN_IDENT"
# What the respawned crewmate writes next sits BELOW the new log's first line
# and above the old file's byte count.
printf 'done: PR ready, checks green
' >> "$f"
printf 'held=%s marked=%s size=%s
' "$held" "$(fm_wake_signal_seen_size "$STATE" "$f")" "$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')"
SH
  out=$(env "${CASE_ENV[@]}" bash "$driver" "$ROOT/bin/fm-watch.sh" 2> "$HOME_DIR/driver.err") \
    || fail "the driver must run: $out"$'\n'"$(cat "$HOME_DIR/driver.err")"
  held=$(printf '%s' "$out" | sed -n 's/.*held=\([a-z]*\).*/\1/p')
  marked=$(printf '%s' "$out" | sed -n 's/.*marked=\([0-9]*\).*/\1/p')
  [ "$held" = no ] || fail "a status file replaced under the span read is held by nobody, got: $out"
  [ "$marked" = 0 ] || fail "and nothing of it is marked classified, got: $out"
  # And the proof it matters: the done: line the new session wrote below the
  # old file's byte count still reaches First Mate.
  watch_bg
  wait_exit || fail "the new log's done: line wakes First Mate at the next poll; out:"$'\n'"$(watch_report)"
  queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  pass "a status log replaced between the identity taken before the span and the one read after it is held not at all and marked not at all: no marker lands past the new, shorter log's end, and the done: line written below it still reaches First Mate"
}

# --- 5e. the same window, one step earlier: identity, then byte count -------
# The hold reads the identity FIRST and the byte count second. A respawn
# landing between those two commands would otherwise bind the OLD file's byte
# count to the NEW file - the count is taken from a handle opened on the old
# inode, the identity read afterwards would be the new file's, and the check
# at the end would find nothing wrong. Taking the identity first makes that
# swap a mismatch, so nothing is held and nothing is marked.
test_hold_refuses_a_status_file_replaced_before_the_byte_count() {
  local driver out held marked
  make_home hold-swapped-early
  {
    printf '%s\n' "$DOOR"
    printf 'working: reading the spec and the epic master plan before the first commit\n'
    printf 'working: writing the story card and the definition of done for the branch\n'
  } > "$STATE/c1.status"
  run_relay -- c1
  [ "$(door_rows c1)" = 'rung story-size' ] || fail "fixture: the door was rung to a live leader"
  driver="$HOME_DIR/drive-swapped-early.sh"
  cat > "$driver" <<'SH'
set -u
# shellcheck source=/dev/null
. "$1"
f="$STATE/c1.status"
sf=$(fm_wake_signal_seen_path "$STATE" "$f")
sig=$(fm_wake_signal_sig "$f")
door=$(head -n 1 "$f")
# The teardown-and-respawn lands on the byte count: the handle is already open
# on the old file, so the count is the old file's, while the path now holds a
# shorter new log.
armed=0
wc() {
  if [ "$armed" -eq 1 ]; then
    armed=0
    rm -f "$f"
    printf '%s\n' "$door" > "$f"
  fi
  command wc "$@"
}
armed=1
if leader_holds_signal "$f"; then held=yes; else held=no; fi
armed=0
[ "$held" = no ] || leader_absorb_signals "$sf$(printf '\t')$sig$(printf '\t')$f$(printf '\t')$FM_HELD_SPAN_END$(printf '\t')$FM_HELD_SPAN_IDENT"
printf 'done: PR ready, checks green
' >> "$f"
printf 'held=%s marked=%s size=%s
' "$held" "$(fm_wake_signal_seen_size "$STATE" "$f")" "$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')"
SH
  out=$(env "${CASE_ENV[@]}" bash "$driver" "$ROOT/bin/fm-watch.sh" 2> "$HOME_DIR/driver.err") \
    || fail "the driver must run: $out"$'\n'"$(cat "$HOME_DIR/driver.err")"
  held=$(printf '%s' "$out" | sed -n 's/.*held=\([a-z]*\).*/\1/p')
  marked=$(printf '%s' "$out" | sed -n 's/.*marked=\([0-9]*\).*/\1/p')
  [ "$held" = no ] || fail "a status file replaced before the byte count is held by nobody, got: $out"
  [ "$marked" = 0 ] || fail "and nothing of it is marked classified, got: $out"
  watch_bg
  wait_exit || fail "the new log's done: line wakes First Mate at the next poll; out:"$'\n'"$(watch_report)"
  queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  pass "a status log replaced between the identity read and the byte count is held not at all and marked not at all: the old file's count is never bound to the new file, and the done: line the new session writes still reaches First Mate"
}

# --- 6. the watcher: without a leader to hold it, the door surfaces ---------
test_watcher_surfaces_when_no_leader_holds_the_door() {
  make_home dead-leader
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  watch_bg FM_FAKE_SHELL_WINDOWS=fm-lead-a
  wait_exit || fail "a door under a dead leader wakes First Mate; out:"$'\n'"$(watch_report)"
  assert_contains "$(cat "$WOUT")" "signal: $STATE/c1.status" "as the ordinary signal wake"
  queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  [ "$(door_rows c1)" = 'failed:leader-dead story-size' ] || fail "the ledger says why the leader could not be rung, got:"$'\n'"$(door_rows c1)"
  [ "$(inbox_count lead-a)" -eq 0 ] || fail "nothing was sent to the dead leader"

  make_home unled-door
  printf '%s\n' "$DOOR" > "$STATE/u1.status"
  watch_bg
  wait_exit || fail "an unled crewmate's door wakes First Mate as before; out:"$'\n'"$(watch_report)"
  queue_is_signal_on u1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  [ ! -e "$DATA/u1/doors" ] || fail "an unled crewmate never gets a ledger"
  [ ! -f "$STATE/.watch-triage.log" ] || ! grep -q 'absorbed door signal' "$STATE/.watch-triage.log" \
    || fail "nothing of an unled crewmate is absorbed as a door"

  make_home other-line
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  printf 'done: PR https://example.test/pr/1 checks green\n' >> "$STATE/c1.status"
  watch_bg
  wait_exit || fail "a span with any other captain-relevant line wakes First Mate, door or no door; out:"$'\n'"$(watch_report)"
  queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
  [ "$(door_rows c1)" = 'rung story-size' ] || fail "the ledger is untouched by the surface, got:"$'\n'"$(door_rows c1)"

  if [ "$(id -u)" -ne 0 ]; then
    make_home ring-failed
    printf '%s\n' "$DOOR" > "$STATE/c1.status"
    mkdir -p "$STATE/lead-a.inbox"
    chmod 500 "$STATE/lead-a.inbox"
    watch_bg
    wait_exit || { chmod 700 "$STATE/lead-a.inbox"; fail "a door whose ring did not land wakes First Mate; out:"$'\n'"$(watch_report)"; }
    chmod 700 "$STATE/lead-a.inbox"
    queue_is_signal_on c1.status || fail "with its wake record, got:"$'\n'"$(watch_report)"
    [ "$(door_rows c1)" = 'failed:send story-size' ] || fail "and the ledger says the ring failed, got:"$'\n'"$(door_rows c1)"
  fi
  pass "watcher: a dead leader, an unled crewmate, another captain-relevant line in the span, or a ring that did not land surfaces the door to First Mate exactly as before"
}

# --- 7. the watcher: one escalation past the bound --------------------------
test_watcher_escalates_a_held_door_once_past_the_bound() {
  make_home overdue
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  prime_status_seen "$STATE" "$STATE/c1.status"
  sleep 1
  watch_bg FM_LEADER_ESCALATE_SECS=1
  wait_exit || fail "a door held past the bound wakes First Mate; out:"$'\n'"$(watch_report)"
  assert_contains "$(watch_report)" "signal: $STATE/c1.status (door [key=story-size] of c1 has stayed open" "the wake names the door, the crewmate and the age"
  assert_contains "$(watch_report)" "under its leader lead-a, past the 1s bound: the leader was rung and has not closed it" "and the leader"
  [ "$(queue_records)" -eq 1 ] || fail "one wake record, got:"$'\n'"$(cat "$STATE/.wake-queue")"
  grep -q $'\tsignal\tc1.status\t' "$STATE/.wake-queue" || fail "the record is a signal wake on the crewmate's status log, got:"$'\n'"$(cat "$STATE/.wake-queue")"
  [ "$(door_rows c1 | tr '\n' ',')" = 'rung story-size,escalated story-size,' ] || fail "the ledger records the escalation, got:"$'\n'"$(door_rows c1)"
  ack_stopped_cycle || fail "fixture: the escalation wake is presented and acknowledged"
  watch_bg FM_LEADER_ESCALATE_SECS=1
  wait_cycle || fail "a restarted watcher does not escalate the same door again; out:"$'\n'"$(watch_report)"
  wait_cycle || fail "nor on the next poll; out:"$'\n'"$(watch_report)"
  [ "$(queue_records)" -eq 0 ] || fail "no new wake record, got:"$'\n'"$(cat "$STATE/.wake-queue")"
  [ "$(door_rows c1 | grep -c escalated)" -eq 1 ] || fail "one escalated row"
  reap
  pass "watcher: a door held open past FM_LEADER_ESCALATE_SECS wakes First Mate once, as a signal wake naming the door and the leader, and never twice"
}

# --- 8. the watcher: a leader that dies holding a door holds nothing --------
test_watcher_wakes_at_once_when_a_holding_leader_dies() {
  make_home leader-died
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  [ "$(door_rows c1)" = 'rung story-size' ] || fail "fixture: the door was rung while the leader was alive"
  prime_status_seen "$STATE" "$STATE/c1.status"
  watch_bg FM_FAKE_SHELL_WINDOWS=fm-lead-a
  wait_exit || fail "a rung door whose leader has since died wakes First Mate at once, no bound; out:"$'\n'"$(watch_report)"
  assert_contains "$(cat "$WOUT")" "signal: $STATE/c1.status (door [key=story-size] of c1 was rung to its leader lead-a, whose endpoint no longer holds a live agent: nobody holds it)" "the wake says who died"
  grep -q $'\tsignal\tc1.status\t' "$STATE/.wake-queue" || fail "the record is a signal wake on the crewmate's status log, got:"$'\n'"$(cat "$STATE/.wake-queue")"
  [ "$(door_rows c1 | tr '\n' ',')" = 'rung story-size,escalated story-size,' ] || fail "the ledger records the escalation, got:"$'\n'"$(door_rows c1)"
  pass "watcher: a door rung to a leader that then died is First Mate's at the next poll, recorded escalated"
}

# --- 9. the watcher: a closed door is recorded answered ---------------------
test_watcher_records_an_answered_door() {
  make_home answered
  printf '%s\n' "$DOOR" > "$STATE/c1.status"
  run_relay -- c1
  printf 'resolved: [key=story-size] leader: one story, keep the docs row\n' >> "$STATE/c1.status"
  prime_status_seen "$STATE" "$STATE/c1.status"
  watch_bg FM_LEADER_ESCALATE_SECS=1
  wait_cycle || fail "the watcher stays alive over a closed door; out:"$'\n'"$(watch_report)"
  [ "$(door_rows c1 | tr '\n' ',')" = 'rung story-size,answered story-size,' ] || fail "a rung door the status log closes is recorded answered, got:"$'\n'"$(door_rows c1)"
  wait_cycle || fail "and the watcher goes on; out:"$'\n'"$(watch_report)"
  [ "$(door_rows c1 | grep -c answered)" -eq 1 ] || fail "recorded once"
  [ "$(queue_records)" -eq 0 ] || fail "a closed door is nobody's wake, got:"$'\n'"$(cat "$STATE/.wake-queue")"
  reap
  pass "watcher: a door the leader closed is recorded answered once and wakes nobody, bound or no bound"
}

test_relay_rings_each_keyed_door_once
test_relay_rings_only_the_lines_it_counted
test_relay_leaves_the_unled_alone
test_relay_records_failures_without_sending
test_watcher_absorbs_a_held_door_and_its_turn_end
test_absorb_marks_only_the_bytes_it_judged
test_absorb_marks_nothing_when_the_status_file_was_replaced
test_hold_refuses_a_status_file_that_changed_under_the_span_read
test_hold_refuses_a_status_file_replaced_before_the_byte_count
test_watcher_surfaces_when_no_leader_holds_the_door
test_watcher_escalates_a_held_door_once_past_the_bound
test_watcher_wakes_at_once_when_a_holding_leader_dies
test_watcher_records_an_answered_door
