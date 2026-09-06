#!/usr/bin/env bash
# tests/fm-spawn-fresh-head.test.sh - the fresh head: what a crewmate carries
# before its first turn.
#
# A claude crewmate or leader whose checkout is the firstmate repo itself
# (AGENTS.md opening "# Firstmate", CLAUDE.md its pointer) would load First
# Mate's whole job description at every start and after every trim, though
# none of it is the crewmate's job: the spawn writes claudeMdExcludes for the
# worktree's CLAUDE.md into the same .claude/settings.local.json it already
# owns, and only there. Any other project keeps its own memory files. The
# spawn also measures the brief the crewmate will read (bytes and a rough
# token estimate at four bytes a token) and warns above 6K tokens without
# refusing anything. Driven end to end against fake tmux panes and real
# isolated git worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-fresh-head)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'zsh\n'; exit 0 ;;
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

# make_home <name> <firstmate|plain|other-agents> -> "<home>|<proj>|<fakebin>"
# firstmate: the project looks like this repo (AGENTS.md opening "# Firstmate",
# CLAUDE.md pointing at it, bin/fm-spawn.sh present). plain: no memory files.
# other-agents: an AGENTS.md and CLAUDE.md of some other project.
make_home() {
  local name=$1 shape=$2 base home proj fakebin
  base="$TMP_ROOT/$name"
  home="$base/home"
  proj="$base/project"
  fakebin=$(make_fakebin "$base/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  case "$shape" in
    firstmate)
      mkdir -p "$proj/bin"
      printf '#!/usr/bin/env bash\n' > "$proj/bin/fm-spawn.sh"
      printf '# Firstmate\n\nYou are the first mate.\n' > "$proj/AGENTS.md"
      printf '@AGENTS.md\n' > "$proj/CLAUDE.md"
      ;;
    other-agents)
      printf '# Some project\n\nRules.\n' > "$proj/AGENTS.md"
      printf '@AGENTS.md\n' > "$proj/CLAUDE.md"
      ;;
  esac
  git -C "$proj" add -A >/dev/null 2>&1
  git -C "$proj" -c user.name=t -c user.email=t@t commit -q -m "shape $shape" --allow-empty >/dev/null 2>&1
  fm_git_add_origin "$proj" "$proj.origin.git"
  printf '%s|%s|%s\n' "$home" "$proj" "$fakebin"
}

read_home() {
  IFS='|' read -r HOME_DIR PROJ_DIR FAKEBIN_DIR <<REC
$1
REC
}

write_brief() {  # <home> <id> [extra bytes]
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<BRIEF
# Task
## Captain's intent
Exercise the fresh head for $2.

## Firstmate spec
Verify the spawn writes the exclusion and measures the brief.
BRIEF
  if [ -n "${3:-}" ]; then
    head -c "$3" /dev/zero | tr '\0' 'x' >> "$1/data/$2/brief.md"
    printf '\n' >> "$1/data/$2/brief.md"
  fi
}

spawn_env() {  # <home> <pane-path> <cmd...>
  local home=$1 pane=$2
  shift 2
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" \
    PATH="$FAKEBIN_DIR:$PATH" "$@" 2>&1
}

run_spawn() {  # <home> <proj> <id> [brief-extra-bytes] [args...]
  local home=$1 proj=$2 id=$3 extra=${4:-} wt
  shift 3; [ $# -gt 0 ] && shift
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  write_brief "$home" "$id" "$extra"
  spawn_env "$home" "$wt" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@"
}

excludes() { jq -c '.claudeMdExcludes // "absent"' "$1/.claude/settings.local.json"; }

test_firstmate_repo_crewmate_and_leader_skip_first_mates_job_description() {
  local rec out wt
  rec=$(make_home fm firstmate); read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1) || fail "spawn on the firstmate repo failed:"$'\n'"$out"
  wt="$PROJ_DIR.wt-c1"
  [ "$(excludes "$wt")" = "[\"$wt/CLAUDE.md\"]" ] \
    || fail "a firstmate-repo crewmate's settings exclude its worktree's CLAUDE.md (the AGENTS.md import), got $(excludes "$wt")"
  [ "$(jq -r '.hooks.PostCompact | length' "$wt/.claude/settings.local.json")" = 1 ] || fail "the hooks stay in the same settings file"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" lead-a '' --leads) || fail "leader spawn failed:"$'\n'"$out"
  wt="$PROJ_DIR.wt-lead-a"
  [ "$(excludes "$wt")" = "[\"$wt/CLAUDE.md\"]" ] || fail "a leader on the firstmate repo skips it too, got $(excludes "$wt")"
  pass "a claude crewmate or leader checked out on the firstmate repo carries claudeMdExcludes for its worktree's CLAUDE.md"
}

test_other_projects_keep_their_memory_files() {
  local rec out wt
  rec=$(make_home plain plain); read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1) || fail "plain spawn failed:"$'\n'"$out"
  wt="$PROJ_DIR.wt-c1"
  [ "$(excludes "$wt")" = '"absent"' ] || fail "a project without memory files gets no exclusion, got $(excludes "$wt")"
  rec=$(make_home other other-agents); read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1) || fail "other-agents spawn failed:"$'\n'"$out"
  wt="$PROJ_DIR.wt-c1"
  [ "$(excludes "$wt")" = '"absent"' ] || fail "another project's AGENTS.md is that project's memory and stays loaded, got $(excludes "$wt")"
  pass "a crewmate on any other project keeps that project's memory files: no exclusion is written"
}

test_relaunch_keeps_the_exclusion() {
  local rec out wt
  rec=$(make_home relaunch firstmate); read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1) || fail "spawn failed:"$'\n'"$out"
  wt="$PROJ_DIR.wt-c1"
  rm -f "$wt/.claude/settings.local.json"
  write_brief "$HOME_DIR" c1
  out=$(FM_FAKE_WINDOWS=fm-c1 spawn_env "$HOME_DIR" "$wt" "$SPAWN" c1 --relaunch) || fail "relaunch failed:"$'\n'"$out"
  [ "$(excludes "$wt")" = "[\"$wt/CLAUDE.md\"]" ] || fail "a relaunch rewrites the exclusion, got $(excludes "$wt")"
  pass "a relaunch on the firstmate repo writes the exclusion again"
}

test_brief_is_measured_and_a_big_one_is_warned_never_refused() {
  local rec out
  rec=$(make_home measure plain); read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1) || fail "spawn failed:"$'\n'"$out"
  assert_contains "$out" "brief c1: " "the spawn measures the brief"
  case "$out" in
    *"brief c1: "*" bytes (~"*" tokens)"*) ;;
    *) fail "the measure names bytes and a token estimate:"$'\n'"$out" ;;
  esac
  case "$out" in *"over 6K"*) fail "a small brief draws no warning:"$'\n'"$out" ;; esac
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c2 30000) || fail "a spawn with a 30 KB brief must still succeed:"$'\n'"$out"
  [ -f "$HOME_DIR/state/c2.meta" ] || fail "the big brief's task is recorded: measured, never refused"
  assert_contains "$out" "over 6K tokens" "a 30 KB brief (~7.5K tokens) is warned about"
  case "$out" in *"brief c2: 30"*" bytes (~7"*" tokens)"*) ;; *) fail "the measure reports the size:"$'\n'"$out" ;; esac
  pass "the spawn reports the brief's bytes and token estimate; over 6K tokens it warns and still spawns"
}

test_firstmate_repo_crewmate_and_leader_skip_first_mates_job_description
test_other_projects_keep_their_memory_files
test_relaunch_keeps_the_exclusion
test_brief_is_measured_and_a_big_one_is_warned_never_refused
