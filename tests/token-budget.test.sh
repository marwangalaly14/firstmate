#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the worker auto-compaction machinery:
# bin/fm-compact-lib.sh (the pure decision), bin/fm-compact-spine.sh (the
# SessionStart compact hook that reprints the story spine from disk and keeps
# the compaction ledger), and bin/fm-compact-stop.sh (the PreToolUse hook that
# denies further tool calls at a second compaction).
#
# The measured trigger law lives in bin/fm-compact-lib.sh's header: claude
# 2.1.259 compacts at autoCompactWindow - 33000, so the spawn-written window is
# 153000. These tests pin the decision matrix, the budget and ledger parsers,
# the spine's output and side effects from fixture worlds, the deny shape, the
# duplicate settings-layer double-fire dedup, the firstmate lift line, and the
# spawn wiring that writes the window and both hooks. No live harness session
# is spawned here; the live rehearsal is recorded in the task report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-compact-lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot token-budget)
SPINE_SESSION=token-budget-test-session

# --- fixture worlds -----------------------------------------------------------

make_transcript() {  # <file> [extra-rows...]
  # Usage rows 1000, 5000 (via cache_read), 4000 (via cache_creation), plus a
  # sidechain row at 99999 that must never be counted. Largest is therefore
  # 5000, derived from the fixture rather than typed by the assertion.
  cat > "$1" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"usage":{"input_tokens":2000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}}}
{"isSidechain":true,"message":{"usage":{"input_tokens":99999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":4000}}}
EOF
}

make_story() {  # <name> <budget-line-or-empty>
  # A fixture firstmate home that is itself a git repo (so derive mode can
  # resolve it from a worktree's git-common-dir), with bin/ and state/, one
  # task brief, and a status file.
  local name=$1 budget=$2
  local home="$TMP_ROOT/$name/home"
  mkdir -p "$home/bin" "$home/state" "$home/data"
  git -C "$home" init -q -b main 2>/dev/null || git -C "$home" init -q
  git -C "$home" -c user.email=t@e -c user.name=t commit -q --allow-empty -m seed
  local id="$name-story"
  mkdir -p "$home/data/$id"
  {
    printf '%s\n' '# Task' "## Captain's intent" 'Do the thing.' '' '## Firstmate spec' 'Do it well.'
    if [ -n "$budget" ]; then printf '%s\n' "$budget"; fi
  } > "$home/data/$id/brief.md"
  printf 'working: brief accepted\n' > "$home/state/$id.status"
  printf '%s|%s' "$home" "$id"
}

compact_payload() {  # <session> <transcript> <cwd> [source]
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" \
    '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"SessionStart", source:"compact"}'
}

run_spine() {  # <payload-json> [args...]
  printf '%s\n' "$1" | "$ROOT/bin/fm-compact-spine.sh" "${@:-}"
}

run_stop() {  # <payload-json> [args...]
  printf '%s\n' "$1" | "$ROOT/bin/fm-compact-stop.sh" "${@:-}"
}

pretool_payload() {  # <cwd>
  jq -n --arg c "$1" '{hook_event_name:"PreToolUse", cwd:$c, tool_name:"Bash", tool_input:{command:"ls"}}'
}

# --- pure decision ------------------------------------------------------------

test_budget_parser() {
  local b="$TMP_ROOT/briefs"
  mkdir -p "$b"
  printf 'Budget: roughly 140K tokens\n' > "$b/k-line"
  printf 'Budget: 140,000 tokens\n' > "$b/commas"
  printf 'Budget: 500k\n' > "$b/lower-k"
  printf 'Budget: 2M tokens\n' > "$b/mega"
  printf 'Budget: 90000\n' > "$b/plain"
  printf 'some prose\nBudget: about 120K tokens\nmore prose\n' > "$b/mid-file"
  printf '# Task\nno budget here\n' > "$b/absent"
  printf 'Budget: see the plan\n' > "$b/no-number"
  printf 'Budget: 1.2M tokens\n' > "$b/decimal"
  assert_contains "$(fm_compact_budget_from_brief "$b/k-line")" '140000'
  [ "$(fm_compact_budget_from_brief "$b/k-line")" = '140000' ] || fail "roughly 140K must parse to 140000"
  [ "$(fm_compact_budget_from_brief "$b/commas")" = '140000' ] || fail "commas must strip"
  [ "$(fm_compact_budget_from_brief "$b/lower-k")" = '500000' ] || fail "500k must parse to 500000"
  [ "$(fm_compact_budget_from_brief "$b/mega")" = '2000000' ] || fail "2M must parse to 2000000"
  [ "$(fm_compact_budget_from_brief "$b/plain")" = '90000' ] || fail "plain number must pass through"
  [ "$(fm_compact_budget_from_brief "$b/mid-file")" = '120000' ] || fail "Budget line found anywhere in the brief"
  [ -z "$(fm_compact_budget_from_brief "$b/absent")" ] || fail "missing Budget line must parse empty"
  [ -z "$(fm_compact_budget_from_brief "$b/no-number")" ] || fail "Budget line without a number must parse empty"
  [ -z "$(fm_compact_budget_from_brief "$b/decimal")" ] || fail "decimal budgets must not parse to a wrong integer"
  [ -z "$(fm_compact_budget_from_brief "$TMP_ROOT/briefs/does-not-exist")" ] || fail "missing brief must parse empty"
  pass "budget parser accepts the fleet's real shapes and refuses to guess"
}

test_decision_matrix() {
  [ "$(fm_compact_decide 130000 0 140000)" = 'silent' ] || fail "no compaction is silent"
  [ "$(fm_compact_decide 130000 1 140000)" = 'incident' ] || fail "one compaction is the incident line"
  [ "$(fm_compact_decide 130000 2 140000)" = 'stop' ] || fail "two compactions stop"
  [ "$(fm_compact_decide 130000 5 140000)" = 'stop' ] || fail "more than two still stop"
  [ "$(fm_compact_decide 130000 2 0)" = 'silent' ] || fail "zero budget is silent: the gate is the brief"
  [ "$(fm_compact_decide 130000 2 '')" = 'silent' ] || fail "absent budget is silent"
  [ "$(fm_compact_decide 0 2 140000)" = 'stop' ] || fail "an unmeasured peak must not weaken the stop"
  [ "$(fm_compact_decide abc 2 140000)" = 'stop' ] || fail "junk peak must not evade the stop"
  [ "$(fm_compact_decide 130000 x 140000)" = 'silent' ] || fail "junk count must not fabricate a compaction"
  [ "$(fm_compact_decide 130000 02 140000)" = 'stop' ] || fail "zero-padded count still stops"
  pass "decision matrix: silent/incident/stop, gated on the budget, never evadable by junk"
}

test_hold_sentence_is_one_line_with_both_numbers() {
  local out
  out=$(fm_compact_hold_sentence 121000 140000)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = '1' ] || fail "hold must be one sentence"
  assert_contains "$out" '121000'
  assert_contains "$out" '140000'
  pass "hold sentence carries the peak and the budget in one line"
}

test_status_ledger_parsers() {
  local st="$TMP_ROOT/ledgers"
  mkdir -p "$st"
  : > "$st/empty"
  printf 'compacted 1 at 118000\n' > "$st/one"
  printf 'working: x\ncompacted 1 at 118000\ncompacted 2 at 121000\n' > "$st/two"
  printf 'compacted 2 at 130000 plus prose\ncompacted 1 at 118000\n' > "$st/near-miss"
  [ "$(fm_compact_count_from_status "$st/empty")" = '0' ] || fail "empty ledger counts 0"
  [ "$(fm_compact_count_from_status "$st/one")" = '1' ] || fail "one line counts 1"
  [ "$(fm_compact_count_from_status "$st/two")" = '2' ] || fail "two lines count 2"
  [ "$(fm_compact_count_from_status "$st/near-miss")" = '1' ] || fail "trailing prose is not a ledger line"
  [ "$(fm_compact_count_from_status "$st/missing-file")" = '0' ] || fail "missing status file counts 0"
  [ "$(fm_compact_last_largest_from_status "$st/two")" = '121000' ] || fail "largest reads from the last ledger line"
  [ -z "$(fm_compact_last_largest_from_status "$st/empty")" ] || fail "no ledger line means no largest"
  [ "$(fm_compact_last_largest_from_status "$st/missing-file")" = '0' ] || [ -z "$(fm_compact_last_largest_from_status "$st/missing-file")" ] || fail "missing file largest is empty or zero"
  pass "ledger parsers count only exact compacted lines and read the latest peak"
}

test_lift_line_detector() {
  local st="$TMP_ROOT/lift"
  mkdir -p "$st"
  printf 'compacted 2 at 121000\n' > "$st/no-lift"
  printf 'compacted 2 at 121000\ncompaction-stop-lifted: firstmate split the story\n' > "$st/lifted"
  fm_compact_status_has_lift "$st/no-lift" && fail "no lift line must not read as lifted"
  fm_compact_status_has_lift "$st/lifted" || fail "lift line must be detected"
  pass "the firstmate lift line is detected exactly"
}

# --- spine hook ---------------------------------------------------------------

test_spine_first_compaction() {
  local rec home id out st learnings transcript
  rec=$(make_story spine-first 'Budget: roughly 140K tokens')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-first/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  learnings="$home/data/learnings.md"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "first compaction must exit 0"
  assert_contains "$out" "$home/data/$id/brief.md"
  assert_contains "$out" 'Budget: roughly 140K'
  assert_contains "$out" 'Do the thing.' # the captain's intent comes back from the brief
  assert_contains "$out" 'Do it well.'   # and the spec body, not a summary of them
  assert_contains "$out" 'compacted 1'
  assert_contains "$out" 'brief accepted'
  grep -q '^compacted 1 at 5000$' "$st" || fail "status ledger must gain 'compacted 1 at 5000' (derived from fixture usage rows), got: $(cat "$st")"
  [ "$(fm_compact_count_from_status "$st")" = '1' ] || fail "exactly one ledger line after the first compaction"
  assert_contains "$(cat "$learnings")" "$id"
  assert_contains "$(cat "$learnings")" '5000'
  assert_contains "$(cat "$learnings")" '140000'
  [ "$(grep -c "compacted once" "$learnings")" = '1' ] || fail "one incident line"
  assert_present "$home/state/.$id.compact-fire" "dedup marker must exist after a fire"
  pass "first compaction: ledger line, learnings incident, spine printed from disk"
}

test_spine_silent_without_budget() {
  local rec home id out st transcript
  rec=$(make_story spine-nobudget '')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-nobudget/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "no budget must still exit 0"
  [ -z "$out" ] || fail "no budget must print no spine, got: $out"
  [ "$(fm_compact_count_from_status "$st")" = '0' ] || fail "no budget must not append a ledger line"
  [ ! -e "$home/data/learnings.md" ] || fail "no budget must not write learnings"
  pass "no budget in the brief: the whole hook is silent and writes nothing"
}

test_spine_dedup_double_fire() {
  local rec home id out1 out2 st transcript learnings
  rec=$(make_story spine-dedup 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-dedup/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  learnings="$home/data/learnings.md"
  out1=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  out2=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  [ -n "$out1" ] || fail "the first fire must print the spine"
  expect_code 0 $? "duplicate fire must exit 0"
  [ -z "$out2" ] || fail "duplicate fire must print nothing, got: $out2"
  [ "$(fm_compact_count_from_status "$st")" = '1' ] || fail "duplicate fire must not add a ledger line"
  [ "$(grep -c 'compacted once' "$learnings")" = '1' ] || fail "duplicate fire must not add an incident line"
  pass "the same event firing from two settings layers appends once"
}

test_spine_second_compaction_blocks() {
  local rec home id out st transcript learnings
  rec=$(make_story spine-second 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-second/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  learnings="$home/data/learnings.md"
  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  # Age the marker past the dedup window so this fire is a NEW compaction, not
  # the duplicate settings-layer fire of the first one.
  printf '%s %s %s\n' "$(( $(date +%s) - 60 ))" 1 "$SPINE_SESSION" > "$home/state/.$id.compact-fire"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "second compaction must exit 0 (SessionStart cannot block anyway)"
  [ "$(fm_compact_count_from_status "$st")" = '2' ] || fail "second compaction must add a ledger line, status: $(cat "$st")"
  grep -q '^blocked:' "$st" || fail "second compaction must append a blocked line so firstmate wakes"
  assert_contains "$out" 'denied'
  [ "$(grep -c 'compacted once' "$learnings")" = '1' ] || fail "the incident line is written once, at the first compaction"
  pass "second compaction: ledger, blocked line for firstmate, hold paragraph in the spine"
}

test_spine_ignores_other_sources() {
  local rec home id out st transcript
  rec=$(make_story spine-source 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-source/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  out=$(printf '{"session_id":"s","transcript_path":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  [ -z "$out" ] || fail "non-compact source must be silent, got: $out"
  [ "$(fm_compact_count_from_status "$st")" = '0' ] || fail "non-compact source must not append"
  out=$(printf 'not json at all' | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "unparseable payload must exit 0"
  [ -z "$out" ] || fail "unparseable payload must be silent"
  pass "the hook answers only the compact source and never dies on bad input"
}

test_spine_derive_mode() {
  # No --home/--id: resolve the story from the payload cwd's fm/<id> branch and
  # the owning home from the git common dir, the shape of a firstmate-repo
  # worker whose worktree lives under ~/.treehouse.
  local rec home id out st transcript wt
  rec=$(make_story spine-derive 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  wt="$TMP_ROOT/spine-derive/wt"
  fm_git_worktree "$home" "$wt" "fm/$id"
  transcript="$TMP_ROOT/spine-derive/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$wt" | "$ROOT/bin/fm-compact-spine.sh")
  expect_code 0 $? "derive mode must exit 0"
  grep -q '^compacted 1 at 5000$' "$st" || fail "derive mode must append the ledger line, status: $(cat "$st")"
  assert_contains "$out" 'compacted 1'
  pass "shared-settings mode derives home and story from the worktree branch"
}

test_spine_missing_transcript_reads_zero_peak() {
  local rec home id out st
  rec=$(make_story spine-notranscript 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  st="$home/state/$id.status"
  out=$(compact_payload "$SPINE_SESSION" "$TMP_ROOT/spine-notranscript/nope.jsonl" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "missing transcript must exit 0"
  grep -q '^compacted 1 at 0$' "$st" || fail "missing transcript must ledger peak 0, got: $(cat "$st")"
  assert_contains "$out" 'transcript'
  pass "a missing or lagging transcript compacts to peak 0 and says so"
}

# --- stop hook ----------------------------------------------------------------

test_stop_hook_matrix() {
  local rec home id out rc st transcript
  rec=$(make_story stop-matrix 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/stop-matrix/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"

  out=$(pretool_payload "$home" | "$ROOT/bin/fm-compact-stop.sh" --home "$home" --id "$id" 2>/dev/null)
  rc=$?
  [ "$rc" = '0' ] && [ -z "$out" ] || fail "no compaction yet: stop hook must be silent ($rc) $out"

  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  out=$(pretool_payload "$home" | "$ROOT/bin/fm-compact-stop.sh" --home "$home" --id "$id" 2>/dev/null)
  rc=$?
  [ "$rc" = '0' ] && [ -z "$out" ] || fail "one compaction must not deny tools ($rc): $out"

  printf '%s %s %s\n' "$(( $(date +%s) - 60 ))" 1 "$SPINE_SESSION" > "$home/state/.$id.compact-fire"
  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  out=$(pretool_payload "$home" | "$ROOT/bin/fm-compact-stop.sh" --home "$home" --id "$id" 2>"$TMP_ROOT/stop-err")
  rc=$?
  [ "$rc" = '2' ] || fail "two compactions must deny with exit 2, got $rc"
  [ -z "$out" ] || fail "deny must keep stdout empty, got: $out"
  assert_contains "$(cat "$TMP_ROOT/stop-err")" '"permissionDecision":"deny"'
  assert_contains "$(cat "$TMP_ROOT/stop-err")" '5000'
  assert_contains "$(cat "$TMP_ROOT/stop-err")" '140000'

  printf 'compaction-stop-lifted: firstmate split the story\n' >> "$st"
  out=$(pretool_payload "$home" | "$ROOT/bin/fm-compact-stop.sh" --home "$home" --id "$id" 2>/dev/null)
  rc=$?
  [ "$rc" = '0' ] && [ -z "$out" ] || fail "lift line must release the stop ($rc): $out"
  pass "stop hook: silent until the second compaction, house deny shape, released by the lift line"
}

test_stop_hook_no_budget_and_bad_payload() {
  local rec home id out rc transcript
  rec=$(make_story stop-nobudget '')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/stop-nobudget/transcript.jsonl"
  make_transcript "$transcript"
  local st="$home/state/${rec#*|}.status"
  # Force the ledger to two compactions without a budget: the gate must stay open.
  printf 'compacted 2 at 121000\n' >> "$st"
  out=$(pretool_payload "$home" | "$ROOT/bin/fm-compact-stop.sh" --home "$home" --id "$id" 2>/dev/null)
  rc=$?
  [ "$rc" = '0' ] || fail "no budget must keep the gate open even at count 2, got $rc"
  out=$(printf 'garbage' | "$ROOT/bin/fm-compact-stop.sh" --home "$home" --id "$id" 2>/dev/null)
  rc=$?
  [ "$rc" = '0' ] && [ -z "$out" ] || fail "unparseable payload must fail open ($rc): $out"
  pass "no budget or unreadable payload: the stop hook steps aside"
}

# --- spawn wiring -------------------------------------------------------------

make_spawn_case() {  # <name> <id> <budget-line>
  local name=$1 id=$2 budget=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  [ -n "$budget" ] && printf '%s\n' "$budget" >> "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s' "$home" "$wt" "$fakebin" "$proj"
}

test_spawn_writes_window_and_hooks() {
  local rec home wt fakebin proj id='wired-1' settings out cmd st transcript rest
  rec=$(make_spawn_case spawn-wiring "$id" 'Budget: roughly 140K tokens')
  home=${rec%%|*}; rest=${rec#*|}; wt=${rest%%|*}; rest=${rest#*|}; fakebin=${rest%%|*}; proj=${rest#*|}
  settings="$wt/.claude/settings.local.json"

  out=$(GROK_HOME="$home/grok-home" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "spawn should succeed: $out"
  assert_present "$settings"
  jq -e . "$settings" >/dev/null || fail "spawn-written settings are not valid JSON"

  # The window comes from the lib's measured constant, never a typed copy.
  local window
  window=$(jq -r '.autoCompactWindow' "$settings")
  [ "$window" = "$FM_COMPACT_WINDOW_TOKENS" ] || fail "spawn window must equal the lib's measured constant ($FM_COMPACT_WINDOW_TOKENS), got $window"

  # The busy hooks the wiring suite owns must all still be present.
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "spawn settings lost $ev"
  done

  jq -e '.hooks.SessionStart[0].matcher == "compact"' "$settings" >/dev/null \
    || fail "spawn settings must carry a SessionStart compact matcher"
  local spine_cmd stop_cmd
  spine_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")
  stop_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  printf '%s' "$spine_cmd" | grep -q 'fm-compact-spine.sh' || fail "SessionStart command must invoke fm-compact-spine.sh"
  printf '%s' "$spine_cmd" | grep -q -- '--home' || fail "SessionStart command must carry an explicit home"
  printf '%s' "$spine_cmd" | grep -q -- "--id '$id'" || fail "SessionStart command must carry the task id"
  printf '%s' "$stop_cmd" | grep -q 'fm-compact-stop.sh' || fail "PreToolUse command must invoke fm-compact-stop.sh"
  printf '%s' "$stop_cmd" | grep -q -- "--id '$id'" || fail "PreToolUse command must carry the task id"

  # Drive the generated SessionStart command end to end: the wiring must work,
  # not merely exist.
  transcript="$TMP_ROOT/spawn-wiring/transcript.jsonl"
  make_transcript "$transcript"
  st="$home/state/$id.status"
  cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$wt" | sh -c "$cmd")
  expect_code 0 $? "generated SessionStart command must run: $out"
  grep -q '^compacted 1 at 5000$' "$st" || fail "driven spawn hook must ledger the compaction, status: $(cat "$st")"
  assert_contains "$out" 'compacted 1'
  pass "spawn writes the measured window plus both hooks, and the generated hook runs"
}

test_shared_settings_carries_compact_entry() {
  jq -e '.hooks.SessionStart[] | select(.matcher == "compact")' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "shared .claude/settings.json must carry a SessionStart compact matcher"
  jq -r '.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command' "$ROOT/.claude/settings.json" \
    | grep -q 'fm-compact-spine.sh' || fail "shared compact entry must invoke fm-compact-spine.sh"
  pass "the shared settings carry the versioned compact hook"
}

test_scripts_are_shellcheck_clean() {
  "$ROOT/bin/fm-lint.sh" >/dev/null 2>&1 || fail "fm-lint.sh failed"
  pass "all scripts pass the repo lint"
}

# --- run ----------------------------------------------------------------------
test_budget_parser
test_decision_matrix
test_hold_sentence_is_one_line_with_both_numbers
test_status_ledger_parsers
test_lift_line_detector
test_spine_first_compaction
test_spine_silent_without_budget
test_spine_dedup_double_fire
test_spine_second_compaction_blocks
test_spine_ignores_other_sources
test_spine_derive_mode
test_spine_missing_transcript_reads_zero_peak
test_stop_hook_matrix
test_stop_hook_no_budget_and_bad_payload
test_spawn_writes_window_and_hooks
test_shared_settings_carries_compact_entry
test_scripts_are_shellcheck_clean
echo "all token-budget tests passed"