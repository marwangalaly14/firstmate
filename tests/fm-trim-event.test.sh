#!/usr/bin/env bash
# tests/fm-trim-event.test.sh - every trim recorded; the second automatic one
# reaches the leader.
#
# bin/fm-trim-event.sh runs from a claude PostCompact hook. It writes one
# record per trim under data/<id>/trims/ (the head before the trim read from
# the transcript, the count of automatic trims, who was told, the harness's
# summary verbatim) and appends the ledger line. From the second automatic
# trim on it puts one line into the leader's steering inbox through
# bin/fm-send.sh when state/<id>.meta names a leader whose endpoint is alive,
# and otherwise queues one `signal` wake for First Mate. A manual trim rings
# nobody, with one exception that is the point of the hook: a manual trim a
# leader ordered (a pending `ordered` line in the ledger) sends the crewmate
# its own carry-on nudge, so nothing has to wait for the compaction to end.
# An unreadable payload does nothing. The spawn installs the hook for every
# claude crewmate and leader, never for codex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-compact-lib.sh"

HOOK="$ROOT/bin/fm-trim-event.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-trim-event)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# --- transcript rows, as the harness writes them ------------------------------
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
row_assistant() {  # <epoch> <msg-id> <in> <cc> <cr> <out> [sidechain]
  printf '{"type":"assistant","uuid":"u-%s","isSidechain":%s,"timestamp":"%s","message":{"id":"%s","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$RANDOM" "${7:-false}" "$(iso "$1")" "$2" "$3" "$4" "$5" "$6"
}
row_boundary() {  # <epoch> <trigger> <pre> <post>
  printf '{"type":"system","subtype":"compact_boundary","uuid":"b-%s","timestamp":"%s","compactMetadata":{"trigger":"%s","preTokens":%s,"postTokens":%s}}\n' "$RANDOM" "$(iso "$1")" "$2" "$3" "$4"
}
row_summary() { printf '{"type":"user","uuid":"s-%s","timestamp":"%s","isCompactSummary":true,"message":{"role":"user","content":"summary"}}\n' "$RANDOM" "$(iso "$1")"; }
row_user() { printf '{"type":"user","uuid":"x-%s","timestamp":"%s","message":{"role":"user","content":"go"}}\n' "$RANDOM" "$(iso "$1")"; }

NOW=1757100000
# The transcript at the moment of a trim: the last request's usage is the
# head (138000), an earlier bigger request and a sidechain row do not count.
write_transcript() {  # <path>
  {
    row_user $((NOW - 900))
    row_assistant $((NOW - 800)) m1 150000 0 0 1000
    row_assistant $((NOW - 700)) m2 1000 2000 130000 5000
    row_assistant $((NOW - 600)) sub 160000 0 0 100 true
  } > "$1"
}

payload() {  # <trigger> <transcript> [summary] [extra json]
  printf '{"hook_event_name":"PostCompact","trigger":"%s","session_id":"s-77","transcript_path":"%s","cwd":"/w","compact_summary":"%s"%s}' \
    "$1" "$2" "${3:-Kept: the failing test.\\nDropped: tool output.}" "${4:-}"
}

# --- a home: state, data, a task, a leader, a fake tmux ----------------------
# The fake tmux serves both readers: fm-lead-lib's liveness read (the exact
# window inventory from `list-windows -t <session>`, every window a record in
# FM_FAKE_STATE names unless FM_FAKE_DEAD_WINDOWS lists it as gone, then the
# `display-message -t <session>:<window>` presence read for a foreground it
# cannot classify) and fm-send's doorbell (send-keys -l logged to FM_SEND_LOG,
# composer empty).
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
is_dead() {
  local dead
  for dead in ${FM_FAKE_DEAD_WINDOWS:-}; do
    [ "$1" = "$dead" ] && return 0
  done
  return 1
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    for meta in "${FM_FAKE_STATE:-/nonexistent}"/*.meta; do
      [ -f "$meta" ] || continue
      w=$(sed -n 's/^window=[^:]*://p' "$meta" | head -1)
      [ -n "$w" ] || continue
      is_dead "$w" || printf '%s\n' "$w"
    done
    exit 0 ;;
  display-message)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-t" ]; then
        is_dead "${a#*:}" && exit 1
      fi
      prev=$a
    done
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  send-keys)
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
  fm_fake_exit0 "$fakebin" treehouse codex
  printf '%s\n' "$fakebin"
}

make_home() {  # <name>: sets HOME_DIR and FAKEBIN
  HOME_DIR="$TMP_ROOT/$1/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
  FAKEBIN=$(make_fakebin "$TMP_ROOT/$1")
}

write_task() {  # <home> <id> [meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "project=/p" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
  mkdir -p "$home/data/$id"
}

run_hook() {  # <home> <id> <payload> [env...]: sets RC; stdout in <home>/hook.out
  local home=$1 id=$2 body=$3
  shift 3
  local envs=()
  while [ $# -gt 0 ]; do envs+=("$1"); shift; done
  printf '%s' "$body" | env PATH="$FAKEBIN:$PATH" FM_SEND_LOG="$home/send.log" FM_FAKE_STATE="$home/state" \
    ${envs[@]+"${envs[@]}"} "$HOOK" "$home" "$id" >"$home/hook.out" 2>"$home/hook.err"
  RC=$?
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

assert_quiet() {  # <home> <label>: nothing on stdout, exit 0
  [ "$RC" -eq 0 ] || fail "$2: the hook must exit 0 (got $RC)"$'\n'"$(cat "$1/hook.err")"
  [ ! -s "$1/hook.out" ] || fail "$2: the hook prints nothing on stdout (the harness would show it):"$'\n'"$(cat "$1/hook.out")"
}

# --- 1. the record ----------------------------------------------------------
test_records_every_trim() {
  local home t rec
  make_home record; home=$HOME_DIR
  write_task "$home" c1 "trim_mark=$FM_COMPACT_MARK"
  t="$home/c1.jsonl"
  write_transcript "$t"
  run_hook "$home" c1 "$(payload auto "$t")"
  assert_quiet "$home" "first trim"
  rec="$home/data/c1/trims/1.md"
  [ -f "$rec" ] || fail "the first trim must write $rec"
  assert_contains "$(cat "$rec")" "# Trim 1: c1" "the record is numbered and named"
  assert_contains "$(cat "$rec")" "- trigger: auto" "the record carries the trigger"
  assert_contains "$(cat "$rec")" "- session: s-77" "the record carries the session"
  assert_contains "$(cat "$rec")" "- transcript: $t" "the record carries the transcript"
  assert_contains "$(cat "$rec")" "- head before the trim: 138K (138000 tokens" \
    "the head is the last request's usage, not the biggest and not a sidechain's"
  assert_contains "$(cat "$rec")" "- trim line: 140K" "a story crewmate's record names the line"
  assert_contains "$(cat "$rec")" "- automatic trims so far: 1" "the first automatic trim counts one"
  assert_contains "$(cat "$rec")" "- told: nobody (first automatic trim)" "the first trim tells nobody"
  assert_contains "$(cat "$rec")" $'## Summary\n\nKept: the failing test.\nDropped: tool output.' \
    "the harness's summary is kept verbatim, newlines included"
  [ "$(cut -f1,2,4,5 "$home/data/c1/trims/index")" = $'1\tauto\t138000\t-' ] \
    || fail "the ledger line must read '1 auto <epoch> 138000 -', got:"$'\n'"$(cat "$home/data/c1/trims/index")"
  [ ! -e "$home/state/.wake-queue" ] || fail "the first automatic trim queues no wake:"$'\n'"$(cat "$home/state/.wake-queue")"
  [ ! -e "$home/send.log" ] || fail "the first automatic trim rings nobody"
  # A task with no transcript to read still gets its record, with ? for the head.
  run_hook "$home" c1 "$(payload auto "$home/missing.jsonl" "Short.")"
  assert_quiet "$home" "no transcript"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- head before the trim: ? (no readable transcript)" \
    "an unreadable transcript reads as ?, never a guess"
  pass "every trim writes data/<id>/trims/<n>.md (trigger, session, transcript, head 138K from the last request, the line, the count, who was told, the summary verbatim) and one ledger line; nothing is printed and nobody is rung on the first"
}

# --- 2. the second automatic trim rings the leader ---------------------------
test_second_automatic_trim_rings_the_leader() {
  local home t rec body typed
  make_home leader; home=$HOME_DIR
  write_task "$home" lead-a "leads=1"
  write_task "$home" c1 "leader=lead-a" "trim_mark=$FM_COMPACT_MARK"
  t="$home/c1.jsonl"
  write_transcript "$t"
  run_hook "$home" c1 "$(payload auto "$t")"
  assert_quiet "$home" "first trim under a leader"
  [ ! -d "$home/state/lead-a.inbox" ] || fail "the first automatic trim must not reach the leader"
  run_hook "$home" c1 "$(payload auto "$t" "Second summary.")"
  assert_quiet "$home" "second trim under a leader"
  rec="$home/state/lead-a.inbox/001.msg"
  [ -f "$rec" ] || fail "the second automatic trim must land in the leader's steering inbox at $rec"
  body=$(inbox_body "$rec")
  [ "$body" = "trim event: c1 trimmed its context for the 2nd time (head 138K before it, line 140K) - steer or split the story; summary in $home/data/c1/trims/2.md" ] \
    || fail "the leader's line differs:"$'\n'"$body"
  typed=$(cat "$home/send.log" 2>/dev/null)
  assert_contains "$typed" "Firstmate instruction waiting: list $home/state/lead-a.inbox/*.msg" \
    "the leader's doorbell rings (fm-send's constant line)"
  [ ! -e "$home/state/.wake-queue" ] || fail "with a live leader nothing reaches First Mate's wake queue:"$'\n'"$(cat "$home/state/.wake-queue")"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- told: leader lead-a (steering inbox)" "the record says who was told"
  [ "$(sed -n '2p' "$home/data/c1/trims/index" | cut -f1,2,4,5)" = $'2\tauto\t138000\tleader:lead-a' ] \
    || fail "the second ledger line names the leader, got:"$'\n'"$(cat "$home/data/c1/trims/index")"
  # Every automatic trim after the second rings again: the third is the 3rd time.
  run_hook "$home" c1 "$(payload auto "$t" "Third.")"
  assert_quiet "$home" "third trim under a leader"
  body=$(inbox_body "$home/state/lead-a.inbox/002.msg")
  assert_contains "$body" "c1 trimmed its context for the 3rd time" "the third automatic trim rings the leader again"
  pass "the second automatic trim puts one line into the leader's steering inbox and rings its doorbell, the wake queue stays empty, the record and ledger name the leader, and the third rings again"
}

# --- 3. a manual trim rings nobody -------------------------------------------
test_manual_trim_records_and_rings_nobody() {
  local home t
  make_home manual; home=$HOME_DIR
  write_task "$home" lead-a "leads=1"
  write_task "$home" c1 "leader=lead-a"
  t="$home/c1.jsonl"
  write_transcript "$t"
  run_hook "$home" c1 "$(payload auto "$t")"
  run_hook "$home" c1 "$(payload auto "$t")"
  rm -rf "$home/state/lead-a.inbox" "$home/send.log"
  run_hook "$home" c1 "$(payload manual "$t" "Typed /compact.")"
  assert_quiet "$home" "manual trim"
  [ -f "$home/data/c1/trims/3.md" ] || fail "a manual trim is still recorded"
  assert_contains "$(cat "$home/data/c1/trims/3.md")" "- trigger: manual" "the record says manual"
  assert_contains "$(cat "$home/data/c1/trims/3.md")" "- automatic trims so far: 2" "a manual trim does not count as automatic"
  assert_contains "$(cat "$home/data/c1/trims/3.md")" "- told: nobody (manual trim)" "a manual trim tells nobody"
  [ ! -d "$home/state/lead-a.inbox" ] || fail "a manual trim must not reach the leader"
  [ ! -e "$home/send.log" ] || fail "a manual trim rings no doorbell"
  [ ! -e "$home/state/.wake-queue" ] || fail "a manual trim queues no wake"
  [ "$(sed -n '3p' "$home/data/c1/trims/index" | cut -f1,2,5)" = $'3\tmanual\t-' ] || fail "the ledger says manual and -"
  [ ! -d "$home/state/c1.inbox" ] || fail "a crewmate that trimmed on its own is nudged by nobody:"$'\n'"$(ls "$home/state/c1.inbox")"
  # A leader's own record has no trim line and gets the same treatment.
  write_transcript "$home/lead.jsonl"
  run_hook "$home" lead-a "$(payload manual "$home/lead.jsonl")"
  assert_quiet "$home" "leader manual trim"
  case "$(cat "$home/data/lead-a/trims/1.md")" in
    *"trim line"*) fail "a leader has no trim line to name" ;;
  esac
  pass "a manual trim nobody ordered is recorded (count unchanged, told nobody), rings neither the leader nor First Mate and nudges the crewmate not at all; a leader's record names no trim line"
}

# --- 3b. a manual trim after the leader's order is the leader's ---------------
test_manual_trim_after_an_order_is_attributed() {
  local home t idx lead_rc msgs f
  make_home ordered; home=$HOME_DIR
  write_task "$home" lead-a "leads=1"
  write_task "$home" c1 "leader=lead-a"
  t="$home/c1.jsonl"
  write_transcript "$t"
  run_hook "$home" c1 "$(payload auto "$t")"
  idx="$home/data/c1/trims/index"
  # The real order: fm-lead trim writes the ordered line, types /compact and
  # RETURNS. By the time the hook below runs, that command is long gone - the
  # shape this case exists for: nothing is waiting anywhere for the trim, and
  # the carry-on nudge must still land.
  lead_rc=0
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_SEND_LOG="$home/send.log" FM_FAKE_STATE="$home/state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-lead.sh" trim --leader lead-a c1 the failing test >/dev/null 2>"$home/lead.err" || lead_rc=$?
  [ "$lead_rc" -eq 0 ] || fail "the leader's trim order lands and returns without waiting, got $lead_rc:"$'\n'"$(cat "$home/lead.err")"
  [ ! -d "$home/state/c1.inbox" ] || fail "fm-lead sends no nudge itself; the hook does"
  assert_contains "$(cat "$home/send.log")" "/compact the failing test" "the order is typed"
  [ "$(sed -n '2p' "$idx" | cut -f1,3,4)" = $'ordered\tlead-a\tthe failing test' ] || fail "the order line follows the first trim:"$'\n'"$(cat "$idx")"
  run_hook "$home" c1 "$(payload manual "$t" "Focused on the failing test.")"
  assert_quiet "$home" "ordered manual trim"
  [ -f "$home/data/c1/trims/2.md" ] || fail "the ordered trim is trim 2 (order lines are not trims)"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- ordered by: leader lead-a (order at epoch " "the record names the leader's order"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "focus: the failing test)" "the record carries the focus"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- automatic trims so far: 1" "an ordered trim is manual: not counted"
  [ ! -d "$home/state/lead-a.inbox" ] || fail "an ordered trim does not ring the leader"
  # The carry-on nudge: the crewmate's own inbox, from the leader that ordered it.
  [ -f "$home/state/c1.inbox/001.msg" ] || fail "the carry-on nudge is a durable record in the crewmate's own inbox; inbox:"$'\n'"$(ls "$home/state/c1.inbox" 2>/dev/null)"
  [ "$(inbox_body "$home/state/c1.inbox/001.msg")" = 'trim done - continue: the failing test' ] \
    || fail "the nudge names the order's focus, got: '$(inbox_body "$home/state/c1.inbox/001.msg")'"
  assert_contains "$(sed '/^--$/,$d' "$home/state/c1.inbox/001.msg")" "mark=from-leader:lead-a" "the nudge carries the ordering leader's mark (the led channel)"
  assert_contains "$(cat "$home/send.log")" "Firstmate instruction waiting" "the inbox doorbell rings the crewmate"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- told: c1 itself (carry-on steer from leader lead-a)" "the record names the nudge"
  [ "$(sed -n '3p' "$idx" | cut -f1,2,5,6)" = $'2\tmanual\t-\tordered:lead-a' ] || fail "the ledger line ends in ordered:<leader>:"$'\n'"$(cat "$idx")"
  # The line that spends the order is written BEFORE the nudge is attempted.
  [ "$(cut -f1 "$idx" | tr '\n' ' ')" = '1 ordered 2 ' ] || fail "the ledger holds the trim line and no failure row:"$'\n'"$(cat "$idx")"
  # A manual trim with no pending order (the order was consumed) is nobody's,
  # and is nudged by nobody: the order is one-shot.
  run_hook "$home" c1 "$(payload manual "$t" "Typed by hand.")"
  assert_contains "$(cat "$home/data/c1/trims/3.md")" "- ordered by: nobody in the ledger" "a manual trim without an order is not attributed"
  assert_contains "$(cat "$home/data/c1/trims/3.md")" "- told: nobody (manual trim)" "and tells nobody"
  [ "$(sed -n '4p' "$idx" | cut -f5,6)" = $'-' ] || fail "no nudge and no sixth field without an order:"$'\n'"$(cat "$idx")"
  msgs=0
  for f in "$home"/state/c1.inbox/*.msg; do [ -f "$f" ] && msgs=$((msgs + 1)); done
  [ "$msgs" -eq 1 ] || fail "the consumed order nudges nothing a second time, got $msgs records"
  # An order that did not reach the pane (order-failed) attributes nothing.
  printf 'ordered\t%s\tlead-a\tlate\norder-failed\t%s\n' "$(date +%s)" "$(date +%s)" >> "$idx"
  run_hook "$home" c1 "$(payload manual "$t" "Typed by hand again.")"
  assert_contains "$(cat "$home/data/c1/trims/4.md")" "- ordered by: nobody in the ledger" "a failed order attributes nothing"
  # An automatic trim never carries an order line, and the count still ignores order lines.
  printf 'ordered\t%s\tlead-a\tpending\n' "$(date +%s)" >> "$idx"
  rm -rf "$home/state/lead-a.inbox"
  run_hook "$home" c1 "$(payload auto "$t")"
  case "$(cat "$home/data/c1/trims/5.md")" in *"ordered by"*) fail "an automatic trim has no ordered-by line" ;; esac
  assert_contains "$(cat "$home/data/c1/trims/5.md")" "- automatic trims so far: 2" "order lines are never counted as trims"
  [ -f "$home/state/lead-a.inbox/001.msg" ] || fail "the second automatic trim still rings the leader"
  pass "a manual trim after fm-lead's order is the leader's (record and ledger say so, not counted, rings the leader not at all) and carries the crewmate its carry-on nudge even though the ordering command is long gone; a hand-typed or failed-order trim is nobody's and is nudged by nobody; order lines never count"
}

# --- 3d. an automatic trim before the turn boundary spends no order ----------
# The double-trim shape the ledger has to survive: the leader orders a trim
# while the crewmate is mid-turn, so the typed /compact is queued behind the
# turn, and the crewmate crosses the harness's own auto-trim window first. That
# automatic trim is not the thing the leader ordered, so it must answer nothing
# and leave the order standing for the queued /compact to spend.
pending_order() {  # <trims-index-file>
  bash -c '. "$1"; . "$2"; fm_lead_pending_order "$3"' _ \
    "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-lead-lib.sh" "$1"
}

test_an_automatic_trim_before_the_boundary_leaves_the_order() {
  local home t idx msgs f pending
  make_home autofirst; home=$HOME_DIR
  write_task "$home" lead-a "leads=1"
  write_task "$home" c1 "leader=lead-a"
  t="$home/c1.jsonl"
  write_transcript "$t"
  idx="$home/data/c1/trims/index"
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_SEND_LOG="$home/send.log" FM_FAKE_STATE="$home/state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-lead.sh" trim --leader lead-a c1 keep the spec >/dev/null 2>"$home/lead.err" \
    || fail "the leader's trim order must land:"$'\n'"$(cat "$home/lead.err")"
  # The automatic trim that beats the queued /compact to the crewmate.
  run_hook "$home" c1 "$(payload auto "$t" "Auto-compacted.")"
  assert_quiet "$home" "automatic trim before the boundary"
  case "$(cat "$home/data/c1/trims/1.md")" in
    *"ordered by"*) fail "an automatic trim is never attributed to the order:"$'\n'"$(cat "$home/data/c1/trims/1.md")" ;;
  esac
  [ ! -d "$home/state/c1.inbox" ] \
    || fail "an automatic trim carries no nudge; c1's inbox holds $(ls "$home/state/c1.inbox" 2>/dev/null)"
  pending=$(pending_order "$idx") \
    || fail "the leader's order must still stand after an automatic trim:"$'\n'"$(cat "$idx")"
  [ "$(printf '%s' "$pending" | cut -f2,3)" = $'lead-a\tkeep the spec' ] \
    || fail "the standing order is still the leader's, with its focus, got: '$pending'"
  # The queued /compact finally runs: this is the trim the leader ordered.
  run_hook "$home" c1 "$(payload manual "$t" "Kept the spec.")"
  assert_quiet "$home" "the ordered manual trim"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- ordered by: leader lead-a (order at epoch " \
    "the manual trim that follows is the leader's"
  msgs=0
  for f in "$home"/state/c1.inbox/*.msg; do [ -f "$f" ] && msgs=$((msgs + 1)); done
  [ "$msgs" -eq 1 ] || fail "one order carries exactly one nudge, got $msgs"
  [ "$(inbox_body "$home/state/c1.inbox/001.msg")" = 'trim done - continue: keep the spec' ] \
    || fail "the nudge names the order's focus, got: '$(inbox_body "$home/state/c1.inbox/001.msg")'"
  [ ! -d "$home/state/lead-a.inbox" ] || fail "neither trim rings the leader: the automatic one is the first"
  # The ledger shows both trims, with only the manual one marked as the leader's.
  [ "$(sed -n '1p' "$idx" | cut -f1,3,4)" = $'ordered\tlead-a\tkeep the spec' ] \
    || fail "the order line stands first:"$'\n'"$(cat "$idx")"
  [ "$(sed -n '2p' "$idx" | cut -f1,2,6)" = $'1\tauto' ] \
    || fail "the automatic trim is recorded and marked for nobody:"$'\n'"$(cat "$idx")"
  [ "$(sed -n '3p' "$idx" | cut -f1,2,6)" = $'2\tmanual\tordered:lead-a' ] \
    || fail "the manual trim is recorded as the leader's:"$'\n'"$(cat "$idx")"
  # And the order is spent: nothing stands for a later trim to claim.
  pending_order "$idx" >/dev/null \
    && fail "the ordered manual trim spends the order:"$'\n'"$(cat "$idx")"
  pass "an automatic trim that lands before the queued /compact answers no order and nudges nobody; the ordered manual trim that follows is the leader's, carries exactly one nudge and spends the order"
}

# --- 3c. the order is spent before the nudge, whatever the send does ---------
# The one-shot guarantee cannot depend on the send: fm-send is the slow step
# and a PostCompact hook can be killed inside it. Here the send is made to
# fail outright, which is the same visible state as a hook killed mid-send.
test_a_failed_nudge_still_spends_the_order() {
  local home t idx msgs f
  make_home nudgefail; home=$HOME_DIR
  # An unwritable inbox is how a send is made to fail here; root ignores the
  # mode bits, so the case cannot be posed for root.
  [ "$(id -u)" -ne 0 ] || { pass "skipped as root: an unwritable inbox cannot fail a send"; return 0; }
  write_task "$home" lead-a "leads=1"
  write_task "$home" c1 "leader=lead-a"
  t="$home/c1.jsonl"
  write_transcript "$t"
  idx="$home/data/c1/trims/index"
  mkdir -p "$home/data/c1/trims"
  printf 'ordered\t%s\tlead-a\tthe failing test\n' "$(date +%s)" > "$idx"
  # The record IS the delivery, so an inbox it cannot be written into is a
  # send that failed outright - the same visible state as a hook killed inside
  # fm-send, which is the slow step.
  mkdir -p "$home/state/c1.inbox"
  chmod 500 "$home/state/c1.inbox"
  run_hook "$home" c1 "$(payload manual "$t" "Focused on the failing test.")"
  chmod 700 "$home/state/c1.inbox"
  assert_quiet "$home" "a nudge that did not record"
  [ "$(cut -f1 "$idx" | tr '\n' ' ')" = 'ordered 1 steer-failed ' ] \
    || fail "the trim line spends the order first, then the failure is recorded beside it:"$'\n'"$(cat "$idx")"
  [ "$(sed -n '3p' "$idx" | cut -f3)" = lead-a ] || fail "the steer-failed line names the leader:"$'\n'"$(cat "$idx")"
  assert_contains "$(cat "$home/data/c1/trims/1.md")" "- told: nobody (the carry-on steer from leader lead-a did not reach c1)" \
    "the trim record names the failure too"
  msgs=0
  for f in "$home"/state/c1.inbox/*.msg; do [ -f "$f" ] && msgs=$((msgs + 1)); done
  [ "$msgs" -eq 0 ] || fail "no record landed, got $msgs"
  # The point: the spent order can never nudge a later trim the crewmate typed.
  run_hook "$home" c1 "$(payload manual "$t" "Typed by hand.")"
  assert_quiet "$home" "a self-typed trim after a failed nudge"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- ordered by: nobody in the ledger" \
    "a trim the crewmate typed itself is nobody's, even after a nudge that failed"
  msgs=0
  for f in "$home"/state/c1.inbox/*.msg; do [ -f "$f" ] && msgs=$((msgs + 1)); done
  [ "$msgs" -eq 0 ] || fail "and it is nudged by nobody, got $msgs records"
  pass "the ledger line that spends a leader's order is written before the nudge is attempted: a nudge that never records leaves a steer-failed row, the record says so, the hook still exits 0 and prints nothing, and the next trim the crewmate types itself is nobody's and gets no steer"
}

# --- 4. no live leader: First Mate gets one signal wake -----------------------
test_without_a_live_leader_first_mate_is_signalled() {
  local home t q
  make_home firstmate; home=$HOME_DIR
  write_task "$home" lead-a "leads=1"
  write_task "$home" c1 "leader=lead-a"
  write_task "$home" c2
  write_task "$home" c3 "leader=lead-gone"
  t="$home/c.jsonl"
  write_transcript "$t"
  # A dead leader: the presence read fails.
  run_hook "$home" c1 "$(payload auto "$t")" FM_FAKE_DEAD_WINDOWS=fm-lead-a
  run_hook "$home" c1 "$(payload auto "$t")" FM_FAKE_DEAD_WINDOWS=fm-lead-a
  assert_quiet "$home" "dead leader"
  [ ! -d "$home/state/lead-a.inbox" ] || fail "a dead leader's inbox must not be written"
  q=$(cat "$home/state/.wake-queue" 2>/dev/null) || fail "a dead leader means one signal wake for First Mate"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 1 ] || fail "exactly one wake row, got:"$'\n'"$q"
  [ "$(cut -f3,4 "$home/state/.wake-queue")" = $'signal\ttrim:c1' ] || fail "the wake is a signal keyed trim:c1, got:"$'\n'"$q"
  assert_contains "$q" "c1 trimmed its context for the 2nd time (head 138K before it) - steer or split the story; summary in $home/data/c1/trims/2.md (leader lead-a dead)" \
    "the wake payload carries the line and why the leader was not told"
  assert_contains "$(cat "$home/data/c1/trims/2.md")" "- told: First Mate (signal wake; leader lead-a dead)" "the record says First Mate was told and why"
  [ "$(sed -n '2p' "$home/data/c1/trims/index" | cut -f5)" = firstmate ] || fail "the ledger says firstmate"
  # No leader at all.
  run_hook "$home" c2 "$(payload auto "$t")"
  run_hook "$home" c2 "$(payload auto "$t")"
  assert_quiet "$home" "no leader"
  assert_contains "$(tail -n 1 "$home/state/.wake-queue")" $'signal\ttrim:c2\tc2 trimmed its context for the 2nd time (head 138K before it) - steer or split the story; summary in '"$home/data/c2/trims/2.md (no leader)" \
    "a crewmate without a leader signals First Mate"
  # A leader whose record is gone.
  run_hook "$home" c3 "$(payload auto "$t")"
  run_hook "$home" c3 "$(payload auto "$t")"
  assert_quiet "$home" "leader without a record"
  assert_contains "$(tail -n 1 "$home/state/.wake-queue")" "(leader lead-gone no record)" "a leader without a record is named as such"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 3 ] || fail "three crewmates, three wakes"
  [ ! -e "$home/send.log" ] || fail "no doorbell rings when nobody leads"
  pass "a dead leader, no leader, or a leader without a record each queue exactly one signal wake keyed trim:<id> for First Mate, with the same line and the reason; no inbox is written"
}

# --- 5. an unreadable payload does nothing ------------------------------------
test_unreadable_payloads_write_nothing() {
  local home t bad out
  make_home unreadable; home=$HOME_DIR
  write_task "$home" c1 "leader=lead-a"
  write_task "$home" lead-a "leads=1"
  t="$home/c1.jsonl"
  write_transcript "$t"
  for bad in 'garbage' '' '[]' \
    "$(printf '{"hook_event_name":"PreCompact","trigger":"auto","transcript_path":"%s"}' "$t")" \
    "$(printf '{"hook_event_name":"PostCompact","trigger":"reactive","transcript_path":"%s"}' "$t")" \
    "$(printf '{"hook_event_name":"PostCompact","transcript_path":"%s"}' "$t")" \
    "$(payload auto "$t" "Sub." ',"agent_id":"a-42"')"; do
    run_hook "$home" c1 "$bad"
    assert_quiet "$home" "payload '$bad'"
  done
  [ ! -e "$home/data/c1/trims" ] || fail "an unreadable payload writes no record:"$'\n'"$(ls "$home/data/c1/trims")"
  [ ! -e "$home/state/.wake-queue" ] && [ ! -d "$home/state/lead-a.inbox" ] || fail "an unreadable payload rings nobody"
  out=$("$HOOK" 2>&1); [ $? -eq 2 ] || fail "running it by hand without arguments is refused with usage"
  assert_contains "$out" "usage:" "the refusal prints usage"
  out=$("$HOOK" --help) || fail "--help must exit 0"
  assert_contains "$out" "PostCompact" "--help prints the header"
  pass "seven unreadable payloads (non-JSON, empty, an array, another event, an unknown trigger, no trigger, a subagent) write nothing, ring nobody, print nothing and exit 0; only a missing argument is refused"
}

# --- 6. earlier trims the ledger missed still count ---------------------------
test_earlier_automatic_trims_count_through_the_transcript() {
  local home t
  make_home older; home=$HOME_DIR
  write_task "$home" c1
  write_task "$home" c2
  t="$home/c1.jsonl"
  # One automatic trim the ledger never saw (its row is followed by requests),
  # one manual trim, then this trim: the 2nd automatic one.
  {
    row_assistant $((NOW - 900)) m1 150000 0 0 1000
    row_boundary $((NOW - 890)) auto 151000 20000
    row_summary $((NOW - 889))
    row_assistant $((NOW - 800)) m2 20000 0 0 1000
    row_boundary $((NOW - 790)) manual 21000 9000
    row_summary $((NOW - 789))
    row_assistant $((NOW - 700)) m3 1000 2000 130000 5000
  } > "$t"
  run_hook "$home" c1 "$(payload auto "$t")"
  assert_quiet "$home" "ledger behind the transcript"
  assert_contains "$(cat "$home/data/c1/trims/1.md")" "- automatic trims so far: 2" \
    "an automatic trim the ledger missed still counts (the manual one does not)"
  assert_contains "$(tail -n 1 "$home/state/.wake-queue" 2>/dev/null)" "c1 trimmed its context for the 2nd time (head 138K before it)" \
    "the second automatic trim by the transcript's count signals First Mate"
  # A harness that appends the boundary row before the hook: the trailing row
  # with no request after it is this trim's own and is not counted twice.
  t="$home/c2.jsonl"
  {
    row_assistant $((NOW - 700)) m3 1000 2000 130000 5000
    row_boundary $((NOW - 1)) auto 138000 20000
    row_summary "$NOW"
  } > "$t"
  run_hook "$home" c2 "$(payload auto "$t")"
  assert_quiet "$home" "boundary row already written"
  assert_contains "$(cat "$home/data/c2/trims/1.md")" "- automatic trims so far: 1" \
    "a trailing boundary row with no request after it is this trim's, not an earlier one"
  assert_contains "$(cat "$home/data/c2/trims/1.md")" "- head before the trim: 138K" "the head is still the last request before the row"
  [ "$(grep -c 'trim:c2' "$home/state/.wake-queue")" = 0 ] || fail "a first automatic trim signals nobody"
  pass "the automatic count is the larger of the ledger's and the transcript's earlier auto boundary rows (manual rows and this trim's own trailing row excluded)"
}

# --- 7. the spawn installs the hook -------------------------------------------
make_spawn_home() {  # <name> -> "<home>|<proj>"
  local base="$TMP_ROOT/$1" home proj
  home="$base/home"
  proj="$base/project"
  FAKEBIN=$(make_fakebin "$base")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  printf '%s|%s\n' "$home" "$proj"
}

run_spawn() {  # <home> <proj> <id> [args...]
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the trim-event wiring for $id.

## Firstmate spec
Verify the spawn installs the PostCompact hook.
EOF
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

postcompact_command() {  # <worktree>
  jq -r '.hooks.PostCompact[0].hooks[0].command' "$1/.claude/settings.local.json"
}

test_spawn_installs_the_hook_for_every_claude_crewmate_and_leader() {
  local home proj out status wt cmd hookout t
  IFS='|' read -r home proj <<EOF
$(make_spawn_home wiring)
EOF
  out=$(run_spawn "$home" "$proj" k1); status=$?
  [ "$status" -eq 0 ] || fail "claude spawn must succeed (exit $status)"$'\n'"$out"
  wt="$proj.wt-k1"
  [ "$(jq -r '.hooks.PostCompact[0].matcher' "$wt/.claude/settings.local.json")" = 'auto|manual' ] \
    || fail "PostCompact must match auto|manual, got '$(jq -r '.hooks.PostCompact[0].matcher' "$wt/.claude/settings.local.json")'"
  [ "$(jq -r '.hooks.PostCompact | length' "$wt/.claude/settings.local.json")" = 1 ] || fail "exactly one PostCompact entry"
  cmd=$(postcompact_command "$wt")
  assert_contains "$cmd" "fm-trim-event.sh" "the hook runs the trim-event script"
  assert_contains "$cmd" " 'k1' " "the hook names the task"
  jq -e '.hooks.PreCompact and .hooks.SessionStart and .hooks.Stop' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "the trim-event hook joins the keep-set, session and busy hooks"
  # The installed command, run as the harness runs it, writes the record.
  t="$home/k1.jsonl"
  write_transcript "$t"
  hookout=$(payload auto "$t" "From the installed command." | PATH="$FAKEBIN:$PATH" bash -c "$cmd"); status=$?
  [ "$status" -eq 0 ] || fail "the installed command must exit 0 (got $status)"
  [ -z "$hookout" ] || fail "the installed command prints nothing, got: $hookout"
  [ -f "$home/data/k1/trims/1.md" ] || fail "the installed command writes data/k1/trims/1.md under the spawn's home"
  assert_contains "$(cat "$home/data/k1/trims/1.md")" "From the installed command." "the record carries the summary"
  hookout=$(printf 'garbage' | bash -c "$cmd"); status=$?
  [ "$status" -eq 0 ] && [ -z "$hookout" ] || fail "the installed command prints nothing and exits 0 on garbage"
  # A leader gets the same hook: its trims are recorded and its second reaches First Mate.
  out=$(run_spawn "$home" "$proj" k2 --leads); status=$?
  [ "$status" -eq 0 ] || fail "leader spawn must succeed (exit $status)"$'\n'"$out"
  cmd=$(postcompact_command "$proj.wt-k2")
  assert_contains "$cmd" "fm-trim-event.sh" "a leader's worktree carries the trim-event hook too"
  assert_contains "$cmd" " 'k2' " "the leader's hook names the leader"
  # A harness without hooks of this kind gets nothing.
  out=$(run_spawn "$home" "$proj" k3 --harness codex); status=$?
  [ "$status" -eq 0 ] || fail "codex spawn must succeed (exit $status)"$'\n'"$out"
  [ ! -e "$proj.wt-k3/.claude/settings.local.json" ] || fail "a codex spawn writes no claude settings"
  pass "the spawn installs PostCompact auto|manual running the trim-event script with the home and the id for a claude crewmate and a leader, never for codex; the installed command writes the record and prints nothing"
}

test_records_every_trim
test_second_automatic_trim_rings_the_leader
test_manual_trim_records_and_rings_nobody
test_manual_trim_after_an_order_is_attributed
test_an_automatic_trim_before_the_boundary_leaves_the_order
test_a_failed_nudge_still_spends_the_order
test_without_a_live_leader_first_mate_is_signalled
test_unreadable_payloads_write_nothing
test_earlier_automatic_trims_count_through_the_transcript
test_spawn_installs_the_hook_for_every_claude_crewmate_and_leader

echo "# all fm-trim-event tests passed"
