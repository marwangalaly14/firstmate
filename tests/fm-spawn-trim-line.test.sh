#!/usr/bin/env bash
# tests/fm-spawn-trim-line.test.sh - the 140K line at spawn time.
#
# A claude story crewmate's worktree .claude/settings.local.json carries the
# one settings key that moves the harness's automatic trim to the captain's
# 140K line (bin/fm-compact-lib.sh owns the derivation), and its record says
# so (trim_mark=, trim_window=). A leader spawned with --leads keeps the
# harness's own window and is recorded as a leader (leads=1); a crewmate may
# only be spawned under a task recorded that way. Driven end to end against
# fake tmux panes and real isolated git worktrees, including a relaunch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-compact-lib.sh
. "$ROOT/bin/fm-compact-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-trim-line)

# Fake tmux: the spawn fixture's shape (pane path, silent launch). For a
# relaunch it also answers the recovery-grade reads: the pane's current
# command is FM_FAKE_PANE_COMMAND (zsh = agent-free), its path is the task's
# worktree, and list-windows names the recorded window.
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
  fm_fake_exit0 "$fakebin" treehouse
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
Exercise the trim line for $2.

## Firstmate spec
Verify the spawn writes the line and records it.
EOF
}

# write_task <home> <proj> <id> [extra meta lines...]: a live ship task of this
# home, written the way a spawn would have recorded it, in a real worktree.
write_task() {
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  [ -d "$wt" ] || git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$proj" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "tasktmp=/tmp/fm-trim-$id" "model=default" "effort=default" "spawn_gen=s1.1.1" "$@"
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

# run_spawn <home> <proj> <id> [args...]: a ship spawn into a fresh worktree.
run_spawn() {
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  write_brief "$home" "$id"
  spawn_env "$home" "$wt" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@"
}

# run_relaunch <home> <proj> <id> [args...]: relaunch an existing recorded task
# whose pane sits agent-free in its worktree.
run_relaunch() {
  local home=$1 proj=$2 id=$3
  shift 3
  write_brief "$home" "$id"
  FM_FAKE_WINDOWS="fm-$id" spawn_env "$home" "$proj.wt-$id" "$SPAWN" "$id" --relaunch "$@"
}

meta_get() { grep "^$2=" "$1" | tail -1 | cut -d= -f2-; }
meta_count() { grep -c "^$2=" "$1" 2>/dev/null || true; }
settings_window() { jq -r ".$FM_COMPACT_SETTINGS_KEY // empty" "$1/.claude/settings.local.json"; }

test_story_crewmate_gets_the_line_and_the_record_says_so() {
  local rec out status meta wt
  rec=$(make_home story)
  read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" s1); status=$?
  [ "$status" -eq 0 ] || fail "story spawn must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/s1.meta"
  wt="$PROJ_DIR.wt-s1"
  [ "$(settings_window "$wt")" = "$(fm_compact_window)" ] \
    || fail "the worktree settings must carry $FM_COMPACT_SETTINGS_KEY=$(fm_compact_window), got '$(settings_window "$wt")'"
  jq -e '.hooks.Stop and .hooks.SessionStart' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "the line must join the busy and session hooks, not replace them"
  [ "$(meta_get "$meta" trim_mark)" = "$FM_COMPACT_MARK" ] || fail "meta must record trim_mark=$FM_COMPACT_MARK, got '$(meta_get "$meta" trim_mark)'"
  [ "$(meta_get "$meta" trim_window)" = "$(fm_compact_window)" ] || fail "meta must record trim_window=$(fm_compact_window), got '$(meta_get "$meta" trim_window)'"
  [ "$(meta_count "$meta" leads)" = 0 ] || fail "a story crewmate is not recorded as a leader"
  fm_compact_check_window "$(meta_get "$meta" trim_window)" || fail "the recorded window must be the derivation"
  assert_contains "$out" "spawned s1 harness=claude" "the success line is unchanged in shape"
  pass "a claude story crewmate gets autoCompactWindow=$(fm_compact_window) in its worktree settings and trim_mark/trim_window in its record"
}

test_leader_keeps_the_harness_window_and_is_recorded_as_one() {
  local rec out status meta wt
  rec=$(make_home leader)
  read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" L1 --leads); status=$?
  [ "$status" -eq 0 ] || fail "--leads spawn must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/L1.meta"
  wt="$PROJ_DIR.wt-L1"
  [ -z "$(settings_window "$wt")" ] || fail "a leader's settings must carry no $FM_COMPACT_SETTINGS_KEY, got '$(settings_window "$wt")'"
  jq -e '.hooks.Stop and .hooks.SessionStart' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "a leader still gets the busy and session hooks"
  [ "$(meta_get "$meta" leads)" = 1 ] || fail "meta must record leads=1, got '$(meta_get "$meta" leads)'"
  [ "$(meta_count "$meta" trim_mark)" = 0 ] && [ "$(meta_count "$meta" trim_window)" = 0 ] \
    || fail "a leader's record carries no trim_mark/trim_window: nothing was written for it"
  assert_contains "$out" "spawned L1 harness=claude" "the success line is unchanged in shape"
  assert_contains "$out" " leads=1" "the success line says the task leads"
  pass "--leads: the harness's own window stays, leads=1 is recorded, no trim keys are claimed"
}

test_leads_refusals_leave_nothing_behind() {
  local rec out
  rec=$(make_home refusals)
  read_home "$rec"
  write_task "$HOME_DIR" "$PROJ_DIR" lead-a leads=1
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" r1 --leads --leader lead-a) && fail "--leads with --leader must be refused"
  assert_contains "$out" "one level deep" "a led crewmate cannot lead"
  [ ! -e "$HOME_DIR/state/r1.meta" ] || fail "a refused spawn leaves no record"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" r2 --leads --relaunch) && fail "--leads with --relaunch must be refused"
  assert_contains "$out" "--relaunch keeps the task's recorded role" "a relaunch keeps the record's role"
  [ ! -e "$HOME_DIR/state/r2.meta" ] || fail "a refused relaunch leaves no record"
  out=$(spawn_env "$HOME_DIR" "$PROJ_DIR" "$SPAWN" r3 "$HOME_DIR" --secondmate --leads) && fail "--leads with --secondmate must be refused"
  assert_contains "$out" "--leads applies only to ship and scout spawns" "a secondmate is not a branch leader of this home"
  pass "--leads is refused with --leader, --relaunch and --secondmate, leaving no record"
}

test_a_task_not_spawned_as_a_leader_cannot_be_named_as_one() {
  local rec out status
  rec=$(make_home notleader)
  read_home "$rec"
  write_task "$HOME_DIR" "$PROJ_DIR" plain
  write_task "$HOME_DIR" "$PROJ_DIR" lead-b leads=1
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1 --leader plain) && fail "--leader naming a task without leads=1 must be refused"
  assert_contains "$out" "was not spawned as a leader (--leads)" "the refusal names the missing flag"
  [ ! -e "$HOME_DIR/state/c1.meta" ] || fail "a refused spawn leaves no record"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c2 --leader lead-b); status=$?
  [ "$status" -eq 0 ] || fail "--leader naming a recorded leader must succeed (exit $status)"$'\n'"$out"
  [ "$(meta_get "$HOME_DIR/state/c2.meta" leader)" = lead-b ] || fail "the crewmate records its leader"
  [ "$(meta_get "$HOME_DIR/state/c2.meta" trim_mark)" = "$FM_COMPACT_MARK" ] || fail "a led crewmate is a story crewmate: it gets the line"
  pass "--leader accepts only a task recorded with leads=1"
}

test_relaunch_keeps_each_role_and_its_window() {
  local rec out status meta wt
  rec=$(make_home relaunch)
  read_home "$rec"
  # A leader: relaunched without any flag, still a leader, still no line.
  write_task "$HOME_DIR" "$PROJ_DIR" L2 leads=1
  out=$(run_relaunch "$HOME_DIR" "$PROJ_DIR" L2); status=$?
  [ "$status" -eq 0 ] || fail "leader relaunch must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/L2.meta"
  wt="$PROJ_DIR.wt-L2"
  [ "$(meta_get "$meta" leads)" = 1 ] || fail "relaunch must keep leads=1"
  [ "$(meta_count "$meta" leads)" = 1 ] || fail "relaunch must not duplicate the leads line ($(meta_count "$meta" leads))"
  [ -z "$(settings_window "$wt")" ] || fail "a relaunched leader still carries no $FM_COMPACT_SETTINGS_KEY"
  [ "$(meta_count "$meta" trim_mark)" = 0 ] || fail "a relaunched leader claims no trim_mark"
  # A story crewmate recorded before this line existed: the relaunch writes it.
  write_task "$HOME_DIR" "$PROJ_DIR" s2
  out=$(run_relaunch "$HOME_DIR" "$PROJ_DIR" s2); status=$?
  [ "$status" -eq 0 ] || fail "story relaunch must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/s2.meta"
  wt="$PROJ_DIR.wt-s2"
  [ "$(settings_window "$wt")" = "$(fm_compact_window)" ] || fail "a relaunched story crewmate gets the line"
  [ "$(meta_get "$meta" trim_window)" = "$(fm_compact_window)" ] || fail "a relaunched story crewmate records trim_window"
  # A story crewmate switched to a harness without the knob: the claim goes.
  fm_fake_exit0 "$FAKEBIN_DIR" codex
  out=$(run_relaunch "$HOME_DIR" "$PROJ_DIR" s2 --harness codex); status=$?
  [ "$status" -eq 0 ] || fail "harness-switch relaunch must succeed (exit $status)"$'\n'"$out"
  [ "$(meta_count "$meta" trim_mark)" = 0 ] && [ "$(meta_count "$meta" trim_window)" = 0 ] \
    || fail "after a switch to codex the record must claim no trim line"
  [ ! -e "$wt/.claude/settings.local.json" ] || fail "the claude settings file is retired with the claude wiring"
  pass "relaunch: a leader stays a leader without the line, a story crewmate gets the line, a harness without the knob drops the claim"
}

test_a_harness_without_the_knob_claims_nothing() {
  local rec out status meta
  rec=$(make_home codex)
  read_home "$rec"
  fm_fake_exit0 "$FAKEBIN_DIR" codex
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" x1 --harness codex); status=$?
  [ "$status" -eq 0 ] || fail "codex spawn must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/x1.meta"
  [ "$(meta_count "$meta" trim_mark)" = 0 ] && [ "$(meta_count "$meta" trim_window)" = 0 ] \
    || fail "a codex crewmate's record claims no trim line"
  [ ! -e "$PROJ_DIR.wt-x1/.claude/settings.local.json" ] || fail "a codex spawn writes no claude settings"
  pass "a harness without the settings key gets no line and no claim"
}

test_story_crewmate_gets_the_line_and_the_record_says_so
test_leader_keeps_the_harness_window_and_is_recorded_as_one
test_leads_refusals_leave_nothing_behind
test_a_task_not_spawned_as_a_leader_cannot_be_named_as_one
test_relaunch_keeps_each_role_and_its_window
test_a_harness_without_the_knob_claims_nothing

echo "# all fm-spawn-trim-line tests passed"
