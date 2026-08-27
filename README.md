# agentfixer

Point it at a git repo. It audits the code with two independent Claude agents,
re-verifies every finding in a fresh context, fixes the confirmed ones, has a
fourth agent review the fix, opens a PR, drives it to green CI, and merges.
Repeat N times.

```
audit ×2 → combine → verify → fix → review ⇄ fix → pr → ci ⇄ cifix → merge
                                       (≤ AF_REVIEW_ROUNDS)  (≤ AF_CI_RETRIES)
```

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

**Multiple workspaces.** If you keep repos in more than one place (say `~/git`
and `~/work`), symlink the script into each — the *symlink's own* directory
defines the workspace, not the target script's repo. A link at `~/work/agentfixer.sh`
operates on `~/work`'s repos, independent of where the real `agentfixer.sh`
checkout lives:

```bash
ln -s ~/git/agentfixer/agentfixer.sh ~/work/agentfixer.sh
```

`--workspace DIR` overrides whichever workspace either rule would pick.

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

## The fix review

Between the fix commit and the PR, a fresh read-only agent is handed two
things — the commit diff for this iteration's fixes, and the confirmed
findings those fixes were supposed to address — and asked, per finding:
does this diff actually fix *that* finding, and does it break anything else?

It is a new `claude -p` process every round, like every other step. That
isolation is the whole point: a reviewer that inherited the fixer's reasoning
about its own work would be reviewing the argument, not the change. It gets
the same `--json-schema` treatment as every other step and the same
completeness gate (G2) — it must return exactly one verdict per finding id,
so it cannot approve a finding by quietly dropping it.

If it objects, the objections go verbatim to a **fresh** fix agent, which
amends the work in place. G1 (no `.github/`) and G2 (no dropped ids) run on
the amended work exactly as they do on the first pass, and the round is
committed on top. Then it is reviewed again. Up to `AF_REVIEW_ROUNDS` review
calls (default 3).

**A later round does not re-litigate what an earlier one approved.** Round 1
reviews every finding. Round 2 onwards reviews what the previous round
rejected, plus any finding whose code the re-fix actually touched; the rest
keep the approval they already earned, carried into the round's output so
that exactly one verdict per finding id still reaches G2. Without this the
loop cannot converge: each round is an independent adversarial read, so a
round that clears the objection it was given is free to reject a *different*
finding it approved last round, round after round, until the cap.

"Touched" is read from the paths the re-fix changed according to git — not
from the agent's own account of what it changed — mapped onto findings
through each finding's own file plus every `files_changed` any fix round
claimed for it. A changed path that maps to no finding at all re-opens every
finding, because an unattributable edit cannot be reasoned about. Adding a
finding to the map never removes another from the scope — a finding's own
file is in the map whatever any agent claims — but note the bound honestly:
an agent that claims a path it had no business touching does convert that
path from unattributable (re-open everything) to attributed (re-open the
claimant), and the residual protection is that the reviewer reads the whole
cumulative diff, stray edit included, while reviewing the claimant. The reviewer is told which findings were settled and why, and asked
not to revisit them; if it volunteers a rejection for one anyway, that
rejection is honoured rather than discarded.

The reviewer's prompt carries an explicit bar in both directions: reject an
incomplete fix, a symptom fix, a weakened test, a new defect, or a diff that
plainly does not address the finding — but **approve** a fix that addresses
the finding and breaks nothing, even one you would have written differently.
Style, naming, structure and "could have been more thorough" are not grounds
for rejection, and the prompt says so, along with what is downstream of the
review (G1, G2, the repository's own required CI, and a human reading the
PR). An earlier version of this prompt told the reviewer only that approving
a bad fix is worse than rejecting a good one, with no counterweight; across
three live runs it never once approved, because a sufficiently adversarial
reader always finds one imperfection somewhere in a multi-file diff.

**If the cap is reached with objections still outstanding**, agentfixer:

- pushes the branch and opens the PR anyway — a human has to be able to see
  what the reviewer refused,
- opens it as a **draft** labelled `needs-human` (see *Halted runs*, below),
- writes the unresolved objections into the PR body under
  `### Fix review` → **Not approved**,
- and **halts the run with exit 3 without merging**. It does not proceed to
  CI or merge, and it does not start another iteration on top of code a
  reviewer never cleared.

Objections are recorded in the PR body **even when a later round resolved
them**, for the same reason this tool already lists the findings *rejected*
during verification: which findings were hard is something the human reading
the PR wants to know.

`AF_REVIEW_ROUNDS=0` disables the stage outright — no reviewer runs, `fix`
goes straight to `pr`, and the PR body says so. It does not mean "review once
and never loop back"; that reading would make `0` a synonym for `1`. The
value is validated before preflight, so a typo is a zero-spend exit 1.

## Halted runs leave a draft PR, never stranded commits

Every PR agentfixer opens on a **halt path is a draft, labelled
`needs-human`**. The only non-draft PR it opens is the happy path's, on its
way to CI and merge.

The reason is that a draft cannot be merged until a human deliberately marks
it ready — precisely the property wanted for work that did not clear its
gates. It is also the reason the work is published at all: a run that dies
after `fix` has already committed leaves real commits in
`~/.cache/agentfixer/<repo>/<timestamp>/worktree`, invisible unless somebody
goes digging.

| halt | what happens to the PR |
|---|---|
| exit 6, upstream API failure (rate limit, session limit, 5xx) | pushed and opened as a draft, if the branch has commits ahead of the base |
| exit 5, budget cap exhausted | same |
| exit 3, review cap reached with objections | opened as a draft |
| exit 2, CI retries exhausted, or CI timed out | the open PR is converted back to a draft (`gh pr ready --undo`) |
| exit 3, no required checks appeared, or their state could not be read | same |
| **exit 3, G1: an agent wrote under `.github/`** | **no PR, nothing pushed** |

**G1 is deliberately excluded.** G1 fires when an agent created or modified
something under `.github/`, which is hostile or malfunctioning output.
Publishing that content to a branch on the remote is the wrong response;
halting with the work quarantined locally is the right one. No `gh pr create`
runs on that path, and nothing reaches the remote.

The halt PR's body opens with a banner stating why the run halted (including
the upstream's own HTTP status and message), which commits are in the branch,
what was *not* done — not reviewed, review rejected it, never reached CI —
and that the draft is deliberate, with a checklist of what to confirm before
marking it ready. agentfixer's ordinary report follows *underneath* the
banner, so a body listing "Fixed" findings can never be mistaken for the
provenance of a clean run.

Opening the rescue PR can itself fail — the session limit that killed the run
may still be in force. When it does, both failures are reported and the run
still exits with the **original** code, never the PR failure's: the reason
the run actually died is the reason the operator needs. The commits stay in
the worktree either way; `af_cleanup_worktree` never deletes a worktree
holding unmerged work, PR or no PR.

Draft support is per-repository and plan-gated on GitHub
(`Repository.planFeatures.draftPullRequests`), so `--draft` and
`gh pr ready --undo` can both be refused. Neither failure is fatal, and
neither is silent.

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

Write-mode steps (`fix`, the re-fix rounds the review loop drives, and
`cifix` when repairing a failing CI run) run under `bwrap` with
`--permission-mode bypassPermissions` — they read untrusted repository
content and can act on it with no human in the loop, so
a prompt injection there has unrestricted Bash. Read-only steps (both
auditors, combine, verify, review) are never sandboxed: they can't write
anything, and they need the real `~/.claude/skills` on disk to resolve `/security-audit`
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
  the repo it is already editing, and cannot write it.
- **The pointer file itself is writable, and is not trusted.** `.git` sits in
  the worktree, which is the one read-write bind, so a write-mode agent can
  rewrite it to name a git directory of its own — one whose `hooks/pre-commit`
  would then run *outside* the sandbox, as your user, when bash commits.
  So bash does not read it: every host-side git command against the worktree
  names `--git-dir` and `--work-tree` explicitly, resolved once before any
  agent ran, and passes `core.hooksPath=/dev/null` so no hook of any
  provenance fires. On top of that, the pointer file's contents are compared
  against what setup wrote before each commit and before each merge; a
  mismatch aborts the run with exit 3.
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
- Merge a fix its reviewer never approved. If the review loop hits
  `AF_REVIEW_ROUNDS` with objections outstanding, a **draft** PR is opened and
  labelled `needs-human`, and the run halts at exit 3 — no CI, no merge, no
  next iteration.
- Leave a mergeable PR behind after a halt. Every PR opened on a halt path is
  a draft labelled `needs-human`; a PR already open when a gate trips is
  converted back to a draft. See *Halted runs*.
- Publish `.github/` tampering. A G1 trip opens no PR and pushes nothing —
  the work stays quarantined in the local worktree.
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
| 2 | CI could not be made green (timed out, or exhausted its retries); the PR is left open, converted back to a **draft** and labelled `needs-human` |
| 3 | a safety gate tripped mid-run: `.github/` was touched (G1), the changed-path list behind G1 could not be read at all, the fix reviewer never approved within `AF_REVIEW_ROUNDS` (G4 — a **draft** PR is opened and labelled `needs-human`, nothing merged), the PR has zero required checks (G3 — the PR is converted back to a draft and labelled `needs-human`), their state could not be read at all (G3 — a `gh` error is not evidence of anything, so it refuses), the merge-time recheck of required checks finds them not passing (G3), the merge itself was refused by GitHub, or `bwrap` is unavailable for a write-mode step and `--no-sandbox` wasn't passed |
| 4 | an agent returned invalid, incomplete, or non-schema-conforming output — includes the verify/fix id-set mismatch (G2) and `combine` inventing non-canonical ids |
| 5 | a step hit its `--max-budget-usd` cap. Nothing is malformed — the output just wasn't finished. The message names the step, the cap, the spend, and the `AF_BUDGET_*` variable to raise (see Cost below). Work already committed is preserved as a draft PR |
| 6 | the Claude API could not complete a call — a rate limit, a session limit, a 5xx. The message names the step, the HTTP status, and the upstream's own reason. Nothing agentfixer or the repository produced was rejected; committed work is preserved as a draft PR labelled `needs-human` (see *Halted runs*) and the run can be re-run once the limit clears |

Codes 2–6 can fire after real spend has already happened (audit and verify
always run, and cost money, before the first write-mode step); code 1 never
does — every preflight check runs before anything else, so a code-1 exit is
always a zero-spend exit. A missing `bwrap` is code 3, not code 1, precisely
because it's only ever checked at the first write-mode step (`fix`), by which
point audit, combine, and verify have already spent budget — calling that
"nothing was spent" would be false.

An unapproved fix review is code 3 rather than a code of its own: the
reviewer's output was perfectly well-formed (so not 4), CI never ran (so not
2), and the operator response is identical to the existing code-3 CI-gate
paths — go look at the `needs-human` PR. A gate that did not open is a gate
that did not open, and the exit codes are a contract worth not inflating.

Code 5 is deliberately distinct from code 4: a cron log reading "exit 4"
should send someone looking for a schema bug, and a budget cap running out
is not one — it's an operational limit that needs a bigger number, not a
fix to agentfixer's output validation.

Code 6 is distinct for the same reason and is the one code nothing in this
tool or your repository caused: the upstream call failed. Two live runs
ended this way mid-review-loop, on a 429 session limit, and both reported
"agent reported failure" with exit 4 — which is what code 6 exists to stop.

## Cost

Each step has a `--max-budget-usd` cap. At the defaults (2 audits × $3,
combine $1, verify $3, fix $6, up to 3 review rounds × $3 and the 2 re-fixes
those rounds can cost × $6, plus up to 3 cifix retries × $3), worst case is
**$46 per repo, per iteration**.

**The review stage costs at least one extra agent call per iteration**, and
at most `AF_REVIEW_ROUNDS` reviews plus `AF_REVIEW_ROUNDS - 1` re-fixes — 3
reviews and 2 re-fixes at the defaults, so 5 extra calls worst case, 1 in the
common case where the first review approves. Set `AF_REVIEW_ROUNDS=0` to turn
the stage off and get the old $25 ceiling back. The interactive confirmation screen
multiplies that by the number of repos selected and the iteration count and
shows the total before anything starts — but only in the interactive picker;
see the `--repo` note above.

**These defaults are sized for small repositories.** A real codebase gives
its auditors and verifier more to look at, and they will run into the cap
and exit 5 (see Exit codes above) well before they've finished. Raise the
cap for the step that's running out, per repo or per run:

```sh
AF_BUDGET_VERIFY=8 AF_BUDGET_FIX=12 ./agentfixer.sh --repo kypost-server
```

**On a Claude subscription (Pro/Max), these dollar figures are notional.**
`--max-budget-usd` caps API spend; a subscription isn't billed per API call,
so the cap still fires — you'll see exit 5 — but the number it enforces
against isn't money leaving your account. Raising the specific
`AF_BUDGET_*` above works, but if you don't want per-step ceilings at all,
remove them outright with `--no-budget` (or `AF_BUDGET=off`):

```sh
agentfixer.sh --repo kypost-server --no-budget
# or
AF_BUDGET=off ./agentfixer.sh --repo kypost-server
```

This makes `af_run_agent` omit `--max-budget-usd` entirely rather than
passing some large number — a large cap still aborts eventually and still
prints a dollar figure that means nothing on subscription billing. There is
no reliable way for agentfixer to detect subscription vs. API-key billing
and switch this on for you automatically (see below), so it stays opt-in:
the cost of a wrong guess in one direction is "type one extra flag"; in the
other it's an API-billed run with no spend guard at all. If you're on a
subscription and pass neither flag nor `AF_BUDGET=off`, the confirmation
screen will say so and remind you the option exists.

Override the defaults with environment variables:

| variable | default | controls |
|---|---|---|
| `AF_BUDGET_AUDIT` | 3 | each of the two parallel auditors |
| `AF_BUDGET_COMBINE` | 1 | merging the two findings lists |
| `AF_BUDGET_VERIFY` | 3 | re-verification |
| `AF_BUDGET_FIX` | 6 | applying fixes, and each re-fix round the reviewer forces |
| `AF_BUDGET_REVIEW` | 3 | each review round |
| `AF_BUDGET_CIFIX` | 3 | each CI-repair attempt |
| `AF_BUDGET=off` | unset | disables every per-step cap outright, same as `--no-budget` |
| `AF_CI_RETRIES` | 3 | max cifix attempts before giving up (exit 2) |
| `AF_REVIEW_ROUNDS` | 3 | max review rounds before giving up (exit 3); `0` disables the stage |
| `AF_MODEL_AUDIT`, `AF_MODEL_COMBINE`, `AF_MODEL_VERIFY`, `AF_MODEL_REVIEW`, `AF_MODEL_FIX`, `AF_MODEL_CIFIX` | opus/sonnet/opus/opus/opus/sonnet | model per step |
| `AF_CACHE` | `~/.cache/agentfixer` | where worktrees and run logs live |
| `AF_CI_TIMEOUT` | 1800 (seconds) | how long to wait for CI to settle |
| `AF_CHECKS_GRACE` | 100 (seconds) | how long an empty required-check set is treated as not-yet-registered before G3 concludes the repo has none |
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

The `claude` stub models the real CLI's argv parsing on the one axis
agentfixer.sh depends on (`--disallowed-tools`/`--allowed-tools`/`--add-dir`
are variadic and swallow whatever follows them), so an argument-ordering
regression fails the stubbed suite too. But it is still a model, not the
binary — nothing else here ever calls the real `claude`. Run the opt-in smoke
test to check the actual CLI accepts our argv and returns `structured_output`:

```bash
AF_SMOKE=1 bats tests/smoke.bats
```

It costs a small amount of real API spend (haiku, capped well under $1), so
it is not part of `bats tests/` and never runs in CI.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
