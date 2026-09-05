#!/usr/bin/env bash
# tests/fm-compact-keep.test.sh - the keep-set for every trim.
#
# bin/fm-compact-keep.sh prints the keep-set bin/fm-compact-lib.sh owns when
# the harness hands it a PreCompact payload for the main agent, and nothing
# for any other payload, always exiting 0; bin/fm-spawn.sh installs it under
# PreCompact with the matcher auto|manual in every claude ship or scout
# worktree, leader included, and in no other harness's. The spawn cases run
# against fake tmux panes and real isolated git worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-compact-lib.sh
. "$ROOT/bin/fm-compact-lib.sh"

KEEP="$ROOT/bin/fm-compact-keep.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-compact-keep)

payload() {  # <trigger> [extra json members]
  printf '{"hook_event_name":"PreCompact","trigger":"%s","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"/w","custom_instructions":null%s}' "$1" "${2:-}"
}

assert_keep_set() {  # <output> <label>
  local out=$1 label=$2
  [ "$out" = "$(fm_compact_keep_set)" ] || fail "$label: stdout must be exactly the keep-set, got:"$'\n'"$out"
  assert_contains "$out" "acceptance criteria" "$label: the keep-set names the acceptance criteria"
  assert_contains "$out" "failing test or error" "$label: the keep-set names the failing test"
  assert_contains "$out" "last decision taken and its reason" "$label: the keep-set names the decision"
  assert_contains "$out" "every file changed so far and why" "$label: the keep-set names the files"
  assert_contains "$out" "every instruction received and not yet done" "$label: the keep-set names pending instructions"
  assert_contains "$out" "Drop the contents of files already committed" "$label: the keep-set names what to drop"
}

test_prints_the_keep_set_for_auto_and_manual_trims() {
  local out
  out=$(payload auto | "$KEEP") || fail "an auto payload must exit 0"
  assert_keep_set "$out" "auto"
  out=$(payload manual ',"custom_instructions":"focus on the parser"' | "$KEEP") || fail "a manual payload must exit 0"
  assert_keep_set "$out" "manual"
  pass "the hook prints the keep-set for an automatic and a typed trim"
}

test_prints_nothing_for_any_other_payload() {
  local out status
  for bad in \
    'not json' \
    '' \
    '[]' \
    '{"hook_event_name":"SessionStart","source":"compact","session_id":"s1","transcript_path":"/t"}' \
    '{"hook_event_name":"PreCompact","trigger":"reactive"}' \
    '{"hook_event_name":"PreCompact"}' \
    '{"hook_event_name":"PreCompact","trigger":"auto","agent_id":"a-42"}'
  do
    out=$(printf '%s' "$bad" | "$KEEP" 2>&1); status=$?
    [ "$status" -eq 0 ] || fail "payload '$bad' must exit 0, got $status"
    [ -z "$out" ] || fail "payload '$bad' must print nothing, got: $out"
  done
  out=$("$KEEP" --help) || fail "--help must exit 0"
  assert_contains "$out" "PreCompact" "--help prints the header"
  pass "seven planted payloads print nothing and exit 0: non-JSON, empty, an array, another event, an unknown trigger, no trigger, a subagent"
}

# --- spawn wiring ------------------------------------------------------------

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

run_spawn() {  # <home> <proj> <id> [args...]
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the keep-set wiring for $id.

## Firstmate spec
Verify the spawn installs the PreCompact hook.
EOF
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

precompact_command() {  # <worktree>
  jq -r '.hooks.PreCompact[0].hooks[0].command' "$1/.claude/settings.local.json"
}

test_spawn_installs_the_hook_for_every_claude_crewmate_and_leader() {
  local rec out status wt cmd hookout
  rec=$(make_home wiring)
  read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" k1); status=$?
  [ "$status" -eq 0 ] || fail "claude spawn must succeed (exit $status)"$'\n'"$out"
  wt="$PROJ_DIR.wt-k1"
  [ "$(jq -r '.hooks.PreCompact[0].matcher' "$wt/.claude/settings.local.json")" = 'auto|manual' ] \
    || fail "PreCompact must match auto|manual, got '$(jq -r '.hooks.PreCompact[0].matcher' "$wt/.claude/settings.local.json")'"
  [ "$(jq -r '.hooks.PreCompact | length' "$wt/.claude/settings.local.json")" = 1 ] || fail "exactly one PreCompact entry"
  cmd=$(precompact_command "$wt")
  assert_contains "$cmd" "fm-compact-keep.sh" "the hook runs the keep script"
  jq -e '.hooks.Stop and .hooks.SessionStart' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "the keep hook joins the busy and session hooks"
  [ "$(jq -r ".$FM_COMPACT_SETTINGS_KEY" "$wt/.claude/settings.local.json")" = "$(fm_compact_window)" ] \
    || fail "the trim line still rides in the same file"
  # The installed command, run as the harness runs it, prints the keep-set.
  hookout=$(payload auto | bash -c "$cmd"); status=$?
  [ "$status" -eq 0 ] || fail "the installed command must exit 0 (got $status)"
  assert_keep_set "$hookout" "installed command"
  hookout=$(printf 'garbage' | bash -c "$cmd"); status=$?
  [ "$status" -eq 0 ] && [ -z "$hookout" ] || fail "the installed command prints nothing and exits 0 on garbage"
  [ ! -e "$wt/CLAUDE.local.md" ] || fail "no keep-set file is written into the worktree"
  # A leader gets the same hook: every trim keeps the same kinds of facts.
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" k2 --leads); status=$?
  [ "$status" -eq 0 ] || fail "leader spawn must succeed (exit $status)"$'\n'"$out"
  cmd=$(precompact_command "$PROJ_DIR.wt-k2")
  assert_contains "$cmd" "fm-compact-keep.sh" "a leader's worktree carries the keep hook too"
  [ "$(jq -r ".$FM_COMPACT_SETTINGS_KEY // empty" "$PROJ_DIR.wt-k2/.claude/settings.local.json")" = "" ] \
    || fail "a leader still has no trim line"
  # A harness without hooks of this kind gets nothing.
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" k3 --harness codex); status=$?
  [ "$status" -eq 0 ] || fail "codex spawn must succeed (exit $status)"$'\n'"$out"
  [ ! -e "$PROJ_DIR.wt-k3/.claude/settings.local.json" ] || fail "a codex spawn writes no claude settings"
  pass "the spawn installs PreCompact auto|manual running the keep script for a claude crewmate and a leader, never for codex, and writes no file into the worktree"
}

test_prints_the_keep_set_for_auto_and_manual_trims
test_prints_nothing_for_any_other_payload
test_spawn_installs_the_hook_for_every_claude_crewmate_and_leader

echo "# all fm-compact-keep tests passed"
