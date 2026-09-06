#!/usr/bin/env bash
# tests/transcript-helpers.sh - synthetic transcript rows, worktrees and
# mtimes for the suites that read a crewmate from the outside
# (fm-crew-vitals, fm-crew-signals). The rows are the harness's own shapes:
# an assistant row carries its usage and, when the model called a tool, the
# tool_use block; a user row is a prompt or a tool result; a compact_boundary
# system row is a trim. Sourced after tests/lib.sh.

iso() {  # <epoch> -> ISO timestamp with milliseconds, as the harness writes it
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null; then return 0; fi
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z
}

# Transcript rows, one per line, in the harness's own shapes.
row_assistant() {  # <epoch> <msg-id> <in> <cc> <cr> <out> [<tool-use json>...]
  local ts id in cc cr out content
  ts=$(iso "$1"); id=$2; in=$3; cc=$4; cr=$5; out=$6
  shift 6
  content='[{"type":"text","text":"ok"}]'
  if [ $# -gt 0 ]; then
    content=$(printf '%s\n' "$@" | jq -s -c '.')
  fi
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","message":{"id":"%s","role":"assistant","content":%s,"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$id-$RANDOM" "$ts" "$id" "$content" "$in" "$cc" "$cr" "$out"
}
tool_bash() { printf '{"type":"tool_use","id":"t%s","name":"Bash","input":{"command":"%s","description":"%s"}}' "$RANDOM" "$1" "${2:-run it}"; }
tool_task() { printf '{"type":"tool_use","id":"t%s","name":"Task","input":{"prompt":"%s"}}' "$RANDOM" "$1"; }
tool_read() { printf '{"type":"tool_use","id":"t%s","name":"Read","input":{"file_path":"%s"%s}}' "$RANDOM" "$1" "${2:+,\"offset\":$2}"; }
row_boundary() {  # <epoch> <trigger> <pre> <post>
  printf '{"type":"system","subtype":"compact_boundary","uuid":"b-%s","timestamp":"%s","compactMetadata":{"trigger":"%s","preTokens":%s,"postTokens":%s}}\n' "$RANDOM" "$(iso "$1")" "$2" "$3" "$4"
}
row_user() { printf '{"type":"user","uuid":"x-%s","timestamp":"%s","message":{"role":"user","content":"go"}}\n' "$RANDOM" "$(iso "$1")"; }
# The harness's own trim summary: a user row that follows a compaction rather
# than asking the model for anything (the shape tests/fm-trim-event.test.sh
# models as row_summary). isMeta rows carry the same "not a prompt" meaning.
row_summary() { printf '{"type":"user","uuid":"s-%s","timestamp":"%s","isCompactSummary":true,"message":{"role":"user","content":"summary"}}\n' "$RANDOM" "$(iso "$1")"; }
row_meta() { printf '{"type":"user","uuid":"m-%s","timestamp":"%s","isMeta":true,"message":{"role":"user","content":"meta"}}\n' "$RANDOM" "$(iso "$1")"; }
row_noise() { printf '{"type":"file-history-snapshot","messageId":"m"}\n'; }
# A sub-agent's row: the same assistant shape the harness writes for a helper
# a Task dispatched, marked isSidechain. Its turns, its head and its tool
# calls are the helper's, never the crewmate's.
row_sidechain() {  # <epoch> <msg-id> <in> <cc> <cr> <out> [<tool-use json>...]
  row_assistant "$@" | jq -c '. + {isSidechain: true}'
}

make_worktree() {  # <path> <commit-epoch>
  local wt=$1 when=$2
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base --date="@$when" 2>/dev/null \
    || GIT_COMMITTER_DATE="@$when" git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base --date="@$when"
  GIT_COMMITTER_DATE="@$when" git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty --amend --no-edit --date="@$when"
}

set_mtime() {  # <file> <epoch>
  touch -t "$(if date -u -r "$2" +%Y%m%d%H%M.%S 2>/dev/null; then :; else date -u -d "@$2" +%Y%m%d%H%M.%S; fi)" "$1" 2>/dev/null \
    || touch -d "@$2" "$1"
  # touch -t reads local time; set the exact epoch through python when present.
  command -v python3 >/dev/null 2>&1 && python3 - "$1" "$2" <<'PY'
import os, sys
os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))
PY
}

