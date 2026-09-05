#!/usr/bin/env bash
# tests/fm-spawn-leader-chain.test.sh - the branch-leader chain at spawn time.
#
# bin/fm-spawn.sh --leader <task-id> records which live task of this home leads
# the new crewmate (leader= in state/<id>.meta) and refuses the fifth crewmate
# under one leader; bin/fm-lead.sh crew lists a leader's recorded crewmates from
# those metas. Both are driven end to end here against fake tmux panes and real
# isolated git worktrees. The contract lives in bin/fm-lead-lib.sh's header.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
LEAD="$ROOT/bin/fm-lead.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-leader-chain)

# Fake tmux: the spawn fixture's shape (pane path, silent launch) plus two
# knobs, each a space-separated list of window names. FM_FAKE_DEAD_WINDOWS are
# gone: missing from `list-windows -t <session>` (the exact inventory
# fm-backend's recovery-grade read checks first) and failing the
# `display-message -t <session>:<window>` presence read (the digest's cheap
# read, which decides when the recovery-grade read cannot classify the
# foreground - here it never can, so both reads are exercised).
# FM_FAKE_GHOST_WINDOWS are what tmux 3.7 makes of a killed window while its
# session lives: missing from the inventory, yet display-message still answers
# with the session's current window. Every window named by a record in
# FM_STATE_OVERRIDE exists unless one of the knobs names it.
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
is_ghost() {  # gone from the inventory, yet display-message still answers
  local ghost
  for ghost in ${FM_FAKE_GHOST_WINDOWS:-}; do
    [ "$1" = "$ghost" ] && return 0
  done
  return 1
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-t" ]; then
        is_dead "${a#*:}" && exit 1
      fi
      prev=$a
    done
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows)
    for meta in "${FM_STATE_OVERRIDE:-/nonexistent}"/*.meta; do
      [ -f "$meta" ] || continue
      w=$(sed -n 's/^window=[^:]*://p' "$meta" | head -1)
      [ -n "$w" ] || continue
      is_dead "$w" || is_ghost "$w" || printf '%s\n' "$w"
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_home <name>: a home with one project repo; echoes "<home>|<proj>|<fakebin>".
make_home() {
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

# write_brief <home> <id>
write_brief() {
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Exercise the leader chain for $2.

## Firstmate spec
Verify the spawn records its leader.
EOF
}

# write_leader <home> <proj> <id>: a live ship task of this home, written the
# way a spawn would have recorded it.
write_leader() {
  local home=$1 proj=$2 id=$3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$proj.wt-$id" \
    "project=$proj" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "tasktmp=/tmp/x" "model=default" "effort=default" "spawn_gen=s1.1.1" "leads=1"
}

# write_crewmate <home> <proj> <id> <leader>: a crewmate already recorded under
# <leader>, the shape this story's own spawn writes (a story crewmate, so no
# leads=1).
write_crewmate() {
  local home=$1 proj=$2 id=$3 leader=$4
  write_leader "$home" "$proj" "$id"
  grep -v '^leads=1$' "$home/state/$id.meta" > "$home/state/$id.meta.tmp"
  mv "$home/state/$id.meta.tmp" "$home/state/$id.meta"
  printf 'leader=%s\n' "$leader" >> "$home/state/$id.meta"
}

# run_spawn <home> <proj> <id> [fm-spawn args...]: a ship spawn of <id> into a
# fresh real worktree of <proj>, with the pane sitting in that worktree.
run_spawn() {
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  write_brief "$home" "$id"
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_DEAD_WINDOWS="${FM_FAKE_DEAD_WINDOWS:-}" FM_FAKE_GHOST_WINDOWS="${FM_FAKE_GHOST_WINDOWS:-}" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

run_lead() {  # <home> [fm-lead args...]
  local home=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_DEAD_WINDOWS="${FM_FAKE_DEAD_WINDOWS:-}" FM_FAKE_GHOST_WINDOWS="${FM_FAKE_GHOST_WINDOWS:-}" PATH="$FAKEBIN_DIR:$PATH" \
    "$LEAD" "$@" 2>&1
}

meta_leader_lines() { grep -c '^leader=' "$1" 2>/dev/null || true; }

test_leader_flag_records_leader_and_reports_it() {
  local rec out status meta
  rec=$(make_home records)
  read_home "$rec"
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-a
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1 --leader lead-a); status=$?
  [ "$status" -eq 0 ] || fail "spawn with --leader must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/c1.meta"
  assert_present "$meta" "spawn must publish the crewmate's meta"
  [ "$(meta_leader_lines "$meta")" = 1 ] || fail "meta must carry exactly one leader= line"$'\n'"$(cat "$meta")"
  assert_grep "leader=lead-a" "$meta" "meta must record leader=lead-a"
  assert_contains "$out" "spawned c1 " "success line must be printed"
  assert_contains "$out" " leader=lead-a" "success line must name the leader"
  pass "--leader records leader=<id> in the crewmate's meta and on the success line"
}

test_leader_equals_form_and_no_flag_leaves_meta_without_leader() {
  local rec out status meta
  rec=$(make_home noflag)
  read_home "$rec"
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-a
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1 --leader=lead-a); status=$?
  [ "$status" -eq 0 ] || fail "spawn with --leader=<id> must succeed (exit $status)"$'\n'"$out"
  assert_grep "leader=lead-a" "$HOME_DIR/state/c1.meta" "--leader=<id> form must record the leader"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" lone); status=$?
  [ "$status" -eq 0 ] || fail "spawn without --leader must still succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/lone.meta"
  [ "$(meta_leader_lines "$meta")" = 0 ] || fail "a spawn without --leader must write no leader= line"$'\n'"$(cat "$meta")"
  assert_not_contains "$out" "leader=" "a spawn without --leader must not mention a leader"
  pass "--leader=<id> works and a spawn without the flag records no leader"
}

test_bad_leader_values_are_refused_before_any_record() {
  local rec out status
  rec=$(make_home refuse)
  read_home "$rec"
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-a

  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1 --leader); status=$?
  [ "$status" -ne 0 ] || fail "--leader without a value must be refused"$'\n'"$out"
  assert_contains "$out" "--leader requires a value" "a dangling --leader must say so"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1b --leader=); status=$?
  [ "$status" -ne 0 ] || fail "--leader= with an empty value must be refused"$'\n'"$out"
  assert_contains "$out" "--leader requires a non-empty value" "an empty --leader= must say so"

  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c2 --leader ghost); status=$?
  [ "$status" -ne 0 ] || fail "an unknown leader must be refused"$'\n'"$out"
  assert_contains "$out" "ghost" "the refusal must name the unknown leader"
  assert_contains "$out" "no task record" "the refusal must say the leader has no record in this home"
  assert_absent "$HOME_DIR/state/c2.meta" "a refused spawn must publish no meta"

  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c3 --leader c3); status=$?
  [ "$status" -ne 0 ] || fail "a task naming itself as leader must be refused"$'\n'"$out"
  assert_contains "$out" "itself" "self-leadership refusal must say so"
  assert_absent "$HOME_DIR/state/c3.meta" "a refused spawn must publish no meta"

  out=$(FM_FAKE_DEAD_WINDOWS=fm-lead-a run_spawn "$HOME_DIR" "$PROJ_DIR" c4 --leader lead-a); status=$?
  [ "$status" -ne 0 ] || fail "a leader whose endpoint is dead must be refused"$'\n'"$out"
  assert_contains "$out" "lead-a" "the dead-leader refusal must name the leader"
  assert_contains "$out" "endpoint is dead" "the dead-leader refusal must name the cause"
  assert_absent "$HOME_DIR/state/c4.meta" "a refused spawn must publish no meta"
  assert_absent "$HOME_DIR/state/.spawn-c4.lock" "a refused spawn must leave no lock behind"
  # A killed window whose session lives: tmux 3.7's display-message answers
  # for the current window, so only the exact inventory tells the truth.
  out=$(FM_FAKE_GHOST_WINDOWS=fm-lead-a run_spawn "$HOME_DIR" "$PROJ_DIR" c4g --leader lead-a); status=$?
  [ "$status" -ne 0 ] || fail "a leader whose window is gone must be refused even though display-message still answers"$'\n'"$out"
  assert_contains "$out" "endpoint is dead" "the gone-window refusal must name the cause"
  assert_absent "$HOME_DIR/state/c4g.meta" "a refused spawn must publish no meta"

  write_crewmate "$HOME_DIR" "$PROJ_DIR" led-one lead-a
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c5 --leader led-one); status=$?
  [ "$status" -ne 0 ] || fail "a crewmate that is itself led must not lead"$'\n'"$out"
  assert_contains "$out" "led-one" "the nested-chain refusal must name the would-be leader"
  assert_contains "$out" "is itself led by lead-a" "the nested-chain refusal must name its leader"
  assert_absent "$HOME_DIR/state/c5.meta" "a refused spawn must publish no meta"

  fm_write_meta "$HOME_DIR/state/sm.meta" "window=firstmate:fm-sm" "endpoint_task_id=sm" \
    "worktree=$TMP_ROOT/sm-home" "project=$TMP_ROOT/sm-home" "harness=claude" "kind=secondmate" \
    "mode=secondmate" "yolo=off" "home=$TMP_ROOT/sm-home" "projects=" "spawn_gen=s1.1.1"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c6 --leader sm); status=$?
  [ "$status" -ne 0 ] || fail "a secondmate must not lead crewmates of this home"$'\n'"$out"
  assert_contains "$out" "secondmate" "the secondmate-leader refusal must name the cause"
  assert_absent "$HOME_DIR/state/c6.meta" "a refused spawn must publish no meta"
  pass "an empty, unknown, self, dead, led, or secondmate leader is refused before any record exists"
}

test_leader_is_refused_with_secondmate_and_relaunch() {
  local rec out status
  rec=$(make_home combos)
  read_home "$rec"
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-a
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" sm-x "$TMP_ROOT/nowhere" --secondmate --leader lead-a 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "--secondmate with --leader must be refused"$'\n'"$out"
  assert_contains "$out" "--leader applies only to ship and scout spawns" "secondmate refusal must name the rule"

  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" lead-a --relaunch --leader lead-b 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "--relaunch with --leader must be refused"$'\n'"$out"
  assert_contains "$out" "--relaunch keeps the task's recorded leader" "relaunch refusal must name the rule"
  pass "--leader is refused alongside --secondmate and --relaunch"
}

test_fifth_crewmate_is_refused_until_one_is_torn_down() {
  local rec out status
  rec=$(make_home ceiling)
  read_home "$rec"
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-a
  write_crewmate "$HOME_DIR" "$PROJ_DIR" c1 lead-a
  write_crewmate "$HOME_DIR" "$PROJ_DIR" c2 lead-a
  write_crewmate "$HOME_DIR" "$PROJ_DIR" c3 lead-a
  # A crewmate of another leader never counts against lead-a.
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-b
  write_crewmate "$HOME_DIR" "$PROJ_DIR" other lead-b

  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c4 --leader lead-a); status=$?
  [ "$status" -eq 0 ] || fail "the fourth crewmate must be accepted (exit $status)"$'\n'"$out"
  assert_grep "leader=lead-a" "$HOME_DIR/state/c4.meta" "the fourth crewmate must record its leader"

  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c5 --leader lead-a); status=$?
  [ "$status" -ne 0 ] || fail "the fifth crewmate must be refused"$'\n'"$out"
  assert_contains "$out" "already leads 4 crewmates" "the refusal must state the ceiling"
  assert_contains "$out" "c1 c2 c3 c4" "the refusal must name the four crewmates"
  assert_not_contains "$out" "other" "another leader's crewmate must not be counted"
  assert_absent "$HOME_DIR/state/c5.meta" "a refused fifth crewmate must publish no meta"
  assert_absent "$HOME_DIR/state/.lead-lead-a.lock" "the leader lock must be released after a refusal"

  # Teardown removes the crewmate's record; that is the moment a slot reopens.
  rm -f "$HOME_DIR/state/c2.meta"
  git -C "$PROJ_DIR" worktree remove --force "$PROJ_DIR.wt-c5"
  git -C "$PROJ_DIR" branch -q -D wt-c5
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c5 --leader lead-a); status=$?
  [ "$status" -eq 0 ] || fail "after one crewmate is torn down the next must be accepted (exit $status)"$'\n'"$out"
  assert_grep "leader=lead-a" "$HOME_DIR/state/c5.meta" "the replacement crewmate must record its leader"
  assert_absent "$HOME_DIR/state/.lead-lead-a.lock" "the leader lock must be released after a success"
  pass "a leader takes four crewmates, refuses the fifth naming the four, and accepts again after a teardown"
}

test_lead_crew_lists_a_leaders_crewmates() {
  local rec out status
  rec=$(make_home crew)
  read_home "$rec"
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-a
  write_crewmate "$HOME_DIR" "$PROJ_DIR" c2 lead-a
  write_crewmate "$HOME_DIR" "$PROJ_DIR" c1 lead-a
  write_leader "$HOME_DIR" "$PROJ_DIR" lead-b
  write_crewmate "$HOME_DIR" "$PROJ_DIR" other lead-b
  write_leader "$HOME_DIR" "$PROJ_DIR" lone

  out=$(FM_FAKE_DEAD_WINDOWS=fm-c2 run_lead "$HOME_DIR" crew --leader lead-a); status=$?
  [ "$status" -eq 0 ] || fail "crew must succeed for a leader with crewmates (exit $status)"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | grep -c '^c[12] ')" = 2 ] || fail "crew must list exactly the two crewmates"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | sed -n '1p' | cut -d' ' -f1)" = c1 ] || fail "crew must list crewmates sorted by id"$'\n'"$out"
  assert_contains "$out" "c1 kind=ship mode=no-mistakes endpoint=alive window=firstmate:fm-c1" "crew must print each crewmate's kind, mode, endpoint and window"
  assert_contains "$out" "c2 kind=ship mode=no-mistakes endpoint=dead window=firstmate:fm-c2" "crew must read the endpoint with fm-lead-lib's liveness read"
  assert_not_contains "$out" "other" "crew must not list another leader's crewmate"

  out=$(run_lead "$HOME_DIR" crew --leader lone); status=$?
  [ "$status" -eq 0 ] || fail "crew must succeed for a leader with no crewmates (exit $status)"$'\n'"$out"
  assert_contains "$out" "no crewmates recorded for lone" "crew must say when a leader has no crewmates"

  out=$(run_lead "$HOME_DIR" crew --leader ghost); status=$?
  [ "$status" -ne 0 ] || fail "crew must refuse a leader with no record"$'\n'"$out"
  assert_contains "$out" "no task record for ghost" "crew must name the missing record"

  out=$(run_lead "$HOME_DIR" crew); status=$?
  [ "$status" -ne 0 ] || fail "crew must refuse without --leader"$'\n'"$out"
  assert_contains "$out" "--leader <task-id>" "crew must name the missing flag"

  out=$(env -u FM_HOME FM_ROOT_OVERRIDE='' PATH="$FAKEBIN_DIR:$PATH" "$LEAD" crew --leader lead-a 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "fm-lead must refuse without FM_HOME"$'\n'"$out"
  assert_contains "$out" "FM_HOME is not set" "fm-lead must fail closed without an explicit home"
  pass "fm-lead crew lists a leader's recorded crewmates with the digest's endpoint read and refuses guesses"
}

test_leader_flag_records_leader_and_reports_it
test_leader_equals_form_and_no_flag_leaves_meta_without_leader
test_bad_leader_values_are_refused_before_any_record
test_leader_is_refused_with_secondmate_and_relaunch
test_fifth_crewmate_is_refused_until_one_is_torn_down
test_lead_crew_lists_a_leaders_crewmates

echo "# all fm-spawn-leader-chain tests passed"
