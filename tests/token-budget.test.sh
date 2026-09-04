#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the worker auto-compaction machinery:
# bin/fm-compact-lib.sh (the pure decision) and bin/fm-compact-spine.sh (the
# SessionStart compact hook that reprints the story spine from disk, keeps the
# compaction ledger in its own file, and signals the branch leader at a second
# compaction without ever stopping the worker).
#
# The measured trigger law lives in bin/fm-compact-lib.sh's header: claude
# 2.1.259 compacts at autoCompactWindow - 33000, so the spawn-written window is
# 153000 and the real trigger is ~120k.
#
# Every spine behavior below is proven against a brief produced by the REAL
# scaffold (bin/fm-brief.sh), because the hook's inputs are real briefs: its
# gate key is the budget= field fm-spawn writes (real scaffold briefs carry no
# Budget line), and its Definition-of-done match must hit the scaffold's
# one-hash heading. No live harness session is spawned here; the live
# rehearsal is recorded in the task report.

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

make_transcript() {  # <file>
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

make_boundary_transcript() {  # <file>
  # A session that compacted twice before: 100000 pre-boundary-1, 60000
  # between the boundaries, then 5000 and 8000 after boundary 2, with a
  # sidechain giant after boundary 2 that must never count. The current
  # compaction's peak is therefore 8000 and the boundary count 2, both
  # derived from the fixture. input_line_number requires one JSON value per
  # line, which is the transcript's real shape.
  cat > "$1" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"system","subtype":"compact_boundary"}
{"type":"assistant","message":{"usage":{"input_tokens":60000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"system","subtype":"compact_boundary"}
{"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"isSidechain":true,"message":{"usage":{"input_tokens":99999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":8000}}}
EOF
}

make_home() {  # <name>
  # A fixture firstmate home that is itself a git repo (so derive mode can
  # resolve it from a worktree's git-common-dir), with bin/ and state/ and a
  # status file. No brief: the caller writes the one its test needs.
  local name=$1
  local home="$TMP_ROOT/$name/home"
  mkdir -p "$home/bin" "$home/state" "$home/data"
  git -C "$home" init -q -b main 2>/dev/null || git -C "$home" init -q
  git -C "$home" -c user.email=t@e -c user.name=t commit -q --allow-empty -m seed
  local id="$name-story"
  printf 'working: brief accepted\n' > "$home/state/$id.status"
  printf '%s|%s' "$home" "$id"
}

make_story() {  # <name> <budget-line-or-empty>
  # A home plus a hand-written brief. The hand-written shape is what the
  # override and fallback tests need; the real-scaffold tests use make_home
  # plus make_real_scaffold_brief instead.
  local name=$1 budget=$2
  local home id
  home=$(make_home "$name"); id=${home#*|}
  home=${home%|*}
  mkdir -p "$home/data/$id"
  {
    printf '%s\n' '# Task' "## Captain's intent" 'Do the thing.' '' '## Firstmate spec' 'Do it well.'
    if [ -n "$budget" ]; then printf '%s\n' "$budget"; fi
  } > "$home/data/$id/brief.md"
  printf '%s|%s' "$home" "$id"
}

make_real_scaffold_brief() {  # <home> <id> <mode>
  # Brief the way firstmate really briefs: bin/fm-brief.sh scaffolds, then the
  # placeholders {TASK} and {FIRSTMATE_SPEC} are filled - the same two steps
  # firstmate performs before a spawn. Real scaffold briefs carry no Budget
  # line, so anything that needs a budget must get it from the spawn-written
  # task record, exactly as production does.
  local home=$1 id=$2 mode=$3 brief
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "fixture-project" --mode "$mode" >/dev/null \
    || fail "fm-brief.sh must scaffold a real brief"
  brief="$home/data/$id/brief.md"
  perl -pi -e 's/\{TASK\}/Make the fixture thing work./g; s/\{FIRSTMATE_SPEC\}/Exercise the machinery./g' "$brief"
  [ -f "$brief" ] || fail "real scaffold must write the brief"
}

wake_rows() {  # <kind>
  # The durable wake queue's rows of one kind, if any. $home_wake_state names
  # the state directory the caller is testing.
  local kind=$1
  [ -n "${home_wake_state:-}" ] && [ -f "$home_wake_state/.wake-queue" ] || return 0
  awk -F'\t' -v k="$kind" '$3 == k' "$home_wake_state/.wake-queue"
}

compact_payload() {  # <session> <transcript> <cwd> [source]
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" \
    '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"SessionStart", source:"compact"}'
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

test_meta_budget_parser() {
  local m="$TMP_ROOT/meta"
  mkdir -p "$m"
  {
    echo "window=firstmate:story"
    echo "harness=claude"
    echo "budget=120000"
    echo "kind=task"
  } > "$m/one"
  printf 'harness=codex\n' > "$m/none"
  [ "$(fm_compact_budget_from_meta "$m/one")" = '120000' ] || fail "spawn-written budget= must parse"
  [ -z "$(fm_compact_budget_from_meta "$m/none")" ] || fail "meta without budget= must parse empty"
  [ -z "$(fm_compact_budget_from_meta "$m/missing")" ] || fail "missing meta must parse empty"
  pass "the gate's normal key is the spawn-written budget= field"
}

test_decision_matrix() {
  [ "$(fm_compact_decide 130000 0 140000)" = 'silent' ] || fail "no compaction is silent"
  [ "$(fm_compact_decide 130000 1 140000)" = 'incident' ] || fail "one compaction is the incident line"
  [ "$(fm_compact_decide 130000 2 140000)" = 'signal' ] || fail "two compactions signal the branch leader"
  [ "$(fm_compact_decide 130000 5 140000)" = 'signal' ] || fail "more than two still signal"
  [ "$(fm_compact_decide 130000 2 0)" = 'silent' ] || fail "zero budget is silent: the gate is the budget"
  [ "$(fm_compact_decide 130000 2 '')" = 'silent' ] || fail "absent budget is silent"
  [ "$(fm_compact_decide 0 2 140000)" = 'signal' ] || fail "an unmeasured peak must not weaken the signal"
  [ "$(fm_compact_decide abc 2 140000)" = 'signal' ] || fail "junk peak must not evade the signal"
  [ "$(fm_compact_decide 130000 x 140000)" = 'silent' ] || fail "junk count must not fabricate a compaction"
  [ "$(fm_compact_decide 130000 02 140000)" = 'signal' ] || fail "zero-padded count still signals"
  pass "decision matrix: silent/incident/signal, gated on the budget, never evadable by junk"
}

test_signal_message_is_one_short_line() {
  local out
  out=$(fm_compact_signal_message my-story 2 121000 140000)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = '1' ] || fail "signal must be one line"
  assert_contains "$out" 'my-story' 'needle missing'
  assert_contains "$out" 'twice' 'needle missing'
  assert_contains "$out" '121000' 'needle missing'
  assert_contains "$out" '140000' 'needle missing'
  out=$(fm_compact_signal_message my-story 3 121000 140000)
  assert_contains "$out" '3 times' 'needle missing'
  # No human-written budget: the line says what is true and stops. Measuring
  # the peak against the machine trigger a worker compacts AT says nothing.
  out=$(fm_compact_signal_message my-story 2 121000 '')
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = '1' ] || fail "the budget-less signal must be one line"
  assert_contains "$out" 'my-story' 'needle missing'
  assert_contains "$out" 'twice' 'needle missing'
  assert_contains "$out" '121000' 'needle missing'
  [ "$(printf '%s' "$out" | grep -c 'budget')" = '0' ] || fail "with no briefed budget the signal must claim none, got: $out"
  pass "the signal names the worker, the count and the peak, and a budget only when a human wrote one"
}

test_ledger_parsers() {
  local st="$TMP_ROOT/ledgers"
  mkdir -p "$st"
  : > "$st/empty"
  printf 'compacted 1 at 118000\n' > "$st/one"
  printf 'compacted 1 at 118000\ncompacted 2 at 121000\n' > "$st/two"
  printf 'compacted 2 at 130000 plus prose\ncompacted 1 at 118000\n' > "$st/near-miss"
  # A story whose earlier compactions were counted from the transcript writes
  # its recorded number as the ledger's FIRST line; the file holds one line and
  # three compactions.
  printf 'compacted 3 at 8000\n' > "$st/recorded-third"
  printf 'compacted 3 at 8000\ncompacted 4 at 9000\n' > "$st/recorded-fourth"
  [ "$(fm_compact_count_from_ledger "$st/empty")" = '0' ] || fail "empty ledger counts 0"
  [ "$(fm_compact_count_from_ledger "$st/one")" = '1' ] || fail "one line counts 1"
  [ "$(fm_compact_count_from_ledger "$st/two")" = '2' ] || fail "two lines count 2"
  [ "$(fm_compact_count_from_ledger "$st/near-miss")" = '1' ] || fail "trailing prose is not a ledger line"
  [ "$(fm_compact_count_from_ledger "$st/missing-file")" = '0' ] || fail "missing ledger counts 0"
  [ "$(fm_compact_count_from_ledger "$st/recorded-third")" = '3' ] \
    || fail "a ledger recording a third compaction must count 3, not its one line"
  [ "$(fm_compact_count_from_ledger "$st/recorded-fourth")" = '4' ] \
    || fail "the ledger's count is the highest number it recorded"
  pass "the ledger counts the highest compaction it recorded, never fewer"
}

test_boundary_count_and_peak() {
  local t="$TMP_ROOT/boundary/t.jsonl"
  mkdir -p "$(dirname "$t")"
  make_boundary_transcript "$t"
  [ "$(fm_compact_count_from_boundaries "$t")" = '2' ] || fail "two boundary rows must count 2"
  [ "$(fm_compact_peak_from_transcript "$t")" = '8000' ] || fail "peak must read only rows after the last boundary, got $(fm_compact_peak_from_transcript "$t")"
  : > "$TMP_ROOT/boundary/empty.jsonl"
  [ "$(fm_compact_count_from_boundaries "$TMP_ROOT/boundary/empty.jsonl")" = '0' ] || fail "no boundaries counts 0"
  [ "$(fm_compact_peak_from_transcript "$TMP_ROOT/boundary/empty.jsonl")" = '0' ] || fail "no usage rows peak 0"
  [ -z "$(fm_compact_count_from_boundaries "$TMP_ROOT/boundary/missing.jsonl")" ] || fail "missing transcript yields no count (caller falls back to the ledger)"
  printf 'not json at all\n{"type":"system","subtype":"compact_bound\n' > "$TMP_ROOT/boundary/malformed.jsonl"
  [ -z "$(fm_compact_count_from_boundaries "$TMP_ROOT/boundary/malformed.jsonl")" ] \
    || fail "an unparseable transcript must yield no count, not 0: got $(fm_compact_count_from_boundaries "$TMP_ROOT/boundary/malformed.jsonl")"
  # Both answers come from ONE read of the file; the pair must agree with the
  # fixture exactly as the two separate readings did.
  [ "$(fm_compact_scan_transcript "$t")" = '2 8000' ] \
    || fail "one scan must answer both count and peak, got: $(fm_compact_scan_transcript "$t")"
  make_transcript "$TMP_ROOT/boundary/flat.jsonl"
  [ "$(fm_compact_scan_transcript "$TMP_ROOT/boundary/flat.jsonl")" = '0 5000' ] \
    || fail "a never-compacted transcript scans 0 boundaries and its largest non-sidechain row"
  [ -z "$(fm_compact_scan_transcript "$TMP_ROOT/boundary/malformed.jsonl")" ] || fail "an unparseable transcript scans empty"
  [ -z "$(fm_compact_scan_transcript "$TMP_ROOT/boundary/missing.jsonl")" ] || fail "a missing transcript scans empty"
  [ "$(fm_compact_peak_from_transcript "$TMP_ROOT/boundary/missing.jsonl")" = '0' ] || fail "missing transcript peaks 0"
  pass "count comes from the transcript's boundaries and the peak from after the last one"
}

# --- spine hook ---------------------------------------------------------------

test_spine_first_compaction_on_real_scaffold_brief() {
  # The A and B proof: a brief produced by the REAL scaffold, no Budget line
  # anywhere, the budget arriving the way production delivers it - the
  # spawn-written budget= field. The gate must open, and the spine must print
  # the Definition-of-done section (the scaffold writes it with ONE hash).
  local rec home id out ledger learnings transcript
  rec=$(make_home spine-real)
  home=${rec%|*}; id=${rec#*|}
  make_real_scaffold_brief "$home" "$id" local-only
  grep -q 'Budget:' "$home/data/$id/brief.md" && fail "the real scaffold must not write a Budget line"
  grep -q '^# Definition of done' "$home/data/$id/brief.md" || fail "the real scaffold must write a one-hash Definition of done"
  printf 'budget=%s\n' "$FM_COMPACT_TRIGGER_TOKENS" > "$home/state/$id.meta"
  transcript="$TMP_ROOT/spine-real/transcript.jsonl"
  make_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  learnings="$home/data/learnings.md"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "first compaction must exit 0"
  assert_contains "$out" "Budget: $FM_COMPACT_TRIGGER_TOKENS tokens" 'needle missing'
  assert_contains "$out" 'Definition of done' 'needle missing'
  [ "$(printf '%s' "$out" | grep -c "Captain's intent")" = '0' ] \
    || fail "the spine must print from the Definition of done onward, not from the intent (the one-hash mismatch)"
  assert_contains "$out" 'Compactions so far: 1' 'compaction count must print in the spine'
  grep -q '^compacted 1 at 5000$' "$ledger" || fail "ledger file must gain 'compacted 1 at 5000' (derived from fixture usage rows), got: $(cat "$ledger")"
  [ "$(fm_compact_count_from_ledger "$ledger")" = '1' ] || fail "exactly one ledger line after the first compaction"
  assert_contains "$(cat "$learnings")" "$id"
  assert_contains "$(cat "$learnings")" '5000' 'needle missing'
  # The real scaffold brief carries no Budget line, so the budget came from the
  # machine record: the durable incident must not claim a briefing that never
  # happened, nor measure the peak against the trigger it compacted at.
  [ "$(grep -c "$FM_COMPACT_TRIGGER_TOKENS" "$learnings")" = '0' ] \
    || fail "the incident must not claim a briefed budget nobody wrote, got: $(cat "$learnings")"
  [ "$(grep -c 'briefed at' "$learnings")" = '0' ] || fail "no Budget line means no briefed-at claim"
  grep -q "compacted once (peak 5000 tokens)\.$" "$learnings" \
    || fail "the incident must read '<id> compacted once (peak <n> tokens).', got: $(cat "$learnings")"
  [ "$(grep -c "compacted once" "$learnings")" = '1' ] || fail "one incident line"
  assert_present "$home/state/.$id.compact-fire" "dedup marker must exist after a fire"
  [ ! -s "$home/state/.wake-queue" ] || fail "the first compaction must wake nobody"
  pass "real scaffold brief, meta budget: gate opens, DoD section prints, first compaction recorded, nobody woken"
}

test_spine_never_writes_the_status_log() {
  # The C proof: the status log is the wake channel and its last line is read
  # as current state, so the hook must not add a single byte to it.
  local rec home id transcript before
  rec=$(make_story spine-status '')
  home=${rec%|*}; id=${rec#*|}
  printf 'budget=120000\n' > "$home/state/$id.meta"
  transcript="$TMP_ROOT/spine-status/transcript.jsonl"
  make_transcript "$transcript"
  before=$(cat "$home/state/$id.status")
  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  [ "$(cat "$home/state/$id.status")" = "$before" ] || fail "a compaction must not write the status log, now: $(cat "$home/state/$id.status")"
  # Age the marker so the second fire is a new compaction, not the duplicate
  # settings-layer delivery the dedup exists to swallow. The harness also
  # writes the first compaction's boundary row into the transcript between
  # fires; simulate that, since the count reads it.
  printf '%s %s %s\n' "$(( $(date +%s) - 60 ))" 1 "$SPINE_SESSION" > "$home/state/.$id.compact-fire"
  printf '{"type":"system","subtype":"compact_boundary"}\n' | cat - "$transcript" > "$transcript.new" && mv "$transcript.new" "$transcript"
  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  [ "$(cat "$home/state/$id.status")" = "$before" ] || fail "even a second compaction must not write the status log"
  grep -q '^compacted 2 at ' "$home/state/$id.compactions" || fail "the second fire still appends to its own ledger"
  pass "the status log is untouched by every compaction; the ledger lives in its own file"
}

test_spine_second_compaction_signals_not_stops() {
  local rec home id out ledger transcript wake
  rec=$(make_story spine-second 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-second/transcript.jsonl"
  make_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  home_wake_state="$home/state"

  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  # Age the marker past the dedup window so this fire is a NEW compaction, not
  # the duplicate settings-layer fire of the first one. The harness writes the
  # first compaction's boundary row into the transcript between fires; the
  # count reads it.
  printf '%s %s %s\n' "$(( $(date +%s) - 60 ))" 1 "$SPINE_SESSION" > "$home/state/.$id.compact-fire"
  printf '{"type":"system","subtype":"compact_boundary"}\n' | cat - "$transcript" > "$transcript.new" && mv "$transcript.new" "$transcript"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "second compaction must exit 0"
  grep -q '^compacted 2 at ' "$ledger" || fail "second compaction must add a ledger line, ledger: $(cat "$ledger")"
  assert_contains "$out" 'carry straight on' 'needle missing'
  [ "$(printf '%s' "$out" | grep -c 'denied')" = '0' ] || fail "the worker must not be stopped or threatened"
  wake=$(wake_rows signal)
  [ -n "$wake" ] || fail "second compaction must enqueue a signal wake for the branch leader"
  assert_contains "$wake" "$id" 'needle missing'
  assert_contains "$wake" 'twice' 'needle missing'
  assert_contains "$wake" '5000' 'needle missing'
  assert_contains "$wake" '140000' 'needle missing'
  [ "$(grep -c "compacted once" "$home/data/learnings.md")" = '1' ] || fail "the incident line is written once, at the first compaction"
  pass "second compaction: signal wake carries worker, count, peak and budget; the worker carries on"
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
  [ ! -e "$home/state/$id.compactions" ] || fail "no budget must not append a ledger line"
  [ ! -e "$home/data/learnings.md" ] || fail "no budget must not write learnings"
  [ "$(cat "$st")" = 'working: brief accepted' ] || fail "no budget must not write the status log"
  pass "no budget anywhere: the whole hook is silent and writes nothing"
}

test_spine_brief_budget_line_overrides_meta() {
  # A hand-written brief Budget line is the human override of the machine
  # record: whoever wrote it chose the number the story is judged against.
  local rec home id out ledger transcript
  rec=$(make_story spine-override 'Budget: 20000 tokens')
  home=${rec%|*}; id=${rec#*|}
  printf 'budget=%s\n' "$FM_COMPACT_TRIGGER_TOKENS" > "$home/state/$id.meta"
  transcript="$TMP_ROOT/spine-override/transcript.jsonl"
  make_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  assert_contains "$out" 'Budget: 20000 tokens' 'needle missing'
  assert_contains "$(cat "$ledger")" 'at 5000' 'needle missing'
  pass "a hand-written brief Budget line overrides the spawn-written record"
}

test_spine_dedup_double_fire() {
  local rec home id out1 out2 ledger learnings transcript
  rec=$(make_story spine-dedup 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-dedup/transcript.jsonl"
  make_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  learnings="$home/data/learnings.md"
  out1=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  rc1=$?
  expect_code 0 "$rc1" "the first fire must exit 0"
  [ -n "$out1" ] || fail "the first fire must print the spine"
  out2=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  rc2=$?
  expect_code 0 "$rc2" "duplicate fire must exit 0"
  [ -z "$out2" ] || fail "duplicate fire must print nothing, got: $out2"
  [ "$(fm_compact_count_from_ledger "$ledger")" = '1' ] || fail "duplicate fire must not add a ledger line"
  [ "$(grep -c 'compacted once' "$learnings")" = '1' ] || fail "duplicate fire must not add an incident line"
  pass "the same event firing from two settings layers appends once"
}

test_spine_count_survives_a_pre_machinery_history() {
  # The count must be true for a session that compacted before the gate ever
  # opened: the transcript's boundaries, not the ledger's memory.
  local rec home id out ledger transcript wake
  rec=$(make_story spine-history 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  transcript="$TMP_ROOT/spine-history/transcript.jsonl"
  make_boundary_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  home_wake_state="$home/state"
  # The ledger is empty - this story's earlier compactions ran before the
  # machinery was installed, exactly the live case this rebuild fixes.
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "the fire must exit 0"
  grep -q '^compacted 3 at 8000$' "$ledger" \
    || fail "two transcript boundaries plus this fire must count 3 at the post-boundary peak, ledger: $(cat "$ledger")"
  wake=$(wake_rows signal)
  assert_contains "$wake" '3 times' 'needle missing'
  assert_contains "$out" '3 times' 'needle missing'
  pass "a story with unrecorded earlier compactions counts from the transcript and signals at the right count"
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
  [ ! -e "$home/state/${rec#*|}.compactions" ] || fail "non-compact source must not append"
  out=$(printf 'not json at all' | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "unparseable payload must exit 0"
  [ -z "$out" ] || fail "unparseable payload must be silent"
  pass "the hook answers only the compact source and never dies on bad input"
}

test_spine_derive_mode() {
  # No --home/--id: resolve the story from the payload cwd's fm/<id> branch and
  # the owning home from the git common dir, the shape of a firstmate-repo
  # worker whose worktree lives under ~/.treehouse.
  local rec home id out ledger transcript wt
  rec=$(make_story spine-derive 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  wt="$TMP_ROOT/spine-derive/wt"
  fm_git_worktree "$home" "$wt" "fm/$id"
  transcript="$TMP_ROOT/spine-derive/transcript.jsonl"
  make_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$wt" | "$ROOT/bin/fm-compact-spine.sh")
  expect_code 0 $? "derive mode must exit 0"
  grep -q '^compacted 1 at 5000$' "$ledger" || fail "derive mode must append the ledger line, ledger: $(cat "$ledger")"
  assert_contains "$out" 'Compactions so far: 1' 'compaction count must print in the spine'
  pass "shared-settings mode derives home and story from the worktree branch"
}

test_spine_missing_transcript_reads_zero_peak() {
  local rec home id out ledger
  rec=$(make_story spine-notranscript 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  ledger="$home/state/$id.compactions"
  out=$(compact_payload "$SPINE_SESSION" "$TMP_ROOT/spine-notranscript/nope.jsonl" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "missing transcript must exit 0"
  grep -q '^compacted 1 at 0$' "$ledger" || fail "missing transcript must ledger peak 0, got: $(cat "$ledger")"
  assert_contains "$out" 'transcript' 'needle missing'
  pass "a missing or lagging transcript compacts to peak 0 and says so"
}

test_spine_count_survives_a_relaunch() {
  # A relaunch starts a brand-new claude session, so the story's earlier
  # compactions are nowhere in the new transcript. The ledger is the story's
  # memory and must hold the count up: the third compaction of the story is
  # counted as the third and signals the branch leader, not a repeat first.
  local rec home id out ledger transcript wake
  rec=$(make_story spine-relaunch 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  ledger="$home/state/$id.compactions"
  home_wake_state="$home/state"
  printf 'compacted 1 at 118000\ncompacted 2 at 121000\n' > "$ledger"
  # The fresh session's transcript: readable, and with ZERO boundary rows.
  transcript="$TMP_ROOT/spine-relaunch/transcript.jsonl"
  mkdir -p "$(dirname "$transcript")"
  make_transcript "$transcript"
  [ "$(fm_compact_count_from_boundaries "$transcript")" = '0' ] || fail "the relaunched session's transcript must carry no boundaries"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "a relaunched worker's compaction must exit 0"
  grep -q '^compacted 3 at 5000$' "$ledger" \
    || fail "the ledger's two earlier fires plus this one must count 3, ledger: $(cat "$ledger")"
  assert_contains "$out" '3 times' 'needle missing'
  wake=$(wake_rows signal)
  [ -n "$wake" ] || fail "a relaunched worker's third compaction must still signal the branch leader"
  assert_contains "$wake" '3 times' 'needle missing'
  [ ! -e "$home/data/learnings.md" ] || fail "a third compaction must not write a fresh 'compacted once' incident: $(cat "$home/data/learnings.md")"
  pass "the count is the story's, not the session's: a relaunch still counts and signals"
}

test_spine_unparseable_transcript_falls_back_to_the_ledger() {
  # A half-written or corrupt transcript is unreadable, not a story that never
  # compacted: the ledger's memory is the count, so the signal still fires.
  local rec home id out ledger transcript wake
  rec=$(make_story spine-badjson 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  ledger="$home/state/$id.compactions"
  home_wake_state="$home/state"
  printf 'compacted 1 at 118000\ncompacted 2 at 121000\n' > "$ledger"
  transcript="$TMP_ROOT/spine-badjson/transcript.jsonl"
  mkdir -p "$(dirname "$transcript")"
  printf 'not json at all\n{"type":"system","subtype":"compact_bound\n' > "$transcript"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "an unparseable transcript must exit 0"
  grep -q '^compacted 3 at 0$' "$ledger" \
    || fail "an unparseable transcript must count from the ledger and peak 0, ledger: $(cat "$ledger")"
  wake=$(wake_rows signal)
  assert_contains "$wake" '3 times' 'needle missing'
  assert_contains "$out" 'carry straight on' 'needle missing'
  pass "an unparseable transcript falls back to the ledger instead of counting a first compaction"
}

test_spine_dedup_without_a_transcript() {
  # The live case: no readable transcript, so both settings-layer fires of ONE
  # compaction count from the ledger - which the first fire has already grown.
  # The same session inside the dedup window is the same event, whatever the
  # count says.
  local rec home id out1 out2 rc2 ledger learnings
  rec=$(make_story spine-dedup-notranscript 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  ledger="$home/state/$id.compactions"
  learnings="$home/data/learnings.md"
  home_wake_state="$home/state"

  out1=$(compact_payload "$SPINE_SESSION" "$TMP_ROOT/spine-dedup-notranscript/nope.jsonl" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  [ -n "$out1" ] || fail "the first fire must print the spine"
  grep -q '^compacted 1 at 0$' "$ledger" || fail "the first fire must ledger the compaction, ledger: $(cat "$ledger")"

  out2=$(compact_payload "$SPINE_SESSION" "$TMP_ROOT/spine-dedup-notranscript/nope.jsonl" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  rc2=$?
  expect_code 0 "$rc2" "the duplicate fire must exit 0"
  [ -z "$out2" ] || fail "the duplicate fire must print nothing, got: $out2"
  [ "$(fm_compact_count_from_ledger "$ledger")" = '1' ] || fail "one compaction must be one ledger line, ledger: $(cat "$ledger")"
  [ "$(grep -c 'compacted once' "$learnings")" = '1' ] || fail "one compaction must be one incident line"
  [ -z "$(wake_rows signal)" ] || fail "a single compaction must never signal the branch leader"
  pass "with no readable transcript, one compaction firing twice is still one compaction"
}

test_spine_count_never_regresses_below_the_ledger() {
  # The ledger's FIRST line can already read `compacted 3`: a story whose
  # earlier trims were counted from a transcript records the number, not one
  # line per fire it happened to witness. The next fire must be the fourth.
  local rec home id out ledger transcript wake
  rec=$(make_story spine-monotonic 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  ledger="$home/state/$id.compactions"
  home_wake_state="$home/state"
  printf 'compacted 3 at 8000\n' > "$ledger"
  transcript="$TMP_ROOT/spine-monotonic/transcript.jsonl"
  mkdir -p "$(dirname "$transcript")"
  make_transcript "$transcript"

  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id")
  expect_code 0 $? "the fire must exit 0"
  grep -q '^compacted 4 at 5000$' "$ledger" \
    || fail "the count must never drop below what the ledger already recorded, ledger: $(cat "$ledger")"
  wake=$(wake_rows signal)
  assert_contains "$wake" '4 times' 'needle missing'
  assert_contains "$out" '4 times' 'needle missing'
  [ ! -e "$home/data/learnings.md" ] || fail "a fourth compaction must not write a first-compaction incident"
  pass "the story count is monotonic: it never reports less history than the ledger holds"
}

test_spine_dedup_survives_a_slow_transcript_read() {
  # The live shape of the duplicate fire: the two settings layers deliver the
  # SAME compaction seconds apart, and the transcript at the trigger is big
  # enough that reading it is itself slow. The dedup window is measured from
  # when the append finished, so the second delivery is still swallowed.
  local rec home id transcript fakedir realjq ledger learnings
  rec=$(make_story spine-slowread 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  ledger="$home/state/$id.compactions"
  learnings="$home/data/learnings.md"
  home_wake_state="$home/state"
  transcript="$TMP_ROOT/spine-slowread/transcript.jsonl"
  mkdir -p "$(dirname "$transcript")"
  make_transcript "$transcript"
  realjq=$(command -v jq) || fail "jq must be installed to run this suite"
  fakedir="$TMP_ROOT/spine-slowread/bin"
  mkdir -p "$fakedir"
  # Stand in for the multi-megabyte transcript a worker carries at the
  # trigger: every read of THIS file costs seconds.
  cat > "$fakedir/jq" <<EOF
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "$transcript" ]; then sleep 2; fi
done
exec "$realjq" "\$@"
EOF
  chmod +x "$fakedir/jq"

  compact_payload "$SPINE_SESSION" "$transcript" "$home" \
    | PATH="$fakedir:$PATH" FM_COMPACT_DEDUP_WINDOW=3 "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  compact_payload "$SPINE_SESSION" "$transcript" "$home" \
    | PATH="$fakedir:$PATH" FM_COMPACT_DEDUP_WINDOW=3 "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null

  [ "$(grep -c '^compacted ' "$ledger")" = '1' ] \
    || fail "a slow transcript read must not age the marker out of the dedup window, ledger: $(cat "$ledger")"
  [ "$(grep -c 'compacted once' "$learnings")" = '1' ] || fail "one compaction is one incident line"
  [ -z "$(wake_rows signal)" ] || fail "a first compaction delivered twice must never signal the branch leader"
  pass "the dedup window is measured from the append, so a slow transcript read cannot double-count"
}

test_spine_incident_names_a_budget_only_when_a_human_wrote_one() {
  # The brief's own Budget line is a human's number, so the durable incident
  # may name it. (The machine-record path is proven on the real scaffold
  # brief, where the incident claims no budget at all.)
  local rec home id transcript learnings
  rec=$(make_story spine-briefed 'Budget: 140K')
  home=${rec%|*}; id=${rec#*|}
  learnings="$home/data/learnings.md"
  transcript="$TMP_ROOT/spine-briefed/transcript.jsonl"
  mkdir -p "$(dirname "$transcript")"
  make_transcript "$transcript"
  compact_payload "$SPINE_SESSION" "$transcript" "$home" | "$ROOT/bin/fm-compact-spine.sh" --home "$home" --id "$id" >/dev/null
  grep -q "compacted once (peak 5000 tokens) on a story briefed at 140000 tokens\.$" "$learnings" \
    || fail "a hand-written Budget line must be named in the incident, got: $(cat "$learnings")"
  pass "the incident names a briefed budget exactly when the brief carried one"
}

# --- spawn wiring -------------------------------------------------------------

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  make_real_scaffold_brief "$home" "$id" no-mistakes
  printf '%s|%s|%s|%s' "$home" "$wt" "$fakebin" "$proj"
}

test_spawn_writes_window_meta_and_spine_only() {
  local rec home wt fakebin proj id='wired-1' settings out cmd ledger transcript
  rec=$(make_spawn_case spawn-wiring "$id")
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
  local spine_cmd
  spine_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")
  printf '%s' "$spine_cmd" | grep -q 'fm-compact-spine.sh' || fail "SessionStart command must invoke fm-compact-spine.sh"
  printf '%s' "$spine_cmd" | grep -q -- '--home' || fail "SessionStart command must carry an explicit home"
  printf '%s' "$spine_cmd" | grep -q -- "--id '$id'" || fail "SessionStart command must carry the task id"
  if jq -e '.hooks.PreToolUse' "$settings" >/dev/null 2>&1; then
    fail "the deny hook is withdrawn: spawn settings must carry no PreToolUse entry"
  fi

  # The gate key: the task record carries the measured trigger as budget=,
  # written by the spawn itself (A: the gate no longer depends on a brief line
  # nobody writes).
  [ "$(fm_compact_budget_from_meta "$home/state/$id.meta")" = "$FM_COMPACT_TRIGGER_TOKENS" ] \
    || fail "claude spawn meta must carry budget=$FM_COMPACT_TRIGGER_TOKENS, got: $(cat "$home/state/$id.meta")"

  # Drive the generated SessionStart command end to end: the wiring must work,
  # not merely exist. The real scaffold brief carries no Budget line, so a
  # firing hook here proves the meta path opens the gate on a real brief.
  transcript="$TMP_ROOT/spawn-wiring/transcript.jsonl"
  make_transcript "$transcript"
  ledger="$home/state/$id.compactions"
  cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")
  out=$(compact_payload "$SPINE_SESSION" "$transcript" "$wt" | sh -c "$cmd")
  expect_code 0 $? "generated SessionStart command must run: $out"
  grep -q '^compacted 1 at 5000$' "$ledger" || fail "driven spawn hook must ledger the compaction, ledger: $(cat "$ledger")"
  assert_contains "$out" 'Compactions so far: 1' 'compaction count must print in the spine'
  assert_contains "$out" 'Definition of done' 'needle missing'
  [ ! -e "$home/state/$id.status" ] || fail "the driven hook must not write the status log, got: $(cat "$home/state/$id.status")"
  pass "spawn writes window, budget= meta, and the spine hook only; the generated hook runs on a real scaffold brief"
}

test_spawn_refuses_a_nonnumeric_window() {
  # The window is environment-overridable and is written verbatim into the
  # worker's settings.local.json. A junk value must stop the spawn, never
  # produce a settings file the harness cannot parse (which would disable
  # every hook in that worker) nor a negative budget in the task record.
  local rec home wt fakebin proj rest id='wired-bad' out rc
  rec=$(make_spawn_case spawn-badwindow "$id")
  home=${rec%%|*}; rest=${rec#*|}; wt=${rest%%|*}; rest=${rest#*|}; fakebin=${rest%%|*}; proj=${rest#*|}

  out=$(FM_COMPACT_WINDOW_TOKENS=not-a-number GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a non-numeric window must refuse the spawn, output: $out"
  assert_contains "$out" 'FM_COMPACT_WINDOW_TOKENS' 'the refusal must name the setting at fault'
  [ ! -e "$wt/.claude/settings.local.json" ] || fail "a refused spawn must write no settings: $(cat "$wt/.claude/settings.local.json")"
  grep -q '^budget=' "$home/state/$id.meta" 2>/dev/null && fail "a refused spawn must write no budget= record"
  pass "a junk compaction window refuses the spawn instead of writing broken settings"
}

test_shared_settings_compact_entry_runs() {
  # Drive the tracked shared-settings entry's command rather than grepping
  # its bytes: a command that no longer runs must fail here, not in a worker.
  local cmd out payload_dir
  cmd=$(jq -r '.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] && [ "$cmd" != 'null' ] || fail "shared .claude/settings.json must carry a SessionStart compact command"
  payload_dir=$(mktemp -d "$TMP_ROOT/shared-cwd.XXXXXX")
  (cd "$payload_dir" && git init -q && git checkout -q -b fm/shared-test 2>/dev/null || true)
  # Outside a firstmate-repo worktree the derive must stay silent: it is the
  # wrong home for this story, and silence is the contract. CLAUDE_PROJECT_DIR
  # is what the harness itself sets when the command runs.
  out=$(compact_payload "$SPINE_SESSION" "$TMP_ROOT/shared/nope.jsonl" "$payload_dir" | CLAUDE_PROJECT_DIR="$ROOT" sh -c "$cmd")
  expect_code 0 $? "the shared-settings command must run"
  [ -z "$out" ] || fail "a cwd outside a firstmate home must stay silent, got: $out"
  pass "the tracked settings carry the compact hook and its command runs, silent off-home"
}

test_scripts_are_shellcheck_clean() {
  "$ROOT/bin/fm-lint.sh" >/dev/null 2>&1 || fail "fm-lint.sh failed"
  pass "all scripts pass the repo lint"
}

# --- run ----------------------------------------------------------------------
test_budget_parser
test_meta_budget_parser
test_decision_matrix
test_signal_message_is_one_short_line
test_ledger_parsers
test_boundary_count_and_peak
test_spine_first_compaction_on_real_scaffold_brief
test_spine_never_writes_the_status_log
test_spine_second_compaction_signals_not_stops
test_spine_silent_without_budget
test_spine_brief_budget_line_overrides_meta
test_spine_dedup_double_fire
test_spine_count_survives_a_pre_machinery_history
test_spine_ignores_other_sources
test_spine_derive_mode
test_spine_missing_transcript_reads_zero_peak
test_spine_count_survives_a_relaunch
test_spine_unparseable_transcript_falls_back_to_the_ledger
test_spine_dedup_without_a_transcript
test_spine_count_never_regresses_below_the_ledger
test_spine_dedup_survives_a_slow_transcript_read
test_spine_incident_names_a_budget_only_when_a_human_wrote_one
test_spawn_writes_window_meta_and_spine_only
test_spawn_refuses_a_nonnumeric_window
test_shared_settings_compact_entry_runs
test_scripts_are_shellcheck_clean
echo "all token-budget tests passed"
