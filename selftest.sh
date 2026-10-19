#!/bin/bash

# selftest.sh: simulate several AI agents committing to ONE repository at the
# same time. Runs the same workload twice, with plain git and with
# git flock-commit, and reports lost, failed and mixed-up commits.
#
#   ./selftest.sh [agents=8] [commits-per-agent=5]
#
# Exit status is 0 when the git flock-commit run is clean.

set -uo pipefail

agents="${1:-8}"
per_agent="${2:-5}"
here="$(cd "$(dirname "$0")" && pwd)"
export PATH="$here/bin:$PATH"

run() {
  local mode="$1" work repo
  work="$(mktemp -d)"
  repo="$work/repo"
  git init -q "$repo"
  git -C "$repo" config user.name selftest
  git -C "$repo" config user.email selftest@example.invalid
  git -C "$repo" commit -q --allow-empty -m init

  for ((a = 1; a <= agents; a++)); do
    (
      cd "$repo" || exit 1
      for ((c = 1; c <= per_agent; c++)); do
        echo "agent $a commit $c" >> "agent$a.txt"
        if [[ "$mode" == plain ]]; then
          git add "agent$a.txt" && git commit -q -m "agent$a #$c"
        else
          git flock-commit -q -m "agent$a #$c" -- "agent$a.txt"
        fi > /dev/null 2>> "$work/errors.log" || echo x >> "$work/failed"
      done
    ) &
  done
  wait

  local expected commits failed lock_errors mixed incomplete leftover
  expected=$((agents * per_agent))
  commits=$(($(git -C "$repo" rev-list --count HEAD) - 1))
  failed=$(cat "$work/failed" 2> /dev/null | wc -l)
  lock_errors=$(grep -c 'index.lock' "$work/errors.log" 2> /dev/null)
  # A commit is "mixed" when it contains a file of another agent.
  mixed=$(git -C "$repo" log --format='@%s' --name-only HEAD | awk '
    /^@/ { subject = substr($0, 2); split(subject, part, " "); own = part[1] ".txt"; next }
    NF && subject != "init" && $0 != own { bad[subject] = 1 }
    END { n = 0; for (s in bad) n++; print n }')
  incomplete=0
  for ((a = 1; a <= agents; a++)); do
    lines=$(git -C "$repo" show "HEAD:agent$a.txt" 2> /dev/null | wc -l)
    [[ "$lines" -eq "$per_agent" ]] || incomplete=$((incomplete + 1))
  done
  leftover=$(git -C "$repo" status --porcelain | wc -l)

  printf '%-16s commits %3d/%-3d  failed %3d  index.lock errors %3d  mixed commits %3d  incomplete files %2d  uncommitted %2d\n' \
    "$mode" "$commits" "$expected" "$failed" "$lock_errors" "$mixed" "$incomplete" "$leftover"

  if [[ -n "${KEEP:-}" ]]; then
    echo "  kept: $work"
  else
    rm -rf "$work"
  fi

  [[ $commits -eq $expected && $failed -eq 0 && $mixed -eq 0 && $incomplete -eq 0 && $leftover -eq 0 ]]
}

echo "git $(git --version | awk '{print $3}'), flock: $(command -v flock || echo 'none (perl fallback)'), $agents agents x $per_agent commits"
run plain || true
if run flock-commit; then
  echo "PASS: git flock-commit kept every agent's commits separate and complete"
else
  echo "FAIL: git flock-commit run was not clean (rerun with KEEP=1 to inspect)"
  exit 1
fi
