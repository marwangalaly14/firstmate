#!/usr/bin/env bash
# bin/fm-compact-lib.sh - the 140K line: where a story crewmate's harness trims
# its own head, derived in one place.
#
# Sourced by bin/fm-spawn.sh (which writes the line into a claude story
# crewmate's worktree .claude/settings.local.json and records trim_mark= and
# trim_window= in state/<id>.meta) and by the tests that pin the arithmetic.
# Nothing else may spell the window or the settings key; a reader that needs
# the mark behind a recorded window uses fm_compact_mark_of_window.
#
# The harness law, read from Claude Code 2.1.259's binary on 2026-09-05 and
# proved live twice on the GLM stand-in (data/epic-crewmate-memory/probes):
#   window    = min(model window, configured)   configured: env
#               CLAUDE_CODE_AUTO_COMPACT_WINDOW, else the settings key
#               autoCompactWindow (local project settings win over user
#               settings), else client data, experiment, model default
#   trims at  count >= window - min(model max output, 20000) - 13000
#   count     = the last reply's usage (input + cache creation + cache read +
#               output) plus the text appended since, estimated at 4 chars per
#               token for Claude 3, 4.0, 4.1, 4.5 and 4.6 model ids and at 3
#               for every other id; checked before each request, so a request
#               above the line is never sent - it is folded into the summary.
#   preTokens on the compact_boundary row is that count at 4 chars per token,
#               so a big pending batch can record above or below the line while
#               the last real head (the last assistant usage before the row)
#               stayed under it; readers measure the head, not preTokens.
#   The harness's earlier "precomputed" trim (window x 0.8) arms only when no
#   window is configured or the configured window is at least 200000, so a
#   story crewmate's 173000 line leaves the 140K line as the only trigger.
#   autoCompactThreshold is not a settings key; the binary reads no such thing.
#
# So the one settings key that puts the trim at the captain's 140K line is
#   autoCompactWindow = 140000 + 20000 + 13000 = 173000
# for a story crewmate; a leader (bin/fm-spawn.sh --leads) keeps the harness's
# own window because the epic's whole shape lives in its head. Nothing here
# stops, warns or throttles a crewmate: the harness trims every session
# somewhere, and this only moves that point from its default (167000 for an
# assumed 200K model, 267000 for a 300K one) to the line the captain named.
#
# The keep-set is the other half: what every trim's summary must keep. The
# harness runs a PreCompact hook before each trim, automatic or manual, and
# appends the hook's stdout to the summarizer's own instructions under
# "Additional Instructions" (read from the same binary: the compaction runs
# the hooks, joins their output to any /compact focus, and builds the summary
# request from that). The spawn installs bin/fm-compact-keep.sh there, which
# prints fm_compact_keep_set; the crewmate's own context never carries it.
#
# fm_compact_keep_set                   -> the keep-set text, for the summarizer
# fm_compact_window                     -> 173000, the window for FM_COMPACT_MARK
# fm_compact_window_for_mark <mark>     -> <mark> + reserved output + margin
# fm_compact_mark_of_window <window>    -> <window> - reserved output - margin
# fm_compact_check_window <window>      -> 0 when <window> is exactly the derived
#                                          window for FM_COMPACT_MARK; otherwise
#                                          one refusal line on stderr and 1

FM_COMPACT_MARK=140000
FM_COMPACT_RESERVED_OUTPUT=20000
FM_COMPACT_MARGIN=13000
# shellcheck disable=SC2034 # The key's one spelling, read by bin/fm-spawn.sh and the tests.
FM_COMPACT_SETTINGS_KEY=autoCompactWindow

fm_compact__is_count() {  # <value> -> 0 when a non-empty decimal integer
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

fm_compact_window_for_mark() {  # <mark>
  local mark=${1:-}
  fm_compact__is_count "$mark" || { echo "error: a mark is a token count, got '${mark}'" >&2; return 1; }
  echo $((mark + FM_COMPACT_RESERVED_OUTPUT + FM_COMPACT_MARGIN))
}

fm_compact_window() {
  fm_compact_window_for_mark "$FM_COMPACT_MARK"
}

fm_compact_mark_of_window() {  # <window>
  local window=${1:-} floor
  fm_compact__is_count "$window" || { echo "error: a window is a token count, got '${window}'" >&2; return 1; }
  floor=$((FM_COMPACT_RESERVED_OUTPUT + FM_COMPACT_MARGIN))
  [ "$window" -gt "$floor" ] || { echo "error: window $window leaves no head below the harness's $floor reserved output and margin" >&2; return 1; }
  echo $((window - floor))
}

fm_compact_check_window() {  # <window>
  local window=${1:-} derived
  derived=$(fm_compact_window)
  fm_compact__is_count "$window" || { echo "error: a window is a token count, got '${window}'" >&2; return 1; }
  [ "$window" -eq "$derived" ] || {
    echo "error: window $window is not the derived window $derived ($FM_COMPACT_MARK + $FM_COMPACT_RESERVED_OUTPUT + $FM_COMPACT_MARGIN); the line is written from bin/fm-compact-lib.sh, never by hand" >&2
    return 1
  }
  return 0
}

fm_compact_keep_set() {
  cat <<'EOF'
Keep verbatim, whatever else is dropped:
- the story's acceptance criteria (the brief's Definition of done and any acceptance list), word for word;
- the exact current failing test or error and its output;
- the last decision taken and its reason;
- every file changed so far and why;
- every instruction received and not yet done.
Drop the contents of files already committed, exploration that led nowhere, and tool output older than the last decision.
EOF
}
