#!/usr/bin/env bash
# tests/fm-compact-lib.test.sh - the 250K line's arithmetic, pinned through
# bin/fm-compact-lib.sh, the one owner of the mark, the harness's two terms,
# and the derived autoCompactWindow the spawn writes for a story crewmate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-compact-lib.sh
. "$ROOT/bin/fm-compact-lib.sh"

test_constants_are_the_captains_line_and_the_harness_terms() {
  [ "$FM_COMPACT_MARK" = 250000 ] || fail "the mark is the captain's 250K line, got $FM_COMPACT_MARK"
  [ "$FM_COMPACT_RESERVED_OUTPUT" = 20000 ] || fail "the harness keeps min(model max output, 20000) for the reply, got $FM_COMPACT_RESERVED_OUTPUT"
  [ "$FM_COMPACT_MARGIN" = 13000 ] || fail "the harness's fixed margin is 13000, got $FM_COMPACT_MARGIN"
  [ "$FM_COMPACT_SETTINGS_KEY" = autoCompactWindow ] || fail "the settings key is autoCompactWindow, got $FM_COMPACT_SETTINGS_KEY"
  pass "constants: mark 250000, reserved output 20000, margin 13000, key autoCompactWindow"
}

test_window_is_mark_plus_reserved_plus_margin() {
  local w
  w=$(fm_compact_window) || fail "fm_compact_window must succeed"
  [ "$w" = 283000 ] || fail "window for the 250K line must be 283000 (250000+20000+13000), got $w"
  w=$(fm_compact_window_for_mark 100000) || fail "fm_compact_window_for_mark must succeed"
  [ "$w" = 133000 ] || fail "window for a 100K mark must be 133000, got $w"
  w=$(fm_compact_mark_of_window 283000) || fail "fm_compact_mark_of_window must succeed"
  [ "$w" = 250000 ] || fail "the mark behind window 283000 is 250000, got $w"
  w=$(fm_compact_mark_of_window 200000) || fail "fm_compact_mark_of_window must succeed on the model default"
  [ "$w" = 167000 ] || fail "the harness's own line for a 200K window is 167000, got $w"
  pass "derivation: 283000 = 250000 + 20000 + 13000, and its inverse"
}

test_a_window_that_is_not_the_derivation_is_refused() {
  local out
  fm_compact_check_window 283000 || fail "the derived window must pass the check"
  out=$(fm_compact_check_window 282000 2>&1) && fail "a window one step off the derivation must be refused"
  assert_contains "$out" "282000" "the refusal names the window it was given"
  assert_contains "$out" "283000" "the refusal names the derived window"
  assert_contains "$out" "250000 + 20000 + 13000" "the refusal shows the derivation"
  out=$(fm_compact_check_window 173000 2>&1) && fail "the old 140K line's window must be refused now the mark is 250000"
  assert_contains "$out" "283000" "the refusal against the old window names the derived one"
  out=$(fm_compact_check_window 250000 2>&1) && fail "writing the mark itself as the window must be refused: the harness would trim at 217000"
  out=$(fm_compact_check_window abc 2>&1) && fail "a non-numeric window must be refused"
  out=$(fm_compact_check_window '' 2>&1) && fail "an empty window must be refused"
  out=$(fm_compact_window_for_mark 12x 2>&1) && fail "a non-numeric mark must be refused"
  out=$(fm_compact_mark_of_window 30000 2>&1) && fail "a window below the two harness terms has no mark and must be refused"
  pass "refusals: a window that is not mark + reserved + margin, a non-number, an empty value"
}

test_constants_are_the_captains_line_and_the_harness_terms
test_window_is_mark_plus_reserved_plus_margin
test_a_window_that_is_not_the_derivation_is_refused
echo "# all fm-compact-lib tests passed"
