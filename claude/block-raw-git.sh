#!/bin/bash

# Pre-tool hook that refuses plain `git add` and `git commit`, so agents
# commit through git flock-commit. Works as:
#   - a Claude Code PreToolUse hook (matcher: Bash): exit 2 + stderr blocks
#   - a ChipAgents pre_tool_use hook (blocking = true): non-zero exit blocks,
#     and the {"block": true, "message": ...} line on stdout explains why
# Best effort: it inspects the command text, so it is a guard rail, not a
# sandbox.

input=$(cat)
# Look at the command only, not its description; fall back to the raw input
# when jq is missing or the command field has another name.
cmd_text=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2> /dev/null)
[[ -n "$cmd_text" ]] || cmd_text="$input"

if printf '%s' "$cmd_text" | grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+(add|commit)([^[:alnum:]_-]|$)'; then
  message='Plain "git add" / "git commit" is blocked: several agents share this repository. Commit only your own files with: git flock-commit -m "<message>" -- <file>...'
  echo "$message" >&2
  printf '{"block": true, "message": "%s"}\n' "$(printf '%s' "$message" | sed 's/["\\]/\\&/g')"
  exit 2
fi
exit 0
