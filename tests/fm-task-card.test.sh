#!/usr/bin/env bash
# tests/fm-task-card.test.sh - the crewmate's own task card, reprinted when a
# trimmed session resumes.
#
# bin/fm-task-card.sh runs from a claude SessionStart hook with the matcher
# compact. It prints, verbatim and in order, the brief's Captain's intent and
# Definition of done sections, the logbook, the count of unread steering-inbox
# records with the line that drains them, and the last status line; each
# section is cut at a fixed size with a note naming the file, the whole card
# stays under FM_TASK_CARD_MAX characters, a missing input is named, and the
# card's own words never mention the machinery. Any other payload prints
# nothing. The spawn installs it for every claude crewmate and leader, never
# for codex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CARD="$ROOT/bin/fm-task-card.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-card)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

MACHINERY_WORDS='trim|compact|context window|token|budget|ledger|telemetry|autoCompact|head size|summary|memory'

payload() {  # <source> [extra json]
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"s-9","transcript_path":"/t/s-9.jsonl","cwd":"/w"%s}' "$1" "${2:-}"
}

make_home() {  # <name>: sets HOME_DIR
  HOME_DIR="$TMP_ROOT/$1/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
}

write_brief() {  # <home> <id> [intent-body]
  local intent=${3:-$'Build the thing.\n\nAcceptance:\n1. The guard turns red first.\n2. The card quotes this line: ORCHID-2291.'}
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Use the library; do not add a wrapper.

# Setup
Run bin/setup.sh once.

# Rules
Never push to origin.

# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
Append \`done: {summary}\` to the status file and stop.
EOF
}

write_logbook() {  # <home> <id>
  cat > "$1/data/$2/logbook.md" <<EOF
# Logbook: $2

## Done
- The first test is red.

## Next
- Make it green without the wrapper.

## Open

## Decisions
- No wrapper.
EOF
}

write_inbox() {  # <home> <id> <n-unread> <n-handled>
  local i
  mkdir -p "$1/state/$2.inbox/handled"
  i=0
  while [ "$i" -lt "$3" ]; do i=$((i + 1)); printf 'schema=fm-task-inbox.v1\nat=now\n--\nsteer %s\n' "$i" > "$1/state/$2.inbox/00$i.msg"; done
  i=0
  while [ "$i" -lt "$4" ]; do i=$((i + 1)); printf 'schema=fm-task-inbox.v1\nat=then\n--\nold %s\n' "$i" > "$1/state/$2.inbox/handled/09$i.msg"; done
}

run_card() {  # <home> <id> <payload> [env...]: sets RC, OUT
  local home=$1 id=$2 body=$3
  shift 3
  OUT=$(printf '%s' "$body" | env "$@" "$CARD" "$home" "$id" 2>"$home/card.err"); RC=$?
}

# --- 1. the card, verbatim and in order ---------------------------------------
test_prints_the_card_for_a_resumed_session() {
  local home expected
  make_home card; home=$HOME_DIR
  write_brief "$home" c1
  write_logbook "$home" c1
  write_inbox "$home" c1 2 1
  printf 'working: started\nblocked: need the token\nworking: unblocked, on the guard\n' > "$home/state/c1.status"
  run_card "$home" c1 "$(payload compact)"
  [ "$RC" -eq 0 ] || fail "the card must exit 0 (got $RC)"$'\n'"$(cat "$home/card.err")"
  expected="# Task c1: where things stand

## What was asked, from your brief ($home/data/c1/brief.md)
Build the thing.

Acceptance:
1. The guard turns red first.
2. The card quotes this line: ORCHID-2291.

## Definition of done, from your brief
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
Append \`done: {summary}\` to the status file and stop.

## Your logbook ($home/data/c1/logbook.md)
# Logbook: c1

## Done
- The first test is red.

## Next
- Make it green without the wrapper.

## Open

## Decisions
- No wrapper.

## Instructions waiting
2 unread: list $home/state/c1.inbox/*.msg and, in numeric order, read and act on each, then mv each handled file to $home/state/c1.inbox/handled/.

## Your last status line
working: unblocked, on the guard"
  [ "$OUT" = "$expected" ] || fail "the card differs from the expected text:"$'\n'"$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$OUT"))"
  pass "a compact SessionStart payload prints the card: intent and definition of done verbatim (Firstmate spec, Setup and Rules left out), the logbook, two unread instructions with the drain line, the last status line"
}

# --- 2. any other payload prints nothing --------------------------------------
test_prints_nothing_for_any_other_payload() {
  local home src bad
  make_home other; home=$HOME_DIR
  write_brief "$home" c1
  for src in startup resume clear fork; do
    run_card "$home" c1 "$(payload "$src")"
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "source $src must print nothing and exit 0 (got $RC):"$'\n'"$OUT"
  done
  for bad in 'garbage' '' '[]' '{"hook_event_name":"PostCompact","trigger":"auto"}' '{"hook_event_name":"SessionStart"}' \
    "$(payload compact ',"agent_id":"a-7"')"; do
    run_card "$home" c1 "$bad"
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "payload '$bad' must print nothing and exit 0 (got $RC):"$'\n'"$OUT"
  done
  OUT=$("$CARD" 2>&1); [ $? -eq 2 ] || fail "running it by hand without arguments is refused"
  assert_contains "$OUT" "usage:" "the refusal prints usage"
  OUT=$("$CARD" --help) || fail "--help must exit 0"
  assert_contains "$OUT" "SessionStart" "--help prints the header"
  pass "startup, resume, clear and fork sources, non-JSON, empty, an array, another event, no source, and a subagent all print nothing and exit 0"
}

# --- 3. cut at a fixed size, whole card bounded --------------------------------
test_sections_are_cut_and_the_card_is_bounded() {
  local home long i
  make_home bounded; home=$HOME_DIR
  long=""
  for i in $(seq 1 400); do long="$long$(printf 'Criterion %03d: the guard for case %03d turns red first.\n' "$i" "$i")"; done
  write_brief "$home" c1 "$long"
  { for i in $(seq 1 200); do printf -- '- done item %03d with a long enough sentence to fill the line\n' "$i"; done; } > "$home/data/c1/logbook.md"
  run_card "$home" c1 "$(payload compact)"
  [ "$RC" -eq 0 ] || fail "exit 0 (got $RC)"
  assert_contains "$OUT" "Criterion 001:" "the intent starts verbatim"
  assert_contains "$OUT" "(cut at 3000 characters; the rest is in $home/data/c1/brief.md)" "the intent is cut at 3000 characters with the file named"
  case "$OUT" in *"Criterion 400:"*) fail "a 20,000-character intent must not be printed whole" ;; esac
  assert_contains "$OUT" "(cut at 2000 characters; the rest is in $home/data/c1/logbook.md)" "the logbook is cut at 2000 characters with the file named"
  [ "${#OUT}" -le 8000 ] || fail "the whole card must stay under 8000 characters, got ${#OUT}"
  assert_contains "$OUT" "## Your last status line" "every section is still present after the cuts"
  pass "a 20,000-character intent and a 200-line logbook are cut at 3000 and 2000 characters with the file named, and the whole card stays under 8000 characters"
}

# --- 4. the card's own words never mention the machinery ----------------------
test_a_comment_inside_a_code_fence_does_not_end_a_section() {
  local home
  make_home fence; home=$HOME_DIR
  write_brief "$home" c1 $'Run the guard:\n\n```sh\n# run this first\nbin/guard.sh\n```\n\nAcceptance:\n1. The card quotes the line after the fence: LOTUS-7741.'
  run_card "$home" c1 "$(payload compact)"
  [ "$RC" -eq 0 ] || fail "the card must exit 0 (got $RC)"$'\n'"$(cat "$home/card.err")"
  assert_contains "$OUT" "# run this first" "the fenced comment line is printed as part of the intent"
  assert_contains "$OUT" "LOTUS-7741" "the acceptance line after the fence is on the card"
  assert_not_contains "$OUT" "Use the library; do not add a wrapper." "the intent still ends at the next real heading"
  assert_contains "$OUT" "## Definition of done, from your brief" "the definition of done still follows"
  pass "a '#' line inside a fenced code block is code, not a heading: the intent runs past it to the next real heading"
}

test_framing_never_mentions_the_machinery() {
  local home framing
  make_home words; home=$HOME_DIR
  mkdir -p "$home/data/c1"
  printf '# Task\n## Captain'"'"'s intent\nPlain ask.\n\n# Definition of done\nPlain done.\n' > "$home/data/c1/brief.md"
  printf '# Logbook: c1\n\n## Done\n\n## Next\n\n## Open\n\n## Decisions\n' > "$home/data/c1/logbook.md"
  write_inbox "$home" c1 1 0
  printf 'working: plain\n' > "$home/state/c1.status"
  run_card "$home" c1 "$(payload compact)"
  framing=$(printf '%s\n' "$OUT" | sed "s#$home#<home>#g")
  printf '%s\n' "$framing" | grep -q -i -E "$MACHINERY_WORDS" \
    && fail "the card's own words must not mention the machinery, got: $(printf '%s\n' "$framing" | grep -i -E "$MACHINERY_WORDS")"
  case "$framing" in
    *resum*|*"picking up"*|*"where you left"*) fail "the card must not say why it is shown:"$'\n'"$framing" ;;
  esac
  pass "the card's own words never say trim, compact, context window, token, budget, memory, summary, or why the card is shown"
}

# --- 5. missing inputs are named, never invented ------------------------------
test_missing_inputs_are_named() {
  local home
  make_home missing; home=$HOME_DIR
  mkdir -p "$home/data/c1"
  run_card "$home" c1 "$(payload compact)"
  [ "$RC" -eq 0 ] || fail "exit 0 with nothing on disk (got $RC)"
  assert_contains "$OUT" "No brief at $home/data/c1/brief.md." "a missing brief is named"
  assert_contains "$OUT" "No logbook yet at $home/data/c1/logbook.md." "a missing logbook is named"
  assert_contains "$OUT" $'## Instructions waiting\nNone.' "no inbox means none waiting"
  assert_contains "$OUT" $'## Your last status line\nNone yet.' "no status line yet is said so"
  # A brief with neither section: read it whole.
  printf '# Task\nLegacy body.\n' > "$home/data/c1/brief.md"
  run_card "$home" c1 "$(payload compact)"
  assert_contains "$OUT" "carries no Captain's intent or Definition of done section; read it whole." "a legacy brief is pointed at, not guessed"
  # Handled records do not count as waiting.
  write_inbox "$home" c1 0 3
  run_card "$home" c1 "$(payload compact)"
  assert_contains "$OUT" $'## Instructions waiting\nNone.' "handled records are not waiting"
  pass "a missing brief, logbook, inbox or status line is named as missing; a legacy brief is pointed at; handled records do not count"
}

# --- 6. the spawn installs the hook -------------------------------------------
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse codex
  printf '%s\n' "$fakebin"
}

make_spawn_home() {  # <name> -> "<home>|<proj>|<fakebin>"
  local base="$TMP_ROOT/$1" home proj fakebin
  home="$base/home"
  proj="$base/project"
  fakebin=$(make_fakebin "$base")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  printf '%s|%s|%s\n' "$home" "$proj" "$fakebin"
}

run_spawn() {  # <home> <proj> <fakebin> <id> [args...]
  local home=$1 proj=$2 fakebin=$3 id=$4 wt
  shift 4
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the task-card wiring for $id: ORCHID-2291.

## Firstmate spec
Verify the spawn installs the SessionStart compact hook.
EOF
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

compact_command() {  # <worktree>
  jq -r '.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command' "$1/.claude/settings.local.json"
}

test_spawn_installs_the_hook_for_every_claude_crewmate_and_leader() {
  local home proj fakebin out status wt cmd hookout
  IFS='|' read -r home proj fakebin <<EOF
$(make_spawn_home wiring)
EOF
  out=$(run_spawn "$home" "$proj" "$fakebin" k1); status=$?
  [ "$status" -eq 0 ] || fail "claude spawn must succeed (exit $status)"$'\n'"$out"
  wt="$proj.wt-k1"
  [ "$(jq -r '[.hooks.SessionStart[] | select(.matcher == "compact")] | length' "$wt/.claude/settings.local.json")" = 1 ] \
    || fail "exactly one SessionStart entry with the matcher compact"
  [ "$(jq -r '[.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|fork")] | length' "$wt/.claude/settings.local.json")" = 1 ] \
    || fail "the session-record entry stays as it was"
  cmd=$(compact_command "$wt")
  assert_contains "$cmd" "fm-task-card.sh" "the compact entry runs the task-card script"
  assert_contains "$cmd" " 'k1' " "the hook names the task"
  # The installed command, run as the harness runs it, prints the card.
  hookout=$(payload compact | bash -c "$cmd"); status=$?
  [ "$status" -eq 0 ] || fail "the installed command must exit 0 (got $status)"
  assert_contains "$hookout" "# Task k1: where things stand" "the installed command prints the card"
  assert_contains "$hookout" "ORCHID-2291" "the card carries the brief's intent"
  assert_contains "$hookout" "## Your logbook ($home/data/k1/logbook.md)" "the card reads the logbook the spawn created"
  assert_contains "$hookout" "## Done" "the logbook the spawn created is printed"
  hookout=$(payload startup | bash -c "$cmd"); status=$?
  [ "$status" -eq 0 ] && [ -z "$hookout" ] || fail "the installed command prints nothing for a startup payload"
  # A leader gets the same hook.
  out=$(run_spawn "$home" "$proj" "$fakebin" k2 --leads); status=$?
  [ "$status" -eq 0 ] || fail "leader spawn must succeed (exit $status)"$'\n'"$out"
  cmd=$(compact_command "$proj.wt-k2")
  assert_contains "$cmd" "fm-task-card.sh" "a leader's worktree carries the task-card hook too"
  # A harness without hooks of this kind gets nothing.
  out=$(run_spawn "$home" "$proj" "$fakebin" k3 --harness codex); status=$?
  [ "$status" -eq 0 ] || fail "codex spawn must succeed (exit $status)"$'\n'"$out"
  [ ! -e "$proj.wt-k3/.claude/settings.local.json" ] || fail "a codex spawn writes no claude settings"
  pass "the spawn installs SessionStart compact running the task-card script with the home and the id for a claude crewmate and a leader, never for codex; the installed command prints the card for a compact payload and nothing for startup"
}

test_prints_the_card_for_a_resumed_session
test_prints_nothing_for_any_other_payload
test_sections_are_cut_and_the_card_is_bounded
test_a_comment_inside_a_code_fence_does_not_end_a_section
test_framing_never_mentions_the_machinery
test_missing_inputs_are_named
test_spawn_installs_the_hook_for_every_claude_crewmate_and_leader

echo "# all fm-task-card tests passed"
