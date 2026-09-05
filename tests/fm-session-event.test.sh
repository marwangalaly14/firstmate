#!/usr/bin/env bash
# tests/fm-session-event.test.sh - launch truth: the launch line a task was
# really given (credentials redacted) in state/<id>.meta, and the session
# record data/<id>/sessions.log that bin/fm-session-event.sh appends from the
# claude SessionStart hook bin/fm-spawn.sh installs. The hook script is driven
# with real payloads; the spawn is driven end to end against fake tmux panes
# and a real isolated git worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
EVENT="$ROOT/bin/fm-session-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-event)

payload() {  # <source> <session-id> <transcript-path> [extra-json-fields]
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","hook_event_name":"SessionStart","source":"%s"%s}\n' \
    "$2" "$3" "$1" "${4:-}"
}

run_event() {  # <data-dir> <id> < payload
  "$EVENT" "$1" "$2" 2>&1
}

test_startup_and_resume_append_one_line_each() {
  local data=$TMP_ROOT/append/data out status log
  mkdir -p "$data/t1"
  log="$data/t1/sessions.log"
  out=$(payload startup sid-1 /tmp/tr/sid-1.jsonl ',"model":"claude-opus-5","effort":{"level":"high"}' | run_event "$data" t1); status=$?
  [ "$status" -eq 0 ] || fail "a startup payload must be accepted (exit $status)"$'\n'"$out"
  [ -z "$out" ] || fail "the hook must print nothing: SessionStart stdout enters the crewmate's context"$'\n'"$out"
  assert_present "$log" "a startup payload must create sessions.log"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "one payload must append exactly one line"$'\n'"$(cat "$log")"
  IFS=$'\t' read -r epoch source sid path model effort < "$log"
  case "$epoch" in ''|*[!0-9]*) fail "the first field must be an epoch second (got '$epoch')" ;; esac
  [ "$source" = startup ] || fail "field 2 must be the source (got '$source')"
  [ "$sid" = sid-1 ] || fail "field 3 must be the session id (got '$sid')"
  [ "$path" = /tmp/tr/sid-1.jsonl ] || fail "field 4 must be the transcript path (got '$path')"
  [ "$model" = claude-opus-5 ] || fail "field 5 must be the model (got '$model')"
  [ "$effort" = high ] || fail "field 6 must be the effort level (got '$effort')"

  out=$(payload resume sid-1 /tmp/tr/sid-1.jsonl | run_event "$data" t1); status=$?
  [ "$status" -eq 0 ] || fail "a resume payload must be accepted (exit $status)"$'\n'"$out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ] || fail "a second payload must append a second line"$'\n'"$(cat "$log")"
  IFS=$'\t' read -r epoch source sid path model effort < <(tail -1 "$log")
  [ "$source" = resume ] || fail "the newest line must be the resume (got '$source')"
  [ "$model" = '?' ] || fail "an absent model must be recorded as ? (got '$model')"
  [ "$effort" = '?' ] || fail "an absent effort must be recorded as ? (got '$effort')"
  pass "startup and resume payloads append one tab-separated line each, newest last, ? for what the harness omitted"
}

test_malformed_or_foreign_payloads_append_nothing() {
  local data=$TMP_ROOT/malformed/data out status log
  mkdir -p "$data/t2"
  log="$data/t2/sessions.log"
  for case in \
    'not json at all' \
    '{"session_id":"s","transcript_path":"/t","hook_event_name":"Stop","source":"startup"}' \
    '{"session_id":"s","transcript_path":"/t","hook_event_name":"SessionStart","source":"compact"}' \
    '{"transcript_path":"/t","hook_event_name":"SessionStart","source":"startup"}' \
    '{"session_id":"","transcript_path":"/t","hook_event_name":"SessionStart","source":"startup"}' \
    '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' \
    '{"session_id":"s","transcript_path":"relative.jsonl","hook_event_name":"SessionStart","source":"startup"}' \
    '{"session_id":"s","transcript_path":"/t","hook_event_name":"SessionStart","source":"startup","agent_id":"sub-1"}' \
    '{"session_id":"s\tx","transcript_path":"/t","hook_event_name":"SessionStart","source":"startup"}' \
    ''; do
    out=$(printf '%s' "$case" | run_event "$data" t2); status=$?
    [ "$status" -eq 0 ] || fail "a rejected payload must still exit 0 so Claude's lifecycle never breaks (exit $status for '$case')"$'\n'"$out"
    [ -z "$out" ] || fail "a rejected payload must print nothing (case '$case')"$'\n'"$out"
    assert_absent "$log" "a rejected payload must append nothing (case '$case')"
  done
  out=$("$EVENT" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "running the hook by hand without arguments must be refused"
  assert_contains "$out" "usage" "the by-hand refusal must show usage"
  pass "non-JSON, foreign, compact, incomplete, relative, subagent, and tab-carrying payloads append nothing and exit 0"
}

# --- through the spawn --------------------------------------------------------

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option|send-keys) exit 0 ;;
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

run_spawn() {  # <home> <proj> <id> [fm-spawn args...]
  local home=$1 proj=$2 id=$3 wt
  shift 3
  wt="$proj.wt-$id"
  git -C "$proj" worktree add --quiet -b "wt-$id" "$wt"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise launch truth for $id.

## Firstmate spec
Verify the spawn records its launch and session hook.
EOF
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

hook_command() {  # <settings> <event>
  jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1"
}

test_spawn_records_launch_and_installs_session_hook() {
  local rec out status meta settings launch cmd matcher log
  rec=$(make_home claude)
  read_home "$rec"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" c1); status=$?
  [ "$status" -eq 0 ] || fail "claude spawn must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/c1.meta"
  [ "$(grep -c '^launch=' "$meta")" = 1 ] || fail "meta must carry exactly one launch= line"$'\n'"$(cat "$meta")"
  launch=$(sed -n 's/^launch=//p' "$meta")
  assert_contains "$launch" "claude --dangerously-skip-permissions" "launch= must record the harness template as given"
  assert_contains "$launch" "__BRIEF__" "launch= must keep the brief placeholder rather than the resolved path"

  settings="$PROJ_DIR.wt-c1/.claude/settings.local.json"
  assert_present "$settings" "claude spawn must write its hook settings"
  jq -e '.hooks.SessionStart' "$settings" >/dev/null || fail "claude hook settings must carry SessionStart"
  matcher=$(jq -r '.hooks.SessionStart[0].matcher' "$settings")
  [ "$matcher" = "startup|resume|clear|fork" ] || fail "SessionStart must match every source that changes the transcript, never compact (got '$matcher')"
  cmd=$(hook_command "$settings" SessionStart)
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "SessionStart must carry a command"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "the busy-state hooks must survive: $ev missing"
  done

  log="$HOME_DIR/data/c1/sessions.log"
  assert_absent "$log" "no session is recorded before the harness starts"
  out=$(payload startup sid-c1 "$TMP_ROOT/tr/sid-c1.jsonl" ',"model":"claude-sonnet-5"' | sh -c "$cmd"); status=$?
  [ "$status" -eq 0 ] || fail "the installed SessionStart command must exit 0 (exit $status)"$'\n'"$out"
  [ -z "$out" ] || fail "the installed SessionStart command must print nothing"$'\n'"$out"
  assert_present "$log" "the installed hook must append the session record"
  assert_grep "sid-c1" "$log" "the record must carry the session id"
  assert_grep "claude-sonnet-5" "$log" "the record must carry the model the harness reported"
  out=$(printf 'garbage' | sh -c "$cmd"); status=$?
  [ "$status" -eq 0 ] || fail "the installed command must tolerate a bad payload (exit $status)"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "a bad payload through the installed command must append nothing"
  pass "a claude spawn records launch= and installs a SessionStart hook that appends data/<id>/sessions.log"
}

test_raw_launch_is_recorded_with_credentials_redacted() {
  local rec out status meta launch raw
  rec=$(make_home raw)
  read_home "$rec"
  # The raw line keeps the spawn's own placeholders literally; nothing here expands.
  # shellcheck disable=SC2016
  raw='ANTHROPIC_BASE_URL=https://example.invalid/v1 ANTHROPIC_AUTH_TOKEN=sk-plant-8d2f OPENROUTER_API_KEY=or-plant-77 claude --model glm-5 "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" g1 "$raw"); status=$?
  [ "$status" -eq 0 ] || fail "a raw claude launch must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/g1.meta"
  launch=$(sed -n 's/^launch=//p' "$meta")
  assert_contains "$launch" "ANTHROPIC_BASE_URL=https://example.invalid/v1" "a plain env value must be kept"
  assert_contains "$launch" "ANTHROPIC_AUTH_TOKEN=<redacted>" "a token value must be redacted by name"
  assert_contains "$launch" "OPENROUTER_API_KEY=<redacted>" "a key value must be redacted by name"
  assert_contains "$launch" "claude --model glm-5" "the command and its flags must be kept"
  assert_contains "$launch" "__BRIEF__" "the brief placeholder must be kept"
  ! grep -r "sk-plant-8d2f" "$HOME_DIR/state" >/dev/null || fail "the planted token must appear nowhere under state/"
  ! grep -r "or-plant-77" "$HOME_DIR/state" >/dev/null || fail "the planted key must appear nowhere under state/"
  assert_not_contains "$out" "sk-plant-8d2f" "the planted token must not be echoed by the spawn"
  pass "a raw launch line is recorded as given with KEY/TOKEN/SECRET/PASSWORD/AUTH values redacted"
}

test_non_claude_spawn_records_launch_without_a_session_hook() {
  local rec out status meta
  rec=$(make_home codex)
  read_home "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" x1); status=$?
  [ "$status" -eq 0 ] || fail "codex spawn must succeed (exit $status)"$'\n'"$out"
  meta="$HOME_DIR/state/x1.meta"
  assert_grep "launch=codex " "$meta" "a codex spawn must record its launch template"
  assert_absent "$PROJ_DIR.wt-x1/.claude/settings.local.json" "a codex spawn must install no claude hooks"
  assert_absent "$HOME_DIR/data/x1/sessions.log" "a codex spawn records no session until a harness reports one"
  pass "a non-claude spawn records launch= and installs no session hook"
}

test_startup_and_resume_append_one_line_each
test_malformed_or_foreign_payloads_append_nothing
test_spawn_records_launch_and_installs_session_hook
test_raw_launch_is_recorded_with_credentials_redacted
test_non_claude_spawn_records_launch_without_a_session_hook

echo "# all fm-session-event tests passed"
