# git-flock-kit: serialized git commits for multiple AI agents

When several AI agents share **one** git repository, they hit two different problems:

1. **`index.lock` collisions.** `fatal: Unable to create '.git/index.lock': File exists`.
2. **Mixed commits.** Agent A runs `git add a.c`, then agent B runs `git commit`, and B's commit now contains A's file. A's own commit then finds nothing to commit.

Here is the measured result on this PC: 8 agents, 5 commits each, all running at the same time (`selftest.sh`):

```
plain            commits  13/40   failed  27  index.lock errors   4  mixed commits  12  incomplete files  2  uncommitted  2
flock-commit     commits  40/40   failed   0  index.lock errors   0  mixed commits   0  incomplete files  0  uncommitted  0
```

Target platform: **CentOS 8** (bash 4.4, util-linux `flock`, git 2.27 or newer).

## What's in the kit

| Path | What it is |
|---|---|
| `bin/git-flock` | Runs any git command (or any program) while holding one repository-wide lock |
| `bin/git-flock-commit` | Stages and commits **only the named paths** as one locked, atomic step |
| `bin/git-flock-autocommit` | End-of-turn helper: commits the given files through `git flock-commit`, and does nothing when none changed |
| `install.sh` | Installs the two scripts, and optionally safegit |
| `selftest.sh` | Starts N parallel fake agents and compares plain git against `git flock-commit` |
| `claude/` | Claude Code integration: a CLAUDE.md snippet plus a hook that blocks plain `git add`/`git commit`. The hook is installed as `git-flock-guard` and also works in ChipAgents |
| `chipagents/` | ChipAgents integration: a `hooks.toml` snippet (end-of-turn auto-commit plus guard) and a rules file |
| `vendor/safegit/` | **safegit 0.33.0**: the one ready-made public tool for this problem. Linux amd64 binary (SHA-256 verified) plus source |
| `vendor/git-wait/` | **git-wait** source, for reference only. Not recommended (see the comparison below) |

## Deploy on CentOS 8

Copy the kit to the server, using the tarball or the folder:

```bash
scp git-flock-kit.tar.gz user@centos-host:~
```

Then, on the server:

```bash
tar xzf git-flock-kit.tar.gz && cd git-flock-kit
sudo bash install.sh                  # -> /usr/local/bin for all users
# or: bash install.sh ~/.local/bin    # just you, no root needed
# or: sudo bash install.sh --with-safegit   # also install safegit
bash selftest.sh                      # should end with PASS
```

`flock` comes from `util-linux`, which is always installed on CentOS 8. If `dnf install` fails because CentOS 8 is end-of-life, point the repos at `vault.centos.org`.

## Usage

### Commit your own files: `git flock-commit`

```bash
git flock-commit -m "fix UART baud divider" -- rtl/uart.v tb/uart_tb.sv
```

- `git flock-commit` stages and commits **exactly** these paths under the lock. New, modified and deleted files are all handled.
- Anything another agent has staged stays staged and is **not** included.
- Other `git commit` options pass through, for example `--author`, `-q`, `-s` and `--no-verify`.
- It refuses `-a`, `--amend`, `-i` and `-p`, because they would sweep up or rewrite other agents' work.
- Exit code 1 with "nothing to commit" means those paths have no changes.

### Every other git command that writes: `git flock`

```bash
git flock pull --rebase
git flock push origin HEAD
git flock merge feature/x
git flock stash push -- rtl/uart.v
git flock -C /path/to/repo checkout -b agent-3/work
```

- Read-only commands skip the lock and run immediately: `log`, `show`, `diff`, `blame`, `grep`, `ls-files`, `ls-tree`, `cat-file`, `rev-parse`, `describe`, `shortlog`.
- To run a multi-step script under one lock, use `--exec`:

```bash
git flock --exec sh -c 'git fetch && git rebase origin/main && git push'
```

### Exit codes and settings

| Item | Meaning |
|---|---|
| exit `75` | Timed out waiting for the lock. The repository was busy; retry |
| other exit codes | git's own exit code, passed through |
| `GIT_FLOCK_TIMEOUT` | Seconds to wait for the lock (default `300`) |

## Using it with Claude Code agents

1. Append `claude/CLAUDE.md.snippet` to the repository's `CLAUDE.md`. It tells every agent to commit with `git flock-commit` and to run other write commands through `git flock`.
2. Optionally, enforce it with a hook. The hook uses `jq` if it is installed (`dnf install jq`), and otherwise falls back to scanning the raw input.

   ```bash
   mkdir -p .claude/hooks
   cp claude/block-raw-git.sh .claude/hooks/
   # merge claude/settings.json.snippet into .claude/settings.json
   ```

   The hook blocks `git add …` and `git commit …` and lets `git flock-commit`, `git flock …` and read-only commands through. It works by checking the command text, so treat it as a guard rail rather than a sandbox.

## Using it with ChipAgents agents

`install.sh` also installs `git-flock-autocommit` and `git-flock-guard`.

1. **Rules:** copy `chipagents/rules/git-flock.md` into the repository's ChipAgents rules directory. That's typically `.chipagents/rules/`; confirm the path on the ChipAgents Rules page.
2. **Hooks:** append `chipagents/hooks.toml.snippet` to the repository's `.chipagents/hooks.toml`, then check it:

   ```bash
   chipagents validate .chipagents/hooks.toml
   ```

   The snippet adds two hooks:

   | Hook | What it does |
   |---|---|
   | `end_turn` → `git-flock-autocommit … {{FILES}}` | At the end of each turn, commits only the files that agent edited, under the lock |
   | `pre_tool_use` → `git-flock-guard` (`blocking = true`) | Refuses plain `git add` / `git commit` from the agent's shell (ChipAgents' shell tool is `Bash`, confirmed from real transcripts). **Client-agent mode only.** |

### Don't use ChipAgents' built-in `git_commit` hook with several agents on one repository

- It runs `git add` + `git commit` on the shared index, so concurrent agents race on `index.lock`.
- With `squash = true`, it amends the previous commit by the same author. When all agents share an author (for example the documented `ChipAgents <noreply@chipagents.ai>`), one agent can amend **another agent's** commit.
- If you keep it for a single-agent repository, that's fine.
- With several agents, use the `end_turn` snippet above instead. The trade-off: the commit message is a fixed string, not the LLM-written message `git_commit` produces.

### Shell note

ChipAgents runs bash hooks with `$SHELL`, which is often tcsh in EDA environments. The snippet's commands are plain words and double-quoted strings, so they behave the same in tcsh. Avoid `!` inside hook commands, because tcsh treats it as history expansion.

## How it works

- **One lock per repository:** `$(git rev-parse --git-common-dir)/git-flock.lock`. The common dir is shared by every worktree of the repository, so worktrees serialize against each other too.
- **Kernel lock (`flock(2)`), not a lock file:** the kernel releases it when the process dies, even on `kill -9`, so it never goes stale. This was tested.
- **`flock -o`:** git's background `gc --auto` does not inherit the lock and keep holding it.
- **No deadlock on re-entry:** `GIT_FLOCK_HELD` is set while the lock is held. A nested call, for example from a git hook, runs directly instead of waiting on itself.
- **Fallback when util-linux `flock` is missing** (for example Git Bash on Windows): the same lock is taken through perl's `flock`. That fallback is what the Windows test above used.

## Options compared

| Option | Prevents index.lock races | Prevents mixed commits | Needs | Verdict |
|---|---|---|---|---|
| **One git worktree per agent** (`claude --worktree <name>`, Claude Code 2.1.49+) | ✅ separate index per agent | ✅ separate branch per agent | nothing | **Best when agents can work on separate branches.** Merge back with `git flock merge` |
| **git-flock / git-flock-commit** (this kit) | ✅ | ✅ when agents use `flock-commit` | bash, util-linux, git | **Use when agents must share one working tree.** Tested here |
| **safegit 0.33.0** (`vendor/safegit`) | ✅ temporary index per commit | ✅ compare-and-swap ref update with retry | one static binary | Most complete design, but **brand new (2026-10-10, 0 stars, one maintainer)**. Not tested here. Evaluate before relying on it |
| **git-wait** (`vendor/git-wait`) | ⚠️ waits until `index.lock` disappears, then runs git; two waiters can still collide | ❌ | Rust toolchain | Not recommended: racy, ignores worktrees, last updated 2024 |

### safegit quick reference (from its README)

```bash
sudo bash install.sh --with-safegit
cd your-repo
safegit commit -m "add feature X" -- src/foo.c src/bar.c   # atomic, isolated commit
safegit push --refs head
safegit undo              # reverse the last safegit operation (it keeps an op log)
safegit doctor            # health check; --action uninstall removes .git/safegit/
safegit unlock            # release a lock left by a killed safegit
```

- safegit creates `.git/safegit/` on first use.
- `commit` works with the git that CentOS 8 ships. Its `merge`, `cherry-pick` and `revert` need git 2.38 to 2.43.
- No pip or npm package of it is published. The `safegit` package on npm is an **unrelated** project.

## Repositories on NFS shared by several hosts

If agents on **different machines** share one repository over NFS:
- The Linux NFS client turns `flock()` into NFS byte-range locks, so the lock works across hosts.
- The exception is mounts with `nolock` or `local_lock=flock` / `local_lock=all`. Check with `grep nfs /proc/mounts`.

Quick cross-host check:

```bash
# host A
git flock --exec sleep 30
# host B, within those 30 s: must print a timeout and exit 75
GIT_FLOCK_TIMEOUT=3 git flock tag probe; echo $?
```

## Test status

Tested on Windows Git Bash with git 2.47 and the perl `flock` fallback:
- The 8-agent self-test above.
- Initial commit in an empty repository.
- New, modified and deleted files committed together.
- Another agent's staged file left out of the commit and still staged.
- Running from a subdirectory, and with `-C`.
- Refused options.
- Timeout returns exit 75.
- Lock released after `kill -9` of the holder.
- Read-only commands not blocked while the lock is held.
- The hook's allow/block cases.

Also tested here:
- `git-flock-autocommit` handles no files, unchanged files, a new + modified mix and ignored files.
- `git-flock-guard` works with Claude-style and ChipAgents-style payloads. It returns exit 2 plus a valid `{"block": true, ...}` JSON line on stdout.

**Not yet run on CentOS 8 / util-linux `flock`, and not yet run inside ChipAgents.** Run `bash selftest.sh` there first, then try the hooks with `chipagents validate`.

## Sources

- safegit: https://github.com/smm-h/safegit (release v0.33.0, MIT)
- git-wait: https://github.com/darshanparajuli/git-wait (MIT)
- Claude Code worktrees for parallel agents: https://www.developersdigest.tech/blog/git-worktrees-claude-code-parallel-agents-guide

## License

MIT for the files written for this kit (see `LICENSE`). safegit (`vendor/safegit`) and git-wait (`vendor/git-wait`) are MIT-licensed by their authors.

## Author

Chih-Hsueh "Josh" HUANG
