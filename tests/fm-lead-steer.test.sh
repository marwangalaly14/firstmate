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
# and then returns, without waiting for the compaction: the carry-on nudge
# after that trim is the crewmate's own PostCompact hook's to send
# (tests/fm-trim-event.test.sh), so no leader command has to outlive a
# compaction. These tests drive the real fm-lead over the real fm-send and a
# stubbed tmux whose inventory and pane command decide who is alive.
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
  run_lead "$home" -- trim --leader lead-a c1 the failing test and nothing else
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
  run_lead "$home" -- trim --leader lead-a c1
  expect_code 0 "$RC" "a bare trim order succeeds: $ERR"
  [ "$(grep -c '^/compact$' "$home/send.log")" -eq 1 ] || fail "without a focus the order is a bare /compact:"$'\n'"$(cat "$home/send.log")"
  [ "$(sed -n '2p' "$idx" | cut -f1,4)" = $'ordered\t-' ] || fail "a bare order records focus '-', got:"$'\n'"$(cat "$idx")"
  pass "trim: the ordered line lands in the trims index, then /compact <focus> is typed; the leader's status notes it"
}

# --- 6. trim does not wait: the nudge is the crewmate's own hook's --------
test_trim_returns_without_waiting_and_sends_no_continue() {
  local home idx before after
  make_home trimnowait; home=$HOME_DIR
  before=$(date +%s)
  run_lead "$home" -- trim --leader lead-a c1 the failing test
  after=$(date +%s)
  expect_code 0 "$RC" "a trim order returns 0 with no compaction anywhere: $ERR"
  [ "$((after - before))" -lt 10 ] || fail "trim returns promptly, it does not wait for a compaction; took $((after - before))s"
  idx="$home/data/c1/trims/index"
  [ "$(cut -f1 "$idx" | tr '\n' ' ')" = 'ordered ' ] || fail "the ledger holds the order and nothing else, got:"$'\n'"$(cat "$idx")"
  assert_contains "$(cat "$home/send.log")" "/compact the failing test" "the order is typed through fm-send's typed plane"
  [ ! -d "$home/state/c1.inbox" ] || fail "trim sends no continue-steer itself; the crewmate's own trim hook does:"$'\n'"$(ls "$home/state/c1.inbox")"
  assert_contains "$(cat "$home/state/lead-a.status")" 'note: ordered a trim of c1: the failing test' "the leader's status notes the order"
  case "$(cat "$home/state/lead-a.status")" in *unconfirmed*) fail "nothing is unconfirmed: the command never waited" ;; esac
  pass "trim marks the order, types /compact and returns at once: no wait, no continue-steer of its own, and no unconfirmed note"
}

test_trim_failed_send_is_recorded() {
  local home idx
  make_home trimfail; home=$HOME_DIR
  run_lead "$home" FM_FAKE_TMUX_SEND_FAIL=1 -- trim --leader lead-a c1 focus
  [ "$RC" -ne 0 ] || fail "a trim whose /compact did not reach the pane must fail"
  idx="$home/data/c1/trims/index"
  [ "$(cut -f1 "$idx" | tr '\n' ' ')" = 'ordered order-failed ' ] || fail "an order that did not reach is marked order-failed after its ordered line, got:"$'\n'"$(cat "$idx")"
  assert_contains "$ERR" "did not reach" "the failure is named"
  [ ! -e "$home/state/lead-a.status" ] || fail "no note for an order that did not reach"
  run_lead "$home" -- trim --leader lead-a c2 focus
  [ "$RC" -ne 0 ] || fail "a foreign crewmate cannot be trimmed"
  assert_contains "$ERR" "c2 is not led by lead-a" "trim refuses outside the chain"
  [ ! -e "$home/data/c2/trims/index" ] || fail "a refused trim records nothing"
  run_lead "$home" FM_FAKE_SHELL_WINDOWS=fm-c3 -- trim --leader lead-a c3 focus
  [ "$RC" -ne 0 ] || fail "a dead crewmate cannot be trimmed"
  [ ! -e "$home/data/c3/trims/index" ] || fail "a refused trim records nothing"
  pass "trim: a /compact that did not reach is recorded as order-failed and fails; foreign and dead crewmates are refused before any record"
}

test_steer_records_rings_notes_and_measures
test_steer_resolve_key_closes_the_door
test_steer_refuses_outside_the_chain_and_the_dead
test_long_steer_is_warned_never_refused
test_trim_orders_then_types_compact
test_trim_returns_without_waiting_and_sends_no_continue
test_trim_failed_send_is_recorded
