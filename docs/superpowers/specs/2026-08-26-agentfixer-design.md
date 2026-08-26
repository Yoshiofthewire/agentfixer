# agentfixer — design

Date: 2026-08-26
Status: approved design, pre-implementation

## 1. Purpose

Point an agent loop at a git repo and have it find real security/quality
defects, independently verify them, fix them, open a PR, drive that PR to
green CI, and merge it — repeatedly, N times, with a fresh context at every
step.

Each step is a separate `claude -p` process. Fresh context is a property of
the process boundary, not a promise made in a prompt.

## 2. Scope

In scope:

- A single self-contained `agentfixer.sh`.
- Interactive repo selection from a workspace directory, plus a headless mode.
- The eight-step pipeline in section 5, run `N` times per repo.
- Live terminal display; tmux tabs for concurrent repos.
- bats tests and a GitHub Actions workflow.

Out of scope (YAGNI — revisit only when asked):

- Non-Claude agent CLIs. Section 4's step table is per-step config; adding a
  vendor later means adding a command template, not a redesign.
- Non-GitHub forges. `gh` is assumed.
- Any web UI, daemon, or persistent scheduler. `cron` plus `--plain` covers it.
- Resuming a partially-completed run. Runs are cheap to restart; resumption
  state is the kind of thing that rots. A halted run leaves its worktree and
  PR intact for manual pickup.

## 3. Install and invocation

```
~/git/agentfixer/agentfixer.sh    source of truth (this repo)
~/git/agentfixer.sh               symlink; the thing you run
~/.cache/agentfixer/<repo>/<run>/ worktrees, logs, JSON artifacts
```

The script is one file. Prompts are embedded as quoted heredocs and JSON
schemas as heredoc constants, so the symlink cannot break by losing a sibling
`prompts/` directory.

**Workspace resolution.** `realpath "$0"` gives the real script path even
through the symlink. If that path is inside a git repo, the workspace is that
repo's parent directory (`~/git`). Otherwise the workspace is the script's own
directory. `--workspace DIR` overrides.

**Interactive mode** (no `--repo`):

1. Enumerate immediate subdirectories of the workspace containing `.git`.
   Exclude the agentfixer repo itself.
2. `fzf --multi` selection.
3. Prompt for iteration count (default 1).
4. Preflight (section 7) each selected repo; print a confirmation summary
   naming the repos, iteration count, and estimated worst-case spend from the
   per-step budget caps. Require an explicit `y`.
5. One repo selected -> run in the foreground. Two or more -> tmux (section 9).

**Headless mode:**

```
agentfixer.sh --repo NAME [--iterations N] [--plain] [--workspace DIR]
              [--base BRANCH] [--dry-run] [--yes]
```

`--plain` disables ANSI redraw and emits one timestamped line per state
change, for cron and CI. `--dry-run` runs audit, combine, and verify, then
prints what would be fixed and exits before any write, branch, or PR.

## 4. Per-step agent configuration

Every step is one `claude -p` invocation with `cwd` set to the run's worktree.

| step | model | tools | budget |
|---|---|---|---|
| `audit-sec` | opus | read-only | $3 |
| `audit-hostile` | opus | read-only | $3 |
| `combine` | sonnet | read-only | $1 |
| `verify` | opus | read-only + subagents | $3 |
| `fix` | opus | write + subagents | $6 |
| `cifix` | sonnet | write | $3 |

Common flags: `--print`, `--output-format json`, `--json-schema <schema>`,
`--model`, `--max-budget-usd`, `--no-session-persistence`.

Read-only steps add `--disallowed-tools 'Edit Write NotebookEdit WebFetch WebSearch'`.
Write steps add `--permission-mode bypassPermissions --disallowed-tools 'WebFetch WebSearch'`.
Budgets and models are shell variables in a defaults block at the top of the
script, overridable by environment variables of the same name.

`bypassPermissions` on the write steps is deliberate and is what makes
unattended operation possible. It is bounded by three things: the step runs in
a throwaway worktree under `~/.cache`, never the user's working tree; the
budget cap; and the deterministic gates in section 6.

## 5. The pipeline

One iteration:

```
  audit-sec ──┐
              ├─ parallel ──> combine ──> verify ──> fix ──> pr ──> ci ──> merge
  audit-hostile ┘                                                    ^  |
                                                                     |  v
                                                                    cifix (<=3)
```

`pr`, `ci`, and `merge` are shell, not agents. There is no reason to pay a
model to run `gh`, and it keeps merge policy in a conditional where it cannot
drift.

**1. audit** — two processes in parallel via `&` and `wait`, each invoking one
skill (`/security-audit`, `/hostile-review`) against the worktree. Each writes
`audit-sec.json` / `audit-hostile.json` conforming to `FINDINGS_SCHEMA`.
A step that exits non-zero or emits invalid JSON fails G4 and halts the run
with exit 4. Auditors assign provisional ids; `combine` reassigns canonical
`F-<iter>-<n>` ids, and every downstream step keys off those.

**2. combine** — one agent reads both files and emits `findings.json`:
deduplicated, severity-ranked, each finding assigned `id` of the form
`F-<iter>-<n>`. The two skills describe identical defects in different
vocabularies, so dedup requires semantic judgment; `sort -u` will not do it.
`source` records which auditor(s) raised each finding.

**3. verify** — one agent, one subagent per finding, each subagent given a
single claim in a fresh context. Subagents are instructed to attempt to
*refute* the finding and to default to `confirmed: false` when uncertain.
Isolation is the point: a verifier that sees all seven findings is anchored by
the six it is not judging. Emits `verified.json` conforming to `VERDICT_SCHEMA`.

**4. fix** — one agent, confirmed findings only, fanning out to subagents.
The prompt requires findings be grouped by file, with subagents run in
parallel across files and sequentially within a file; concurrent edits to one
path clobber each other. The agent edits and runs the repo's test command if
one is detectable; it does not commit. Emits `fixed.json`.

Bash then makes exactly one commit. Agents are unreliable at git hygiene, the
PR body already itemizes every finding, and a single commit keeps the
section-6 diff gates trivial to evaluate.

**5. pr** — shell. Push `agentfixer/<YYYYMMDD-HHMM>-iter<NN>`, then
`gh pr create`. Body per section 8.

**6. ci** — shell. Polls `gh pr checks --required --json bucket,name` every
`AF_POLL` seconds (default 15) until no bucket is `pending`, bounded by
`AF_CI_TIMEOUT` (default 1800s). Polling rather than `--watch` because a
blocking watch cannot be driven by a test stub, and the state machine here is
what most needs proving. `fail` or `cancel` routes to `cifix`; `skipping` does
not count as failure.

**7. cifix** — shell collects failure context with `gh run view --log-failed`,
truncated to the last 400 lines per failing job. One fresh agent per attempt,
maximum `CI_RETRIES` (default 3). Bash commits and pushes its edits, then
returns to step 6.

Exhausting the retries **halts the entire run**, not just the iteration. A PR
that cannot be made green means something systemic; further iterations would
be built on an unmerged base. The PR is left open and labelled `needs-human`.

**8. merge** — shell, gated by section 6.

The next iteration re-audits the freshly merged base branch.

## 6. Safety gates

All gates are shell conditionals evaluated on real artifacts. None is a prompt
instruction, because a prompt instruction is advisory and these are not.

**G1 — workflow tamper gate.** Before `pr`, and again immediately before
`merge`:

```
git diff --name-only "$base_sha"..HEAD | grep -qE '^\.github/' && abort_run
```

An agent that can edit workflows can turn CI green by deleting the tests. The
operator's `gh` token carries the `workflow` scope, so this is a reachable
action, not a theoretical one. Tripping G1 aborts the run and leaves
everything for inspection.

**G2 — ID completeness.** After `verify` and after `fix`, assert that the set
of finding IDs in the output equals the set in the input, exactly. A parent
agent that quietly drops one of four findings otherwise ships a PR claiming
four fixes and containing three.

**G3 — merge gate.** Merge requires all of:

- `gh pr checks --required --json bucket` returns a **non-empty** array.
- Every element has `bucket == "pass"`.
- G1 passes against the current head.
- The head SHA is unchanged since the checks were read, enforced by
  `gh pr merge --squash --delete-branch --match-head-commit "$head_sha"`.

An empty required-checks array is treated as failure, never success. Green with
nothing to be green about is not evidence. On failure the PR is left open and
the run halts.

**G4 — schema validation.** Every agent step passes `--json-schema`. Output
that fails validation fails the step; nothing downstream parses prose.

## 7. Preflight

Run once per repo before any tokens are spent. Any failure aborts that repo
with a message naming the exact remediation command.

1. `claude`, `gh`, `jq`, `git`, `fzf` on `PATH`; `tmux` only if multi-repo.
2. `gh auth status` succeeds.
3. The repo has an `origin` remote on github.com.
4. `git fetch origin` succeeds; the base branch (default: the remote HEAD)
   exists.
5. `gh api "repos/$owner/$repo/branches/$base" --jq .protected` returns `true`.

Step 5 is **advisory**. It proves branch protection exists; it does not prove
that protection requires status checks, because neither classic protection nor
rulesets expose required contexts to a non-admin token, and the two report
through different endpoints. It is a cheap early warning that prevents burning
a full audit on a repo that can never merge. The authoritative check is G3, at
merge time, which needs no admin rights.

On failure of step 5, print the branch's settings URL and exit 1.

## 8. Attribution

Every artifact is unambiguously marked as agent-authored.

**Commit** — subject `fix: <n> verified findings from agentfixer iteration <N>`,
body listing each finding as `- SEVERITY file:line — title`, and the trailer:

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

**PR labels** — `agent-authored` and `agentfixer`, created idempotently
(`gh label create ... 2>/dev/null || true`) since the target repo may not have
them.

**PR body:**

```
## agentfixer · iteration N/M

Agent-authored. Findings produced by `security-audit` and `hostile-review`,
then independently re-verified in isolated contexts before any code changed.

### Fixed
- **HIGH** `src/db/query.ts:88` — SQL injection in WHERE clause

### Rejected during verification
- `src/x.ts:12` — auditor claimed X; verifier found Y. Not changed.

### Provenance
| step | model |
|---|---|
| audit | claude-opus-5 |
| verify | claude-opus-5 |
| fix | claude-opus-5 |

Run log: `~/.cache/agentfixer/<repo>/<run>/iter-NN/`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Listing rejected findings is deliberate: it shows the reviewer what the
verifier caught, which is the evidence that the verify stage is doing work.

## 9. Display

Default mode redraws a single status block in place using `tput`. Full agent
transcripts tee to per-step log files; the wall of text lives on disk.

```
 agentfixer · Spinmatch · iteration 2/5
 ────────────────────────────────────────────────────
  ✔ audit     sec 5 · hostile 4              1m12s
  ✔ combine   9 raw → 7 unique               0m21s
  ✔ verify    4 confirmed · 3 rejected       2m03s
  ⠸ fix       4 findings · parallel subagents      1m03s
       HIGH  src/db/query.ts:88     SQL injection in WHERE
       HIGH  src/auth/session.ts:12 session token written to log
       MED   src/api/upload.ts:44   no upload size limit
       LOW   src/util/rand.ts:7     Math.random for token
  · pr   · ci   · merge
 ────────────────────────────────────────────────────
 log: ~/.cache/agentfixer/Spinmatch/20260826-1130/iter-02/fix.log
```

The blurb under the active step is the condensed list of findings in play,
rendered from `verified.json`. It is static for the duration of the step: bash
does not drive the per-finding loop, so it cannot honestly claim per-finding
progress. Each line is `severity`, `file:line`, and the finding's `blurb`
field (max 80 chars), truncated to terminal width.

Steps show a braille spinner and elapsed time while active, `✔` or `✘` when
done. `--plain` replaces all of this with timestamped lines and is selected
automatically when stdout is not a TTY.

**Tabs.** Two or more repos selected creates a tmux session named `agentfixer`
with one window per repo, named after the repo, each running
`agentfixer.sh --repo NAME --iterations N --yes`. tmux's status bar is the tab
strip. Already inside tmux -> create windows in the current session instead of
nesting. This is not a hand-rolled multiplexer, and it gives detach/reattach,
which is how an overnight run survives closing the terminal.

## 10. State and artifacts

```
~/.cache/agentfixer/<repo>/<YYYYMMDD-HHMM>/
  run.log
  worktree/                 git worktree, branch agentfixer/<run>-iter<NN>
  iter-01/
    audit-sec.json  audit-hostile.json  findings.json
    verified.json   fixed.json
    audit-sec.log   audit-hostile.log   combine.log
    verify.log      fix.log             cifix-1.log
    pr.txt          checks.json
```

Isolation uses `git worktree add` against the target repo, so the user's
working tree is never touched and a dirty target is not a blocker.

**Cleanup is conservative.** A worktree is removed only when its branch is
merged and the working tree is clean. Otherwise it is left in place and its
path printed. Deleting a worktree holding unmerged work is a data-loss bug, and
tidiness is not worth it.

**Idempotency.** Run directories are timestamped, so a second run never
collides with a first. Branch names include the run timestamp and iteration.
`gh label create` is failure-tolerant. Nothing in the tool kills processes by
pattern or sleeps to wait for state; every wait is a poll on an observable
condition (`gh pr checks --watch`, `git fetch`).

## 11. Exit codes

| code | meaning |
|---|---|
| 0 | all requested iterations completed and merged |
| 1 | usage error or preflight failure; nothing was spent |
| 2 | halted: CI retries exhausted; PR left open and labelled |
| 3 | halted: a safety gate (G1/G3) tripped |
| 4 | halted: an agent step failed schema or ID-completeness validation |

Distinct codes matter because this will be run from cron, where the only
signal is the exit status.

## 12. JSON contracts

`FINDINGS_SCHEMA` — output of each auditor and of `combine`:

```json
{"type":"object","required":["findings"],"properties":{
 "findings":{"type":"array","items":{"type":"object",
  "required":["id","severity","file","line","title","blurb","detail","evidence"],
  "properties":{
   "id":{"type":"string"},
   "severity":{"type":"string","enum":["CRITICAL","HIGH","MEDIUM","LOW"]},
   "file":{"type":"string"},
   "line":{"type":"integer"},
   "title":{"type":"string","maxLength":60},
   "blurb":{"type":"string","maxLength":80},
   "detail":{"type":"string"},
   "evidence":{"type":"string"},
   "source":{"type":"string","enum":["security-audit","hostile-review","both"]}
  }}}}}
```

`blurb` exists purely to feed section 9's display and is required so the
auditors write it rather than bash truncating `detail` into nonsense.

`VERDICT_SCHEMA` — output of `verify`:

```json
{"type":"object","required":["verdicts"],"properties":{
 "verdicts":{"type":"array","items":{"type":"object",
  "required":["id","confirmed","reason"],
  "properties":{
   "id":{"type":"string"},
   "confirmed":{"type":"boolean"},
   "reason":{"type":"string"},
   "severity_adjusted":{"type":"string","enum":["CRITICAL","HIGH","MEDIUM","LOW"]}
  }}}}}
```

`FIXED_SCHEMA` — output of `fix`:

```json
{"type":"object","required":["results"],"properties":{
 "results":{"type":"array","items":{"type":"object",
  "required":["id","status","files_changed"],
  "properties":{
   "id":{"type":"string"},
   "status":{"type":"string","enum":["fixed","skipped"]},
   "files_changed":{"type":"array","items":{"type":"string"}},
   "note":{"type":"string"}
  }}}}}
```

A `skipped` result is legal and is reported in the PR body; a *missing* result
is not, and trips G2.

`CIFIX_SCHEMA` — output of `cifix`:

```json
{"type":"object","required":["diagnosis","files_changed","confident"],
 "properties":{
  "diagnosis":{"type":"string"},
  "files_changed":{"type":"array","items":{"type":"string"}},
  "confident":{"type":"boolean"}}}
```

Nothing branches on `confident`; it is recorded so a human triaging a
`needs-human` PR can see whether the agent believed its own fix.

## 13. Testing

`bats`, with stub `claude` and `gh` executables placed ahead of the real ones
on `PATH`, driving a real temporary git repo. `git` is never stubbed — the git
behaviour is what needs proving.

Required cases:

- Verify rejecting a finding removes it from the fix input.
- Fix returning fewer IDs than it was given trips G2 and exits 4.
- A diff touching `.github/workflows/ci.yml` trips G1 and exits 3.
- An empty `--required` check array refuses to merge and exits 3.
- A non-empty array with one `fail` bucket routes to `cifix`.
- Three consecutive `cifix` failures halt the run with exit 2 and leave the PR
  open.
- A head SHA that moved between the check read and the merge causes
  `--match-head-commit` to refuse.
- Preflight on an unprotected branch exits 1 before any `claude` invocation.
- Workspace resolution yields `~/git` when invoked through the symlink.
- Cleanup leaves an unmerged worktree in place.
- `--dry-run` reaches `verify` and exits before any branch, commit, or PR.

CI runs `shellcheck` and `bats` on push and PR. agentfixer's own base branch
gets branch protection requiring both, since the tool refuses to merge into
repos that lack it.

## 14. Known risks

- **A confident-but-wrong verifier.** The verify stage reduces false positives;
  it does not eliminate them. Mitigation is the refute-by-default prompt, real
  CI, and branch protection. Residual risk is accepted: this tool opens PRs
  into protected branches, it does not push to them.
- **Auditor blind spots.** Two skills sharing a base model share blind spots.
  Running N iterations helps only where earlier fixes expose later findings.
  This is a diminishing-returns loop, not a proof of absence.
- **Cost.** Worst case per iteration is $6 audit + $1 combine + $3 verify +
  $6 fix + 3 x $3 cifix = **$25**, and the confirmation screen states the
  worst case for the whole run (iterations x $25) before it starts.
- **Repo test quality.** Green CI on a repo with thin tests is weak evidence.
  agentfixer cannot fix that and does not pretend to; G3 checks that required
  checks exist and pass, not that they are good.
