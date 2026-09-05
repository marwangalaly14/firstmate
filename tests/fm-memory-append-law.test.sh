#!/usr/bin/env bash
# tests/fm-memory-append-law.test.sh - the law of the head: memory machinery
# appends, or acts at a trim; it never rewrites the head between trims.
#
# A turn re-reads the crewmate's whole head, and an unchanged front of the
# head comes from the prompt cache at a fraction of the price; anything that
# changes the front between trims forces a full-price re-read. So everything
# that measures or steers a crewmate from the outside must leave the head's
# front alone: docs/branch-leader.md "The law of the head". This suite proves
# it on a real spawn (fake tmux, real worktrees), two ways:
#   1. of the hooks the spawn installs in the crewmate's harness settings, the
#      only ones whose stdout the harness puts in front of the model - the
#      keep-set (PreCompact) and the task card (SessionStart) - fire at a trim
#      and nowhere else; every other hook, run for real against the fixture,
#      prints nothing; and no hook rides an event this suite does not know.
#   2. every piece of the machinery run between trims (the hooks, the vitals
#      card, the signals check, the leader's steer and trim order, the
#      progress report, the door relay, and the trim-time scripts themselves)
#      leaves every file outside data/ and state/ byte-identical: the
#      worktrees' memory files and harness settings, the user-level harness
#      config, the project, the brief.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/transcript-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/transcript-helpers.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-append-law)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
NOW=$(date +%s)

# The trim-line suite's fake tmux: the pane's path and command come from the
# environment, list-windows names FM_FAKE_WINDOWS, capture-pane shows an empty
# composer (a typed submit reads back as confirmed).
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
  list-windows) printf '%s\n' "${FM_FAKE_WINDOWS:-}" | tr ' ' '\n'; exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
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

BASE="$TMP_ROOT/law"
HOME_DIR="$BASE/home"
PROJ_DIR="$BASE/project"
make_fixture() {
  FAKEBIN_DIR=$(make_fakebin "$BASE/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/user-home/.claude"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '# user memory\nremember nothing\n' > "$HOME_DIR/user-home/.claude/CLAUDE.md"
  printf '{"hooks":{}}\n' > "$HOME_DIR/user-home/.claude/settings.json"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_git_init_commit "$PROJ_DIR"
  printf '# project\nA project memory file the crewmate reads.\n' > "$PROJ_DIR/CLAUDE.md"
  git -C "$PROJ_DIR" add CLAUDE.md
  git -C "$PROJ_DIR" -c user.name=t -c user.email=t@t commit -q -m 'memory file'
  fm_git_add_origin "$PROJ_DIR" "$PROJ_DIR.origin.git"
}

write_brief() {  # <id>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nExercise the law of the head for %s.\n\n## Firstmate spec\nNone.\n' "$1" > "$HOME_DIR/data/$1/brief.md"
}

fixture_env() {  # <pane-path> <cmd...>: the spawn's environment (agent-free pane)
  local pane=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-zsh}" FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" \
    FM_SEND_LOG="$BASE/send.log" FM_SEND_SETTLE=0 \
    PATH="$FAKEBIN_DIR:$PATH" "$@"
}

run_spawn() {  # <id> [args...]
  local id=$1 wt
  shift
  wt="$PROJ_DIR.wt-$id"
  git -C "$PROJ_DIR" worktree add --quiet -b "wt-$id" "$wt"
  write_brief "$id"
  fixture_env "$wt" "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

# machinery <cmd...>: run one piece of the machinery the way the fleet does,
# with both panes alive and holding an agent.
machinery() {
  FM_FAKE_PANE_COMMAND=claude FM_FAKE_WINDOWS="fm-lead-a fm-c1" fixture_env "$PROJ_DIR.wt-c1" "$@"
}

# The head's front on disk: everything outside data/ and state/ (the worktrees
# with their memory files and harness settings, the user-level config, the
# project) plus the briefs, which a relaunch and the task card read back into
# the head. Path and content hash.
front_files() {
  find "$BASE" -type f -not -path "$HOME_DIR/data/*" -not -path "$HOME_DIR/state/*" -not -path "$BASE/send.log" -not -path "$BASE/out/*" -not -path "$BASE/marker" "$@"
  find "$HOME_DIR/data" -type f -name brief.md "$@"
}
manifest() {
  front_files | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(shasum -a 256 < "$f" | cut -c1-64)" "$f"
  done
}

hook_payload() {  # <event> [<extra json fields>]
  printf '{"session_id":"s-c1","transcript_path":"%s","cwd":"%s","hook_event_name":"%s"%s}\n' \
    "$HOME_DIR/c1.jsonl" "$PROJ_DIR.wt-c1" "$1" "${2:+,$2}"
}

# --- the fixture: a leader and its crewmate, spawned for real ----------------
make_fixture
out=$(run_spawn lead-a --leads); status=$?
[ "$status" -eq 0 ] || fail "the leader's spawn must succeed (exit $status)"$'\n'"$out"
out=$(FM_FAKE_WINDOWS="fm-lead-a" FM_FAKE_PANE_COMMAND=claude run_spawn c1 --leader lead-a); status=$?
[ "$status" -eq 0 ] || fail "the crewmate's spawn must succeed (exit $status)"$'\n'"$out"
WT="$PROJ_DIR.wt-c1"
SETTINGS="$WT/.claude/settings.local.json"
[ -f "$SETTINGS" ] || fail "the spawn writes the crewmate's harness settings at $SETTINGS"
# a transcript with a loop (three identical calls), a session record, a door
# line and a logbook line, so every reader has something to read
{
  row_user $((NOW - 200))
  row_assistant $((NOW - 90)) m1 60000 0 0 10 "$(tool_bash 'bash tests/x.test.sh')"
  row_assistant $((NOW - 60)) m2 60000 0 0 10 "$(tool_bash 'bash tests/x.test.sh')"
  row_assistant $((NOW - 30)) m3 60000 0 0 10 "$(tool_bash 'bash tests/x.test.sh')"
} > "$HOME_DIR/c1.jsonl"
printf '%s\tstartup\ts-c1\t%s\t?\t?\n' "$((NOW - 3600))" "$HOME_DIR/c1.jsonl" >> "$HOME_DIR/data/c1/sessions.log"
printf 'blocked: [key=stuck] the suite loops on the same failure\n' > "$HOME_DIR/state/c1.status"
printf '\n- the retry loop is the suspect\n' >> "$HOME_DIR/data/c1/logbook.md"
mkdir -p "$BASE/out"

# --- 1. the hooks: who may speak, and only at a trim -------------------------
test_only_the_trim_hooks_speak_into_the_head() {
  local events e n i cmd matcher outf payload speakers=0 unknown=
  events=$(jq -r '.hooks | keys[]' "$SETTINGS")
  for e in $events; do
    case "$e" in
      UserPromptSubmit|Stop|StopFailure|SessionEnd|SessionStart|PreCompact|PostCompact) ;;
      *) unknown="$unknown $e" ;;
    esac
  done
  [ -z "$unknown" ] || fail "a hook rides an event this suite does not know:$unknown - classify it under the law (does its stdout reach the model? does it fire only at a trim?) before it ships"
  for e in $events; do
    n=$(jq -r ".hooks[\"$e\"] | length" "$SETTINGS")
    i=0
    while [ "$i" -lt "$n" ]; do
      matcher=$(jq -r ".hooks[\"$e\"][$i].matcher // \"\"" "$SETTINGS")
      cmd=$(jq -r ".hooks[\"$e\"][$i].hooks[0].command" "$SETTINGS")
      [ "$(jq -r ".hooks[\"$e\"][$i].hooks | length" "$SETTINGS")" -eq 1 ] || fail "${e}[$i]: one command per entry, so the law can read it"
      case "$e:$cmd" in
        PreCompact:*fm-compact-keep.sh*)
          # the keep-set speaks to the summarizer: at a trim, automatic or typed
          [ "$matcher" = "auto|manual" ] || fail "PreCompact keep-set must match auto|manual, got '$matcher'"
          speakers=$((speakers + 1))
          ;;
        SessionStart:*fm-task-card.sh*)
          # the task card speaks to the crewmate: only when a trimmed session resumes
          [ "$matcher" = compact ] || fail "the task card must fire on SessionStart compact only, got matcher '$matcher'"
          speakers=$((speakers + 1))
          ;;
        *fm-compact-keep.sh*|*fm-task-card.sh*)
          fail "${e}[$i]: a speaking script is wired to an event that is not a trim: $cmd"
          ;;
        *)
          # everything else fires between trims and must say nothing
          case "$e" in
            SessionStart) payload=$(hook_payload "$e" '"source":"startup"') ;;
            PostCompact) payload=$(hook_payload "$e" '"trigger":"auto"') ;;
            *) payload=$(hook_payload "$e") ;;
          esac
          outf="$BASE/out/$e.$i.stdout"
          printf '%s\n' "$payload" | machinery bash -c "$cmd" > "$outf" 2>/dev/null || true
          [ ! -s "$outf" ] || fail "${e}[$i] printed into the head between trims:"$'\n'"$(cat "$outf")"$'\n'"command: $cmd"
          ;;
      esac
      i=$((i + 1))
    done
  done
  [ "$speakers" -eq 2 ] || fail "exactly two hooks speak into the head (the keep-set and the task card), found $speakers"
  pass "of the spawn's hooks only the keep-set (PreCompact auto|manual) and the task card (SessionStart compact) speak into the head, both at a trim; UserPromptSubmit, Stop, StopFailure, SessionEnd, SessionStart startup and PostCompact run for real and print nothing; no hook rides an unknown event"
}

# --- 2. the machinery between trims leaves the head's front alone -------------
test_the_machinery_writes_only_under_data_and_state() {
  local before after changed rc
  manifest > "$BASE/out/before.manifest"
  [ "$(wc -l < "$BASE/out/before.manifest" | tr -d ' ')" -gt 10 ] || fail "the manifest covers the worktrees, the project and the user-level config, got:"$'\n'"$(cat "$BASE/out/before.manifest")"
  grep -q "$WT/.claude/settings.local.json" "$BASE/out/before.manifest" || fail "the manifest covers the crewmate's harness settings"
  grep -q "$WT/CLAUDE.md" "$BASE/out/before.manifest" || fail "the manifest covers the worktree's memory file"
  grep -q "$HOME_DIR/user-home/.claude/CLAUDE.md" "$BASE/out/before.manifest" || fail "the manifest covers the user-level memory file"
  grep -q "$HOME_DIR/data/c1/brief.md" "$BASE/out/before.manifest" || fail "the manifest covers the crewmate's brief"
  touch "$BASE/marker"
  # the readers
  machinery "$ROOT/bin/fm-crew-vitals.sh" c1 > "$BASE/out/vitals" 2>&1 || fail "the vitals card runs: $(cat "$BASE/out/vitals")"
  machinery "$ROOT/bin/fm-crew-vitals.sh" c1 --json > "$BASE/out/vitals.json" 2>&1 || fail "the vitals JSON runs"
  machinery "$ROOT/bin/fm-crew-signals.sh" "$HOME_DIR" c1 > "$BASE/out/signals" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "the signals check runs (exit $rc): $(cat "$BASE/out/signals")"
  grep -q '^loop' "$BASE/out/signals" || fail "the fixture's loop is seen, so the check did real work: $(cat "$BASE/out/signals")"
  machinery "$ROOT/bin/fm-progress.sh" scaffold lead-a --estimate 40 > "$BASE/out/progress" 2>&1 || fail "the progress scaffold runs: $(cat "$BASE/out/progress")"
  # the leader's hands
  machinery "$ROOT/bin/fm-lead.sh" steer --leader lead-a c1 "drop the retry loop; assert once" > "$BASE/out/steer" 2>&1 || fail "the leader's steer lands: $(cat "$BASE/out/steer")"
  machinery "$ROOT/bin/fm-lead.sh" trim --leader lead-a c1 the failing test > "$BASE/out/trim" 2>&1 || fail "the leader's trim order lands: $(cat "$BASE/out/trim")"
  # the door relay (the Stop hook's second half) and the trim-time scripts
  machinery "$ROOT/bin/fm-lead-relay.sh" "$HOME_DIR" c1 > "$BASE/out/relay" 2>&1 || fail "the relay runs"
  [ -f "$HOME_DIR/data/c1/doors/index" ] || fail "the relay did real work (the door ledger)"
  hook_payload PreCompact '"trigger":"auto"' | machinery "$ROOT/bin/fm-compact-keep.sh" > "$BASE/out/keep" 2>&1 || fail "the keep-set runs"
  [ -s "$BASE/out/keep" ] || fail "the keep-set speaks (to the summarizer, at a trim)"
  hook_payload SessionStart '"source":"compact"' | machinery "$ROOT/bin/fm-task-card.sh" "$HOME_DIR" c1 > "$BASE/out/card" 2>&1 || fail "the task card runs"
  [ -s "$BASE/out/card" ] || fail "the task card speaks (to the crewmate, after a trim)"
  hook_payload PostCompact '"trigger":"auto"' | machinery "$ROOT/bin/fm-trim-event.sh" "$HOME_DIR" c1 > "$BASE/out/trimevent" 2>&1 || fail "the trim event runs"
  [ ! -s "$BASE/out/trimevent" ] || fail "the trim event prints nothing: $(cat "$BASE/out/trimevent")"
  # the verdict: nothing outside data/ and state/ changed, by content or by name
  manifest > "$BASE/out/after.manifest"
  before=$(cat "$BASE/out/before.manifest"); after=$(cat "$BASE/out/after.manifest")
  [ "$before" = "$after" ] || fail "the head's front changed between trims:"$'\n'"$(diff "$BASE/out/before.manifest" "$BASE/out/after.manifest" || true)"
  changed=$(front_files -newer "$BASE/marker")
  [ -z "$changed" ] || fail "the machinery wrote into the head's front:"$'\n'"$changed"
  [ -n "$(find "$HOME_DIR/data" "$HOME_DIR/state" -type f -newer "$BASE/marker")" ] || fail "the machinery did write its records under data/ and state/"
  pass "the vitals, the signals check, the progress report, the leader's steer and trim order, the door relay, the keep-set, the task card and the trim event leave every file outside data/ and state/ byte-identical: the worktrees, their memory files and harness settings, the user-level config, the project and the briefs"
}

test_only_the_trim_hooks_speak_into_the_head
test_the_machinery_writes_only_under_data_and_state

echo "# all fm-memory-append-law tests passed"
