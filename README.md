# agentfixer

Point it at a git repo. It audits the code with two independent Claude agents,
re-verifies every finding in a fresh context, fixes the confirmed ones, opens a
PR, drives it to green CI, and merges. Repeat N times.

Every pipeline step is a separate `claude -p` process, so each one starts with
a clean context and can't be talked out of what it's supposed to check. Merge
policy, retry caps, and tamper gates are shell conditionals — not instructions
in a prompt an agent could be argued out of.

## Install

Clone into the directory that holds the repos you want to run agentfixer
against, and symlink the script one level up:

```bash
git clone git@github.com:<you>/agentfixer.git ~/git/agentfixer
ln -s ~/git/agentfixer/agentfixer.sh ~/git/agentfixer.sh
```

agentfixer resolves its own real path and, if that path is inside a git repo,
treats that repo's *parent* directory as the workspace — the set of sibling
repos it will offer to run against. The symlink above works because
`~/git/agentfixer.sh` resolves to `~/git/agentfixer/agentfixer.sh`, whose
repo's parent is `~/git`. It never lists itself as a target — the exclusion
is the repo its own resolved path lives in, whatever that repo is called, so
an unrelated repo that happens to be named `agentfixer` is still offered.

Requires `claude`, `gh` (authenticated — `gh auth login`), `jq`, and `git`.
`fzf` is required for the interactive repo picker; `tmux` is required only
when you select two or more repos at once. `bwrap` (bubblewrap) is required
for every write-mode step unless you pass `--no-sandbox`.

## Use

```bash
~/git/agentfixer.sh                                  # pick repos, pick N, go
~/git/agentfixer.sh --repo myapp --iterations 5      # headless, one repo
~/git/agentfixer.sh --repo myapp --dry-run           # audit and verify only
~/git/agentfixer.sh --repo myapp --plain --yes       # for cron
```

Flags (`--help` is the source of truth; this list is generated from it):

| flag | meaning |
|---|---|
| `--repo NAME` | repo in the workspace to run against; omit for a picker |
| `--iterations N` | how many audit/fix/merge cycles to run (default 1) |
| `--workspace DIR` | directory holding the repos (default: parent of this repo) |
| `--base BRANCH` | base branch (default: the remote HEAD) |
| `--dry-run` | audit and verify only; change nothing |
| `--plain` | line output instead of a live display |
| `--no-sandbox` | run write-mode agents unsandboxed (not recommended) |
| `--yes`, `-y` | skip the confirmation prompt |
| `--version` | print the version and exit |
| `--help`, `-h` | print this usage and exit |

`--dry-run` stops after verification and prints what it would have fixed; it
never opens a PR.

Selecting two or more repos in the picker opens a tmux session with one
window per repo, each running headlessly. Detach with `C-b d`; the runs keep
going. Selecting one repo runs in the foreground, no tmux involved.

**`--repo` skips the confirmation screen and cost estimate.** They only
appear in the interactive picker (`--yes` suppresses them there). A headless
`--repo` run — the form you'd use from cron — starts immediately with no
prompt, so know your `--iterations` and budget before you script it.

## Branch protection is required

Two separate checks enforce this, both hard failures:

- **Preflight** (`af_preflight`) refuses to start if the base branch is not
  reported as `protected` by the GitHub API.
- **The merge gate** (G3) refuses to merge a PR whose *required* status
  checks are an empty set — a repo can be "protected" with no required
  checks configured, and CI reporting green then means nothing was actually
  gated on.

Green with nothing to be green about is not evidence, and this tool's last
step is a merge. Enable branch protection at
`https://github.com/<owner>/<repo>/settings/branches`, requiring at least one
status check.

## Sandbox: what it protects, and what it does not

Write-mode steps (`fix`, and `cifix` when repairing a failing CI run) run
under `bwrap` with `--permission-mode bypassPermissions` — they read
untrusted repository content and can act on it with no human in the loop, so
a prompt injection there has unrestricted Bash. Read-only steps (both
auditors, combine, verify) are never sandboxed: they can't write anything,
and they need the real `~/.claude/skills` on disk to resolve `/security-audit`
and `/hostile-review`.

**What the sandbox protects**, precisely:

- `$HOME` is masked by an empty tmpfs, then three things are re-exposed inside
  it: `$HOME/.claude` (read-only, so its `settings.json` can't be poisoned to
  run hooks on your next `claude` session), the run's own worktree
  (read-write), and the target repository's own `.git` directory (read-only —
  see below). `~/.ssh`, `~/.config/gh`, `~/.aws`, shell history, and any
  *other* repo checked out under `$HOME` are unreadable from inside the
  sandbox.
- GitHub and SSH credentials (`GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`,
  `GITHUB_ENTERPRISE_TOKEN`, `SSH_AUTH_SOCK`, `GH_CONFIG_DIR`, plus AWS keys)
  are stripped from the write-mode agent's environment unconditionally, even
  with `--no-sandbox`. The agent never needs them: bash performs every `git`
  push and `gh` call in this tool, never the agent.

**What it does not protect, stated just as plainly:**

- **Network egress is open and cannot be closed.** The agent process is
  itself an LLM API client; `--unshare-net` would break `claude` outright.
  This is an accepted residual risk, not an oversight — a prompt injection
  can still exfiltrate over the network.
- Everything **outside** `$HOME` is bound read-only (`--ro-bind / /`), not
  hidden. `/etc` and any repository not checked out under `$HOME` remain
  readable from inside the sandbox.
- **The target repository's full git history is readable inside the sandbox.**
  A `git worktree`'s `.git` is only a pointer file into
  `<repo>/.git/worktrees/<name>`, which the tmpfs would otherwise hide — and
  with it hidden, *every* git command inside the sandbox fails with `not a
  git repository`, so the agent cannot run a test suite that shells out to
  git, read history, or diff its own work. That directory is therefore bound
  back in **read-only**: the agent can read the whole history and config of
  the repo it is already editing, and can write neither. Nothing but bash
  ever writes git state.
- Read-only steps run with no sandbox at all, by design (see above).

`$HOME` inside the sandbox is a writable but *empty* tmpfs, so toolchains
that want `~/.npm`, `~/.cargo`, or `~/.m2` still work — they just start from
nothing and re-download every run. That per-run slowdown is the tradeoff for
`~/.ssh` and friends being unreadable, not a bug.

`--no-sandbox` runs write-mode steps unconfined (credentials are still
scrubbed) and prints a loud warning first. It exists for environments where
`bwrap` genuinely can't run (e.g. no unprivileged user namespaces); it is not
recommended.

## What it will not do

- Push to a branch directly. It only opens PRs.
- Create or modify anything under `.github/`. An agent that can edit
  workflows can make CI green by deleting the tests, so a deterministic diff
  check (G1) aborts the run the moment a changed or committed path starts
  with `.github` — working-tree changes before a commit, and the full commit
  range before a merge, are both checked, including renames into or out of
  `.github/`.
- Force push. Ever.
- Touch your working tree. All work happens in a throwaway git worktree
  under `~/.cache/agentfixer/<repo>/<timestamp>/worktree` (override the cache
  root with `AF_CACHE`); your existing checkout is never touched.
- Delete a worktree that holds unmerged commits or uncommitted changes. Only
  a worktree that is both clean and fully merged into the base is removed
  when a run ends; anything else is left in place with a message pointing at
  it, so a run that dies mid-flight loses nothing.

## Exit codes

| code | meaning |
|---|---|
| 0 | completed |
| 1 | usage error, or a preflight check failed before the run started — nothing was spent |
| 2 | CI could not be made green (timed out, or exhausted its retries); the PR is left open, labelled `needs-human` |
| 3 | a safety gate tripped mid-run: `.github/` was touched (G1), the changed-path list behind G1 could not be read at all, the PR has zero required checks (G3), their state could not be read at all (G3 — a `gh` error is not evidence of anything, so it refuses), the merge-time recheck of required checks finds them not passing (G3), the merge itself was refused by GitHub, or `bwrap` is unavailable for a write-mode step and `--no-sandbox` wasn't passed |
| 4 | an agent returned invalid, incomplete, or non-schema-conforming output — includes the verify/fix id-set mismatch (G2) and `combine` inventing non-canonical ids |

Codes 2–4 can fire after real spend has already happened (audit and verify
always run, and cost money, before the first write-mode step); code 1 never
does — every preflight check runs before anything else, so a code-1 exit is
always a zero-spend exit. A missing `bwrap` is code 3, not code 1, precisely
because it's only ever checked at the first write-mode step (`fix`), by which
point audit, combine, and verify have already spent budget — calling that
"nothing was spent" would be false.

## Cost

Each step has a `--max-budget-usd` cap. At the defaults (2 audits × $3,
combine $1, verify $3, fix $6, plus up to 3 cifix retries × $3), worst case
is **$25 per repo, per iteration**. The interactive confirmation screen
multiplies that by the number of repos selected and the iteration count and
shows the total before anything starts — but only in the interactive picker;
see the `--repo` note above.

Override the defaults with environment variables:

| variable | default | controls |
|---|---|---|
| `AF_BUDGET_AUDIT` | 3 | each of the two parallel auditors |
| `AF_BUDGET_COMBINE` | 1 | merging the two findings lists |
| `AF_BUDGET_VERIFY` | 3 | re-verification |
| `AF_BUDGET_FIX` | 6 | applying fixes |
| `AF_BUDGET_CIFIX` | 3 | each CI-repair attempt |
| `AF_CI_RETRIES` | 3 | max cifix attempts before giving up (exit 2) |
| `AF_MODEL_AUDIT`, `AF_MODEL_COMBINE`, `AF_MODEL_VERIFY`, `AF_MODEL_FIX`, `AF_MODEL_CIFIX` | opus/sonnet/opus/opus/sonnet | model per step |
| `AF_CACHE` | `~/.cache/agentfixer` | where worktrees and run logs live |
| `AF_CI_TIMEOUT` | 1800 (seconds) | how long to wait for CI to settle |
| `AF_BASE` | the remote HEAD | base branch, same as `--base` |

`AF_BASE` is the one setting that is *also* a flag, and `--base` simply sets
it. Unlike the run's internal state (worktree, branch, sandbox), `af_main`
does not reset it, so an `AF_BASE` exported in your shell or crontab applies
to every repo in the run — including ones whose default branch is something
else. Prefer `--base` unless you mean exactly that.

## Development

```bash
bats tests/
shellcheck agentfixer.sh tests/stubs/*
```

Tests stub `claude` and `gh` on `PATH` and run against real temporary git
repos. `git` is never stubbed — git behaviour is what needs proving.
