#!/usr/bin/env bash
# tests/fm-lead-steer.test.sh - the leader's hands: steer and trim.
#
# bin/fm-lead.sh steer sends a crewmate ordinary text through bin/fm-send.sh
# (the durable inbox record plus the doorbell; --resolve-key closes a door),
# refuses a crewmate outside the leader's chain or one whose endpoint is
# dead, copies the first line into the leader's own status as a note: line so
# First Mate reads it at its next drain, and measures the steer's size
# (data/<leader>/steers/index; a warning over 1,200 characters, never a
# refusal). bin/fm-lead.sh trim types `/compact <focus>` through fm-send's
# typed plane after writing an `ordered` line into the crewmate's trims
# index, so bin/fm-trim-event.sh can attribute the manual trim that follows.
# trim then waits, bounded by FM_LEAD_TRIM_WAIT_SECS, for the crewmate's own
# PostCompact line in that ledger and sends one continue-steer through the
# inbox doorbell when it arrives; without it the leader is told and the exit
# is 3. These tests drive the real fm-lead over the real fm-send and a stubbed
# tmux whose inventory and pane command decide who is alive; a background
# helper plays the crewmate's PostCompact hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEAD="$ROOT/bin/fm-lead.sh"
TMP_ROOT=$(fm_test_tmproot fm-lead-steer)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# The fake tmux: `list-windows -t <session> -F '#{window_name}'` lists every
# window a record in FM_FAKE_STATE names except FM_FAKE_GONE_WINDOWS; the
# pane command is zsh for FM_FAKE_SHELL_WINDOWS (an agent that died to its
# shell) and claude otherwise; send-keys -l text is logged to FM_SEND_LOG;
# FM_FAKE_TMUX_SEND_FAIL=1 fails every send-keys.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
listed() {
  local w
  for w in ${FM_FAKE_GONE_WINDOWS:-}; do [ "$1" = "$w" ] && return 1; done
  return 0
}
shell_only() {
  local w
  for w in ${FM_FAKE_SHELL_WINDOWS:-}; do [ "$1" = "$w" ] && return 0; done
  return 1
}
target_window() {
  local prev= a
  for a in "$@"; do
    [ "$prev" = "-t" ] && { printf '%s' "${a#*:}"; return 0; }
    prev=$a
  done
}
case "$*" in
  *"#{pane_current_path}"*) printf '\n'; exit 0 ;;
  *"#{pane_current_command}"*)
    if shell_only "$(target_window "$@")"; then printf 'zsh\n'; else printf 'claude\n'; fi
    exit 0 ;;
  *cursor_y*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    for meta in "${FM_FAKE_STATE:-/nonexistent}"/*.meta; do
      [ -f "$meta" ] || continue
      w=$(sed -n 's/^window=[^:]*://p' "$meta" | head -1)
      [ -n "$w" ] || continue
      listed "$w" && printf '%s\n' "$w"
    done
    exit 0 ;;
  display-message)
    listed "$(target_window "$@")" || exit 1
    printf 'fakepane\n'; exit 0 ;;
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

make_home() {  # <name>: sets HOME_DIR and FAKEBIN; lead-a leads c1 and c3, lead-b leads c2
  HOME_DIR="$TMP_ROOT/$1/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
  FAKEBIN=$(make_fakebin "$TMP_ROOT/$1")
  write_task "$HOME_DIR" lead-a "leads=1"
  write_task "$HOME_DIR" lead-b "leads=1"
  write_task "$HOME_DIR" c1 "leader=lead-a"
  write_task "$HOME_DIR" c2 "leader=lead-b"
  write_task "$HOME_DIR" c3 "leader=lead-a"
}

write_task() {  # <home> <id> [meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
}

run_lead() {  # <home> [ENV=val...] -- <fm-lead args...>: sets RC, OUT, ERR
  local home=$1
  shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$home/send.log"
  OUT=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_LOG="$home/send.log" \
    FM_FAKE_STATE="$home/state" FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} "$LEAD" "$@" 2>"$home/lead.err")
  RC=$?
  ERR=$(cat "$home/lead.err")
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

record_header() {  # <record>: the header lines before --
  sed '/^--$/,$d' "$1"
}

# The crewmate's own PostCompact hook, played after <seconds>: the ledger line
# bin/fm-trim-event.sh appends once the compaction has run.
plant_trim_after() {  # <home> <crewmate> <seconds>
  local home=$1 id=$2 delay=$3
  (
    sleep "$delay"
    mkdir -p "$home/data/$id/trims"
    printf '1\tmanual\t%s\t138000\t-\tordered:lead-a\n' "$(date +%s)" >> "$home/data/$id/trims/index"
  ) &
  PLANT_PID=$!
}

# --- 1. a steer: the record, the doorbell, the note, the measure ------------
test_steer_records_rings_notes_and_measures() {
  local home body note idx
  make_home steer; home=$HOME_DIR
  run_lead "$home" -- steer --leader lead-a c1 $'rebase onto main first\nthen rerun the suite'
  expect_code 0 "$RC" "a steer to an own live crewmate succeeds: $ERR"
  [ -f "$home/state/c1.inbox/001.msg" ] || fail "the steer must be a durable inbox record (fm-send's inbox plane)"
  body=$(inbox_body "$home/state/c1.inbox/001.msg")
  [ "$body" = $'rebase onto main first\nthen rerun the suite' ] || fail "the record carries the text verbatim, got:"$'\n'"$body"
  assert_contains "$(cat "$home/send.log")" "Firstmate instruction waiting" "the doorbell rings the crewmate"
  case "$(cat "$home/send.log")" in *"rebase onto main"*) fail "the text is never typed into the pane" ;; esac
  note=$(grep '^note: ' "$home/state/lead-a.status" 2>/dev/null || true)
  [ "$note" = 'note: steered c1 (43 chars, 2 lines): rebase onto main first' ] \
    || fail "the leader's status gets one note line with the first line of the steer, got: '$note'"
  [ "$(grep -c . "$home/state/lead-a.status")" -eq 1 ] || fail "exactly one status line for one steer"
  [ ! -e "$home/state/c1.status" ] || fail "nothing is written to the crewmate's status for a plain steer"
  idx="$home/data/lead-a/steers/index"
  [ -f "$idx" ] || fail "the steer is measured in $idx"
  case "$(cut -f2- "$idx")" in
    $'c1\t43\t2\t-') ;;
    *) fail "the index line is <epoch> <crewmate> <chars> <lines> <key|->, got:"$'\n'"$(cat "$idx")" ;;
  esac
  case "$(cut -f1 "$idx")" in ''|*[!0-9]*) fail "the index line starts with the epoch" ;; esac
  case "$ERR" in *1,200*|*1200*) fail "a 43-character steer draws no size warning: $ERR" ;; esac
  pass "steer: durable record + doorbell through fm-send, one note line on the leader's status, one measured index line"
}

# --- 2. a steer that answers a door closes it --------------------------------
test_steer_resolve_key_closes_the_door() {
  local home
  make_home door; home=$HOME_DIR
  printf 'blocked: [key=stuck] the suite loops on the same failure\n' > "$home/state/c1.status"
  run_lead "$home" -- steer --leader lead-a c1 --resolve-key stuck "drop the retry loop; assert once and read the log"
  expect_code 0 "$RC" "an answering steer succeeds: $ERR"
  [ -f "$home/state/c1.inbox/001.msg" ] || fail "the answer is a durable inbox record"
  assert_contains "$(cat "$home/state/c1.status")" 'resolved [key=stuck]: answered:' \
    "fm-send closes the door at answer time (the resolved line on the crewmate's status)"
  assert_contains "$(cat "$home/state/lead-a.status")" 'note: steered c1 (' "the leader's note is written for an answer too"
  assert_contains "$(cat "$home/state/lead-a.status")" 'drop the retry loop' "the note carries the first line"
  [ "$(cut -f5 "$home/data/lead-a/steers/index")" = stuck ] || fail "the index records the key the steer answered"
  pass "steer --resolve-key: the door closes through fm-send and the measure records the key"
}

# --- 3. refusals: not my crewmate, no such crewmate, dead, gone, no leader ---
test_steer_refuses_outside_the_chain_and_the_dead() {
  local home
  make_home refuse; home=$HOME_DIR
  run_lead "$home" -- steer --leader lead-a c2 "hello"
  [ "$RC" -ne 0 ] || fail "a crewmate led by another leader must be refused"
  assert_contains "$ERR" "c2 is not led by lead-a" "the refusal names the chain"
  assert_contains "$ERR" "leader=lead-b" "the refusal names who leads it"
  [ ! -d "$home/state/c2.inbox" ] || fail "nothing is sent to a foreign crewmate"
  [ ! -e "$home/state/lead-a.status" ] || fail "a refused steer leaves no note"
  [ ! -e "$home/data/lead-a/steers/index" ] || fail "a refused steer is not measured"
  run_lead "$home" -- steer --leader lead-a ghost "hello"
  [ "$RC" -ne 0 ] || fail "an unrecorded crewmate must be refused"
  assert_contains "$ERR" "no task record for ghost" "the refusal names the missing record"
  run_lead "$home" FM_FAKE_SHELL_WINDOWS=fm-c3 -- steer --leader lead-a c3 "hello"
  [ "$RC" -ne 0 ] || fail "a crewmate whose agent died to its shell must be refused"
  assert_contains "$ERR" "c3 is not alive (endpoint dead)" "the refusal says dead"
  assert_contains "$ERR" "First Mate" "lifecycle is First Mate's: the refusal points there"
  [ ! -d "$home/state/c3.inbox" ] || fail "nothing is sent to a dead crewmate"
  run_lead "$home" FM_FAKE_GONE_WINDOWS=fm-c3 -- steer --leader lead-a c3 "hello"
  [ "$RC" -ne 0 ] || fail "a crewmate whose window is gone must be refused"
  assert_contains "$ERR" "c3 is not alive" "a gone window is dead too"
  run_lead "$home" -- steer --leader nobody c1 "hello"
  [ "$RC" -ne 0 ] || fail "a leader with no record must be refused"
  assert_contains "$ERR" "no task record for nobody" "the refusal names the leader's missing record"
  run_lead "$home" -- steer --leader lead-a c1
  [ "$RC" -ne 0 ] || fail "a steer needs text"
  assert_contains "$ERR" "text" "the refusal asks for the text"
  run_lead "$home" -- steer c1 "hello"
  [ "$RC" -ne 0 ] || fail "--leader is required"
  [ ! -e "$home/state/lead-a.status" ] || fail "no refusal leaves a note:"$'\n'"$(cat "$home/state/lead-a.status")"
  pass "steer refuses a foreign, unrecorded, dead or gone crewmate and a leaderless call, sending and noting nothing"
}

# --- 4. size is measured and warned, never refused ----------------------------
test_long_steer_is_warned_never_refused() {
  local home long
  make_home long; home=$HOME_DIR
  long=$(printf 'x%.0s' $(seq 1 1300))
  run_lead "$home" -- steer --leader lead-a c1 "$long"
  expect_code 0 "$RC" "a long steer is still sent: $ERR"
  [ -f "$home/state/c1.inbox/001.msg" ] || fail "the long steer is recorded"
  assert_contains "$ERR" "1300 characters" "the warning states the size"
  assert_contains "$ERR" "over 1,200" "the warning names the line"
  assert_contains "$ERR" "sent anyway" "measured, never refused"
  [ "$(cut -f3 "$home/data/lead-a/steers/index")" = 1300 ] || fail "the measure records 1300 chars"
  assert_contains "$(cat "$home/state/lead-a.status")" 'note: steered c1 (1300 chars, 1 lines): xxxxx' "the note keeps the size"
  [ "${#OUT}" -eq 0 ] || fail "steer prints nothing on stdout on success, got: $OUT"
  pass "a 1,300-character steer is sent, measured and warned about, never refused"
}

# --- 5. trim: the order is recorded before /compact is typed ------------------
test_trim_orders_then_types_compact() {
  local home idx
  make_home trim; home=$HOME_DIR
  plant_trim_after "$home" c1 1
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=30 -- trim --leader lead-a c1 the failing test and nothing else
  wait "$PLANT_PID" 2>/dev/null || true
  expect_code 0 "$RC" "a trim order to an own live crewmate succeeds: $ERR"
  assert_contains "$(cat "$home/send.log")" "/compact the failing test and nothing else" "the order is typed through fm-send's typed plane"
  case "$(inbox_body "$home/state/c1.inbox/001.msg" 2>/dev/null)" in
    /compact*) fail "a /compact is never an inbox record (the harness's parser must see it)" ;;
  esac
  idx="$home/data/c1/trims/index"
  [ -f "$idx" ] || fail "the order is recorded in the crewmate's trims index"
  case "$(sed -n '1p' "$idx" | cut -f1,3,4)" in
    $'ordered\tlead-a\tthe failing test and nothing else') ;;
    *) fail "the index gets 'ordered <epoch> <leader> <focus>', got:"$'\n'"$(cat "$idx")" ;;
  esac
  assert_contains "$(cat "$home/state/lead-a.status")" 'note: ordered a trim of c1: the failing test and nothing else' "the leader's status notes the order"
  # No focus: a bare /compact and a '-' focus.
  plant_trim_after "$home" c1 1
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=30 -- trim --leader lead-a c1
  wait "$PLANT_PID" 2>/dev/null || true
  expect_code 0 "$RC" "a bare trim order succeeds: $ERR"
  [ "$(grep -c '^/compact$' "$home/send.log")" -eq 1 ] || fail "without a focus the order is a bare /compact:"$'\n'"$(cat "$home/send.log")"
  [ "$(sed -n '3p' "$idx" | cut -f1,4)" = $'ordered\t-' ] || fail "a bare order records focus '-', got:"$'\n'"$(cat "$idx")"
  pass "trim: the ordered line lands in the trims index, then /compact <focus> is typed; the leader's status notes it"
}

# --- 6. trim finishes the loop: the continue-steer after the crewmate trims ---
test_trim_continues_the_crewmate_once_it_has_trimmed() {
  local home rec body idx
  make_home trimwait; home=$HOME_DIR
  plant_trim_after "$home" c1 2
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=30 -- trim --leader lead-a c1 the failing test
  wait "$PLANT_PID" 2>/dev/null || true
  expect_code 0 "$RC" "a trim the crewmate answers succeeds: $ERR"
  rec="$home/state/c1.inbox/001.msg"
  [ -f "$rec" ] || fail "the continue-steer is a durable inbox record; inbox:"$'\n'"$(ls "$home/state/c1.inbox" 2>/dev/null)"
  body=$(inbox_body "$rec")
  [ "$body" = 'trim done - continue: the failing test' ] || fail "the continue-steer names the focus, got: '$body'"
  assert_contains "$(record_header "$rec")" "mark=from-leader:lead-a" "the continue-steer carries the leader's mark (the led channel)"
  assert_contains "$(cat "$home/send.log")" "Firstmate instruction waiting" "the inbox doorbell rings the crewmate"
  idx="$home/data/c1/trims/index"
  [ "$(cut -f1 "$idx" | tr '\n' ' ')" = 'ordered 1 ' ] || fail "the continue follows the crewmate's own ledger line, got:"$'\n'"$(cat "$idx")"
  # Without a focus the continue points at the task card.
  make_home trimwait-bare; home=$HOME_DIR
  plant_trim_after "$home" c1 1
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=30 -- trim --leader lead-a c1
  wait "$PLANT_PID" 2>/dev/null || true
  expect_code 0 "$RC" "a bare trim the crewmate answers succeeds: $ERR"
  [ "$(inbox_body "$home/state/c1.inbox/001.msg")" = 'trim done - continue with your task card' ] \
    || fail "without a focus the continue points at the task card, got: '$(inbox_body "$home/state/c1.inbox/001.msg")'"
  pass "trim waits for the crewmate's own trim line and then sends one continue-steer through the inbox doorbell, marked from-leader, naming the focus or the task card"
}

# --- 7. a trim that never arrives is said out loud, never waited on forever ---
test_trim_that_never_arrives_is_reported_and_bounded() {
  local home
  make_home trimtimeout; home=$HOME_DIR
  # An earlier trim of the same crewmate is not an answer to this order.
  mkdir -p "$home/data/c1/trims"
  printf '1\tmanual\t%s\t150000\t-\n' "$(( $(date +%s) + 5 ))" > "$home/data/c1/trims/index"
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=2 FM_LEAD_TRIM_POLL_SECS=1 -- trim --leader lead-a c1 the failing test
  expect_code 3 "$RC" "an unconfirmed trim exits 3, got $RC: $ERR"
  [ ! -d "$home/state/c1.inbox" ] || fail "no continue-steer is sent when the trim never arrived"
  assert_contains "$ERR" "the trim of c1 was ordered at" "the message names the crewmate and when"
  assert_contains "$ERR" "within 2s" "and the bound it waited"
  assert_contains "$ERR" "the order stands in the ledger" "the order is left alone"
  assert_contains "$ERR" "bin/fm-crew-vitals.sh c1" "and the leader is told how to look"
  assert_contains "$(cat "$home/state/lead-a.status")" 'note: trim of c1 unconfirmed after 2s' "the leader's status carries the note"
  [ "$(cut -f1 "$home/data/c1/trims/index" | tr '\n' ' ')" = '1 ordered ' ] \
    || fail "the ledger keeps the earlier trim and the order, and adds nothing else, got:"$'\n'"$(cat "$home/data/c1/trims/index")"
  pass "a trim order the crewmate never answers - an earlier trim of its own is no answer - is bounded by FM_LEAD_TRIM_WAIT_SECS, exits 3, sends no continue, and tells the leader to read the pane and steer by hand"
}

test_trim_failed_send_is_recorded() {
  local home idx
  make_home trimfail; home=$HOME_DIR
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=2 FM_FAKE_TMUX_SEND_FAIL=1 -- trim --leader lead-a c1 focus
  [ "$RC" -ne 0 ] || fail "a trim whose /compact did not reach the pane must fail"
  idx="$home/data/c1/trims/index"
  [ "$(cut -f1 "$idx" | tr '\n' ' ')" = 'ordered order-failed ' ] || fail "an order that did not reach is marked order-failed after its ordered line, got:"$'\n'"$(cat "$idx")"
  assert_contains "$ERR" "did not reach" "the failure is named"
  [ ! -e "$home/state/lead-a.status" ] || fail "no note for an order that did not reach"
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=2 -- trim --leader lead-a c2 focus
  [ "$RC" -ne 0 ] || fail "a foreign crewmate cannot be trimmed"
  assert_contains "$ERR" "c2 is not led by lead-a" "trim refuses outside the chain"
  [ ! -e "$home/data/c2/trims/index" ] || fail "a refused trim records nothing"
  run_lead "$home" FM_LEAD_TRIM_WAIT_SECS=2 FM_FAKE_SHELL_WINDOWS=fm-c3 -- trim --leader lead-a c3 focus
  [ "$RC" -ne 0 ] || fail "a dead crewmate cannot be trimmed"
  [ ! -e "$home/data/c3/trims/index" ] || fail "a refused trim records nothing"
  pass "trim: a /compact that did not reach is recorded as order-failed and fails; foreign and dead crewmates are refused before any record"
}

test_steer_records_rings_notes_and_measures
test_steer_resolve_key_closes_the_door
test_steer_refuses_outside_the_chain_and_the_dead
test_long_steer_is_warned_never_refused
test_trim_orders_then_types_compact
test_trim_continues_the_crewmate_once_it_has_trimmed
test_trim_that_never_arrives_is_reported_and_bounded
test_trim_failed_send_is_recorded
