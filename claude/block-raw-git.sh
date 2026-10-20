#!/bin/bash

# Pre-tool hook that refuses plain `git add` and `git commit`, so agents
# commit through git flock-commit. Works as:
#   - a Claude Code PreToolUse hook (matcher: Bash): exit 2 + stderr blocks
#   - a ChipAgents pre_tool_use hook (blocking = true): a non-zero exit
#     blocks, and the {"block": true, "message": ...} line on stdout explains
#     why. Measured on ChipAgents 0.42.3: pre_tool_use fires in normal mode,
#     tool_name is exactly "Bash", and tool_input.command is the whole shell
#     line the agent built (e.g. `cd x && git add f; echo rc=$?`).
# Best effort: it inspects the command text, so it is a guard rail, not a
# sandbox.

# Escape a string for a JSON string literal. A raw newline, tab or other
# control character inside a JSON string makes the whole reply unparseable,
# and an unparseable block is silently ignored by the agent.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

input=$(cat)
# Look at the command only, not its description; fall back to the raw input
# when jq is missing or the command field has another name.
cmd_text=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2> /dev/null)
[[ -n "$cmd_text" ]] || cmd_text="$input"

if printf '%s' "$cmd_text" | grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+(add|commit)([^[:alnum:]_-]|$)'; then
  message='Plain "git add" / "git commit" is blocked: several agents share this repository.
Commit only your own files with: git flock-commit -m "<message>" -- <file>...'
  echo "$message" >&2
  printf '{"block": true, "message": "%s"}\n' "$(json_escape "$message")"
  exit 2
fi
exit 0
