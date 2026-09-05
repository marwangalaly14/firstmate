#!/usr/bin/env bash
# tests/fm-logbook.test.sh - the crewmate's logbook.
#
# bin/fm-logbook-lib.sh owns data/<id>/logbook.md: its path, its four-heading
# template, and an init that creates it once and never touches it again.
# bin/fm-spawn.sh creates it at every ship or scout launch, fresh or relaunch,
# for story crewmates and leaders on any harness, never for a secondmate;
# bin/fm-brief.sh names it in a four-line section of every ship and scout
# scaffold that asks the crewmate for no number, and the definition of done
# never mentions it. The spawn cases run against fake tmux panes and real
# isolated git worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-logbook-lib.sh
. "$ROOT/bin/fm-logbook-lib.sh"

BRIEF_SH="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-logbook)

# Words that would ask the crewmate to count or watch its own head. The
# scaffold never says them: the number is the fleet's to measure.
MACHINERY_WORDS='trim|compact|context window|token|budget|ledger|telemetry|autoCompact|head size'

assert_template() {  # <file> <id> <label>
  local file=$1 id=$2 label=$3
  [ "$(cat "$file")" = "$(fm_logbook_template "$id")" ] || fail "$label: $file must be the template, got:"$'\n'"$(cat "$file")"
}

# --- the library ------------------------------------------------------------

test_template_has_the_four_headings_and_no_number_to_report() {
  local tpl lines
  tpl=$(fm_logbook_template x1)
  for h in '## Done' '## Next' '## Open' '## Decisions'; do
    [ "$(printf '%s\n' "$tpl" | grep -c -x "$h")" -eq 1 ] || fail "the template must carry exactly one '$h' heading"
  done
  assert_contains "$tpl" "# Logbook: x1" "the template is titled with the task id"
  assert_contains "$tpl" "Nobody reads it to count anything" "the template says nobody counts from it"
  lines=$(printf '%s\n' "$tpl" | wc -l | tr -d ' ')
  [ "$lines" -lt 40 ] || fail "the template must leave room under 40 lines, has $lines"
  printf '%s\n' "$tpl" | grep -q -i -E "$MACHINERY_WORDS" && fail "the template must not mention the machinery, got: $(printf '%s\n' "$tpl" | grep -i -E "$MACHINERY_WORDS")"
  [ "$(fm_logbook_path /d t9)" = "/d/t9/logbook.md" ] || fail "the path is <data>/<id>/logbook.md"
  pass "the template is titled with the id, carries Done/Next/Open/Decisions once each, says nobody counts from it, and names no machinery"
}

test_init_creates_once_and_never_overwrites() {
  local data="$TMP_ROOT/lib/data" file
  mkdir -p "$data"
  file=$(fm_logbook_path "$data" a1)
  fm_logbook_init "$data" a1 || fail "init must succeed when the file is absent"
  assert_template "$file" a1 "first init"
  printf '# Logbook: a1\n\n## Done\n- the crewmate wrote this\n' > "$file"
  fm_logbook_init "$data" a1 || fail "a second init must succeed"
  [ "$(cat "$file")" = "$(printf '# Logbook: a1\n\n## Done\n- the crewmate wrote this')" ] || fail "a second init must leave the crewmate's text untouched"
  [ -z "$(ls "$data/a1" | grep -v '^logbook.md$')" ] || fail "init leaves no temp file behind, got: $(ls "$data/a1")"
  fm_logbook_init "$data" "" 2>/dev/null && fail "init without an id must refuse"
  fm_logbook_init "" a1 2>/dev/null && fail "init without a data dir must refuse"
  pass "init writes the template once, keeps what the crewmate wrote on every later call, and refuses without its two arguments"
}

# --- the scaffold -----------------------------------------------------------

scaffold_home() {  # <name> -> home
  local home="$TMP_ROOT/brief-$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

test_ship_and_scout_briefs_name_the_logbook_and_ask_for_no_number() {
  local home brief section dod
  home=$(scaffold_home crew)
  for spec in 's1:--mode no-mistakes' 's2:--mode direct-PR' 's3:--mode local-only' 's4:--scout'; do
    id=${spec%%:*}
    # shellcheck disable=SC2086 # the flags are a deliberate word list
    FM_HOME="$home" "$BRIEF_SH" "$id" demo ${spec#*:} >/dev/null || fail "$id: scaffold must succeed"
    brief="$home/data/$id/brief.md"
    [ "$(grep -c -x '# Your logbook' "$brief")" -eq 1 ] || fail "$id: exactly one '# Your logbook' section"
    section=$(sed -n '/^# Your logbook$/,/^$/p' "$brief")
    assert_contains "$section" "$(fm_logbook_path "$home/data" "$id")" "$id: the section names the logbook path"
    assert_contains "$section" "Done, Next, Open, Decisions" "$id: the section names the four headings"
    assert_contains "$section" "nobody reads it to count anything" "$id: the section says nobody counts from it"
    [ "$(printf '%s\n' "$section" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 4 ] || fail "$id: the section is four lines, got:"$'\n'"$section"
    # The home's own path is masked first: this test's temp root carries the word.
    dod=$(sed -n '/^# Definition of done$/,$p' "$brief" | sed "s#$home#<home>#g")
    printf '%s\n' "$dod" | grep -q -i 'logbook' && fail "$id: the definition of done must not mention the logbook"
    sed "s#$home#<home>#g" "$brief" | grep -q -i -E "$MACHINERY_WORDS" && fail "$id: the brief asks the crewmate about the machinery: $(grep -n -i -E "$MACHINERY_WORDS" "$brief")"
  done
  FM_HOME="$home" "$BRIEF_SH" s5 --secondmate demo >/dev/null || fail "secondmate scaffold must succeed"
  sed "s#$home#<home>#g" "$home/data/s5/brief.md" | grep -q -i 'logbook' && fail "a secondmate charter names no logbook; it has a whole home"
  pass "every ship mode and the scout scaffold carry the four-line logbook section naming the path, the definition of done never mentions it, no brief names the machinery, and a charter has none"
}

# --- the spawn --------------------------------------------------------------

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
  *cursor_y*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' "${FM_FAKE_WINDOWS:-}"; exit 0 ;;
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

make_home() {  # <name> -> "<home>|<proj>|<fakebin>"
  local name=$1 base home proj fakebin
  base="$TMP_ROOT/$name"
  home="$base/home"
  proj="$base/project"
  fakebin=$(make_fakebin "$base/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  printf '%s|%s|%s\n' "$home" "$proj" "$fakebin"
}

read_home() {
  IFS='|' read -r HOME_DIR PROJ_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Exercise the logbook for $2.

## Firstmate spec
Verify the spawn creates the logbook once.
EOF
}

spawn_env() {  # <home> <pane-path> <cmd...>
  local home=$1 pane=$2
  shift 2
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-zsh}" FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" \
    PATH="$FAKEBIN_DIR:$PATH" "$@" 2>&1
}

run_spawn() {  # <home> <proj> <id> [args...]
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  write_brief "$home" "$id"
  spawn_env "$home" "$wt" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@"
}

run_relaunch() {  # <home> <proj> <id> [args...]
  local home=$1 proj=$2 id=$3
  shift 3
  FM_FAKE_WINDOWS="fm-$id" spawn_env "$home" "$proj.wt-$id" "$SPAWN" "$id" --relaunch "$@"
}

test_spawn_creates_the_logbook_for_crewmates_and_leaders_and_keeps_it_on_relaunch() {
  local rec out status file
  rec=$(make_home spawn)
  read_home "$rec"
  # A story crewmate on claude.
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1); status=$?
  [ "$status" -eq 0 ] || fail "claude spawn must succeed (exit $status)"$'\n'"$out"
  file=$(fm_logbook_path "$HOME_DIR/data" c1)
  [ -f "$file" ] || fail "the spawn must create $file"
  assert_template "$file" c1 "crewmate"
  # A leader: the same file.
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" L1 --leads); status=$?
  [ "$status" -eq 0 ] || fail "leader spawn must succeed (exit $status)"$'\n'"$out"
  assert_template "$(fm_logbook_path "$HOME_DIR/data" L1)" L1 "leader"
  # Another harness: the logbook is not a claude thing.
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c2 --harness codex); status=$?
  [ "$status" -eq 0 ] || fail "codex spawn must succeed (exit $status)"$'\n'"$out"
  assert_template "$(fm_logbook_path "$HOME_DIR/data" c2)" c2 "codex crewmate"
  # A relaunch keeps what the crewmate wrote.
  printf '# Logbook: c1\n\n## Done\n- half the story\n\n## Next\n- the other half\n' > "$file"
  out=$(run_relaunch "$HOME_DIR" "$PROJ_DIR" c1); status=$?
  [ "$status" -eq 0 ] || fail "relaunch must succeed (exit $status)"$'\n'"$out"
  assert_contains "$(cat "$file")" "half the story" "a relaunch keeps the crewmate's logbook"
  [ "$(grep -c -x '## Done' "$file")" -eq 1 ] || fail "a relaunch must not append a second template"
  # A relaunch of a task recorded before this story gets the file.
  rm -f "$(fm_logbook_path "$HOME_DIR/data" c2)"
  out=$(run_relaunch "$HOME_DIR" "$PROJ_DIR" c2); status=$?
  [ "$status" -eq 0 ] || fail "relaunch of an older task must succeed (exit $status)"$'\n'"$out"
  assert_template "$(fm_logbook_path "$HOME_DIR/data" c2)" c2 "older task relaunched"
  pass "the spawn creates the logbook for a claude crewmate, a leader and a codex crewmate, and a relaunch keeps a written one and supplies a missing one"
}

test_template_has_the_four_headings_and_no_number_to_report
test_init_creates_once_and_never_overwrites
test_ship_and_scout_briefs_name_the_logbook_and_ask_for_no_number
test_spawn_creates_the_logbook_for_crewmates_and_leaders_and_keeps_it_on_relaunch

echo "# all fm-logbook tests passed"
