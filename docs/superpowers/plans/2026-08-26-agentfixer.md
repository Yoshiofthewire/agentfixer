# agentfixer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single bash script that repeatedly audits a git repo with Claude agents, independently verifies the findings, fixes them, opens a PR, drives it to green CI, and merges it.

**Architecture:** One self-contained `agentfixer.sh`. Every pipeline step is a separate `claude -p` process, so fresh context is enforced by the process boundary. Merge policy, retry caps, and tamper gates live in shell conditionals, never in prompts. The script ends with a main-guard so `bats` can source it and unit-test individual functions.

**Tech Stack:** bash 5, `jq`, `gh`, `git`, `fzf`, `tmux`, `claude` CLI. Tests: `bats` + `bats-support` + `bats-assert`. Lint: `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-08-26-agentfixer-design.md`

## Global Constraints

- Single file: `agentfixer.sh`. Prompts and JSON schemas are embedded heredocs. No sibling data directories — the script is run through a symlink and must not depend on its own siblings.
- Every function is prefixed `af_`. The file ends with `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then af_main "$@"; fi` so tests can source it without executing.
- `set -euo pipefail` at the top. `shellcheck` must pass at default severity with zero warnings.
- Runtime deps: `claude`, `gh`, `jq`, `git`, `fzf`. `tmux` only for multi-repo. No others may be added.
- **Agent output contract** (verified empirically 2026-08-26): `claude -p --output-format json --json-schema S` emits one JSON object. The validated payload is `.structured_output`. Success requires `.is_error == false` **and** `.subtype == "success"`. Per-call spend is `.total_cost_usd`. Denied tools appear in `.permission_denials`.
- Exit codes: `0` success, `1` usage/preflight, `2` CI retries exhausted, `3` safety gate tripped, `4` schema or ID-completeness failure.
- The script never runs `git push --force` and never writes under `.github/`.
- Commit trailer on every commit it authors: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- PR labels on every PR it opens: `agent-authored`, `agentfixer`.

## File Structure

| File | Responsibility |
|---|---|
| `agentfixer.sh` | The entire tool. Sections in order: defaults, logging, display, workspace/discovery, preflight, run/worktree lifecycle, agent wrapper, pipeline steps, gates, iteration loop, CLI parsing, `af_main`, main-guard. |
| `tests/helpers.bash` | `setup_stub_env`, `make_repo`, `stub_claude`, `stub_gh`. Every `.bats` file loads it. |
| `tests/stubs/claude` | Programmable `claude` stub, dispatches on `$AF_STEP`. |
| `tests/stubs/gh` | Programmable `gh` stub, dispatches on `$1`/`$2` with per-call sequencing. |
| `tests/*.bats` | One file per concern, named after the task that created it. |
| `.github/workflows/ci.yml` | `shellcheck` + `bats` on push and PR. |
| `README.md` | Install (symlink), usage, and the branch-protection requirement. |

`git` is never stubbed. Git behaviour is what needs proving.

---

### Task 1: Scaffold, main-guard, and the stub harness

Everything downstream depends on being able to run a test. This task delivers a script that does nothing but report its version, and the machinery to test it.

**Files:**
- Create: `agentfixer.sh`, `tests/helpers.bash`, `tests/stubs/claude`, `tests/stubs/gh`, `tests/scaffold.bats`, `.github/workflows/ci.yml`, `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `af_main "$@"` (entry point); `AF_VERSION` (string); test helpers `setup_stub_env`, `make_repo`, `stub_claude <step> <json>`, `stub_gh <key> <body>`.

- [ ] **Step 1: Install test dependencies**

This needs `sudo` — run it yourself, do not automate it.

```bash
sudo pacman -S --needed bats bats-support bats-assert shellcheck
```

Verify: `bats --version && shellcheck --version`

- [ ] **Step 2: Write the failing test**

Create `tests/scaffold.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
}

@test "reports its version" {
  run "$AF_SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == agentfixer* ]]
}

@test "unknown flag exits 1" {
  run "$AF_SCRIPT" --nope
  [ "$status" -eq 1 ]
}

@test "can be sourced without executing" {
  run bash -c "source '$AF_SCRIPT'; echo SOURCED_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == "SOURCED_OK" ]]
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bats tests/scaffold.bats`
Expected: FAIL — `tests/helpers.bash` does not exist.

- [ ] **Step 4: Write the test helpers**

Create `tests/helpers.bash`:

```bash
# shellcheck shell=bash
AF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AF_ROOT
export AF_SCRIPT="$AF_ROOT/agentfixer.sh"

setup_stub_env() {
  AF_TMP="$(mktemp -d)"
  export AF_TMP
  export AF_STUB_DIR="$AF_TMP/stub"
  mkdir -p "$AF_STUB_DIR/claude" "$AF_STUB_DIR/gh" "$AF_TMP/bin"
  cp "$AF_ROOT/tests/stubs/claude" "$AF_TMP/bin/claude"
  cp "$AF_ROOT/tests/stubs/gh" "$AF_TMP/bin/gh"
  chmod +x "$AF_TMP/bin/claude" "$AF_TMP/bin/gh"
  export PATH="$AF_TMP/bin:$PATH"
  export HOME="$AF_TMP/home"
  mkdir -p "$HOME"
}

teardown() {
  [ -n "${AF_TMP:-}" ] && rm -rf "$AF_TMP"
}

# make_repo <name> -> prints the repo path
make_repo() {
  local name="$1" dir="$AF_TMP/ws/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.test
  git -C "$dir" config user.name Test
  echo "hello" > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  git -C "$dir" remote add origin "https://github.com/test/$name.git"
  echo "$dir"
}

# stub_claude <step> <structured_output_json>
stub_claude() { printf '%s' "$2" > "$AF_STUB_DIR/claude/$1.json"; }

# stub_claude_raw <step> <full_envelope>  -- for malformed-output tests
stub_claude_raw() { printf '%s' "$2" > "$AF_STUB_DIR/claude/$1.envelope"; }

# stub_claude_side_effect <step> <bash source>  -- runs in the agent's cwd
stub_claude_side_effect() { printf '%s' "$2" > "$AF_STUB_DIR/claude/$1.sh"; }

# stub_gh <key> <body>   key is e.g. pr_checks, api_repos
stub_gh() { printf '%s' "$2" > "$AF_STUB_DIR/gh/$1"; }

# stub_gh_seq <key> <n> <body>  -- response for the Nth call
stub_gh_seq() { printf '%s' "$3" > "$AF_STUB_DIR/gh/$1.$2"; }

gh_calls() { cat "$AF_STUB_DIR/gh/calls.log" 2>/dev/null || true; }
```

- [ ] **Step 5: Write the claude stub**

Create `tests/stubs/claude`:

```bash
#!/usr/bin/env bash
# Programmable `claude` stub. Dispatches on $AF_STEP.
set -euo pipefail
step="${AF_STEP:-unknown}"
d="${AF_STUB_DIR:?AF_STUB_DIR unset}/claude"
printf '%s\n' "$*" >> "$d/$step.args"

# Optional side effect, executed in the caller's cwd (the worktree).
if [ -f "$d/$step.sh" ]; then
  bash "$d/$step.sh"
fi

rc=0
if [ -f "$d/$step.exit" ]; then rc="$(cat "$d/$step.exit")"; fi

# A raw envelope overrides everything, so tests can inject malformed output.
if [ -f "$d/$step.envelope" ]; then
  cat "$d/$step.envelope"
  exit "$rc"
fi

payload='{}'
if [ -f "$d/$step.json" ]; then payload="$(cat "$d/$step.json")"; fi
jq -n --argjson so "$payload" '{
  is_error: false, subtype: "success", api_error_status: null,
  total_cost_usd: 0.01, permission_denials: [],
  subagent_stats: {spawned: 1, completed: 1, failed: 0},
  result: ($so | tostring), structured_output: $so
}'
exit "$rc"
```

- [ ] **Step 6: Write the gh stub**

Create `tests/stubs/gh`:

```bash
#!/usr/bin/env bash
# Programmable `gh` stub. Key is the first two args, sanitized.
set -euo pipefail
d="${AF_STUB_DIR:?AF_STUB_DIR unset}/gh"
printf '%s\n' "$*" >> "$d/calls.log"

key="$(printf '%s_%s' "${1:-}" "${2:-}" | tr -c 'a-zA-Z0-9' '_')"
n_file="$d/$key.n"
n=1
if [ -f "$n_file" ]; then n=$(( $(cat "$n_file") + 1 )); fi
printf '%s' "$n" > "$n_file"

for f in "$d/$key.$n" "$d/$key"; do
  if [ -f "$f" ]; then
    cat "$f"
    if [ -f "$f.exit" ]; then exit "$(cat "$f.exit")"; fi
    exit 0
  fi
done
exit 0
```

- [ ] **Step 7: Write the minimal script**

Create `agentfixer.sh`:

```bash
#!/usr/bin/env bash
# agentfixer - repeated audit/verify/fix/PR/CI/merge loop driven by Claude agents.
set -euo pipefail

AF_VERSION="0.1.0"

# ---------------------------------------------------------------- exit codes
readonly AF_EX_USAGE=1
readonly AF_EX_CI=2
readonly AF_EX_GATE=3
readonly AF_EX_SCHEMA=4

af_die() { printf 'agentfixer: %s\n' "$1" >&2; exit "${2:-$AF_EX_USAGE}"; }

af_main() {
  case "${1:-}" in
    --version) printf 'agentfixer %s\n' "$AF_VERSION"; return 0 ;;
    -h|--help) printf 'usage: agentfixer.sh [--repo NAME] [--iterations N]\n'; return 0 ;;
    *) af_die "unknown option: ${1:-}" "$AF_EX_USAGE" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  af_main "$@"
fi
```

Then `chmod +x agentfixer.sh tests/stubs/claude tests/stubs/gh`.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bats tests/scaffold.bats`
Expected: 3 passing.

- [ ] **Step 9: Run shellcheck**

Run: `shellcheck agentfixer.sh tests/stubs/claude tests/stubs/gh`
Expected: no output, exit 0.

- [ ] **Step 10: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: shellcheck agentfixer.sh tests/stubs/claude tests/stubs/gh
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y bats jq
      - run: bats tests/
```

Create `.gitignore`:

```
*.log
```

- [ ] **Step 11: Commit**

```bash
git add agentfixer.sh tests .github .gitignore
git commit -m "feat: scaffold agentfixer with bats harness and stubs

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Workspace resolution and repo discovery

**Files:**
- Modify: `agentfixer.sh` (add after the exit-code block)
- Create: `tests/workspace.bats`

**Interfaces:**
- Consumes: `af_die`.
- Produces: `af_resolve_workspace` (prints workspace dir), `af_list_repos <workspace>` (prints one repo basename per line, sorted, excluding the agentfixer repo itself).

- [ ] **Step 1: Write the failing test**

Create `tests/workspace.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
}

@test "workspace is the parent of the script's own repo, through a symlink" {
  mkdir -p "$AF_TMP/ws/agentfixer"
  git -C "$AF_TMP/ws/agentfixer" init -q
  cp "$AF_SCRIPT" "$AF_TMP/ws/agentfixer/agentfixer.sh"
  ln -s "$AF_TMP/ws/agentfixer/agentfixer.sh" "$AF_TMP/ws/agentfixer.sh"
  run bash -c "source '$AF_TMP/ws/agentfixer.sh'; af_resolve_workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$AF_TMP/ws" ]
}

@test "lists sibling git repos and excludes non-repos" {
  make_repo alpha >/dev/null
  make_repo beta >/dev/null
  mkdir -p "$AF_TMP/ws/notarepo"
  run bash -c "source '$AF_SCRIPT'; af_list_repos '$AF_TMP/ws'"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha
beta" ]
}

@test "excludes the agentfixer repo itself" {
  make_repo alpha >/dev/null
  make_repo agentfixer >/dev/null
  run bash -c "source '$AF_SCRIPT'; af_list_repos '$AF_TMP/ws'"
  [ "$output" = "alpha" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/workspace.bats`
Expected: FAIL — `af_resolve_workspace: command not found`.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh` after the exit-code block:

```bash
# ------------------------------------------------------- workspace discovery
# The script is run through a symlink in the workspace. Resolve the real path,
# and if it lives inside a git repo, the workspace is that repo's parent.
af_resolve_workspace() {
  local real dir root
  real="$(readlink -f "${BASH_SOURCE[0]}")"
  dir="$(dirname "$real")"
  if root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"; then
    dirname "$root"
  else
    printf '%s\n' "$dir"
  fi
}

af_list_repos() {
  local ws="$1" d
  for d in "$ws"/*/; do
    [ -d "$d/.git" ] || continue
    d="$(basename "$d")"
    [ "$d" = "agentfixer" ] && continue
    printf '%s\n' "$d"
  done | sort
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/workspace.bats`
Expected: 3 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/workspace.bats
git commit -m "feat: resolve workspace through symlink and list sibling repos

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Agent invocation wrapper and gate G4

The single most-reused function. Everything after this calls it.

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/agent.bats`

**Interfaces:**
- Consumes: `af_die`, `AF_EX_SCHEMA`.
- Produces:
  - `af_run_agent <step> <model> <budget> <mode> <schema> <outfile> <logfile> <prompt>` — `mode` is `ro` or `rw`. Writes `.structured_output` to `outfile`, the raw envelope to `logfile`, adds `.total_cost_usd` to the global `AF_SPEND`. Exits `AF_EX_SCHEMA` on failure.
  - `AF_SPEND` — running float total of dollars spent.
  - `AF_SCHEMA_FINDINGS`, `AF_SCHEMA_VERDICTS`, `AF_SCHEMA_FIXED` — schema constants.

- [ ] **Step 1: Write the failing test**

Create `tests/agent.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
}

@test "extracts structured_output to the outfile" {
  stub_claude probe '{"findings":[]}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$AF_TMP/o.json")" = '{"findings":[]}' ]
}

@test "read-only mode disallows write tools" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--disallowed-tools' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- 'Edit Write' "$AF_STUB_DIR/claude/probe.args"
  ! grep -q -- 'bypassPermissions' "$AF_STUB_DIR/claude/probe.args"
}

@test "write mode uses bypassPermissions" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- 'bypassPermissions' "$AF_STUB_DIR/claude/probe.args"
}

@test "passes model and budget through" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe sonnet 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--model sonnet' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- '--max-budget-usd 3' "$AF_STUB_DIR/claude/probe.args"
}

@test "G4: is_error true exits 4" {
  stub_claude_raw probe '{"is_error":true,"subtype":"error_during_execution","structured_output":null}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "G4: non-JSON output exits 4" {
  stub_claude_raw probe 'this is not json'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "G4: missing structured_output exits 4" {
  stub_claude_raw probe '{"is_error":false,"subtype":"success","structured_output":null}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "G4: nonzero exit from claude exits 4" {
  stub_claude probe '{}'
  printf '7' > "$AF_STUB_DIR/claude/probe.exit"
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "accumulates spend" {
  stub_claude probe '{}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'; echo SPEND=\$AF_SPEND"
  [[ "$output" == *"SPEND=0.01"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/agent.bats`
Expected: 8 failures — `af_run_agent: command not found`.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
# ------------------------------------------------------------ agent wrapper
AF_SPEND="0"

# af_run_agent STEP MODEL BUDGET MODE SCHEMA OUT LOG PROMPT
# MODE is "ro" (read-only) or "rw" (write, bypassPermissions).
# Writes .structured_output to OUT, the raw envelope to LOG.
af_run_agent() {
  local step="$1" model="$2" budget="$3" mode="$4" schema="$5"
  local out="$6" log="$7" prompt="$8"
  local -a args=(
    --print --output-format json --no-session-persistence
    --model "$model" --max-budget-usd "$budget" --json-schema "$schema"
  )
  if [ "$mode" = "rw" ]; then
    args+=(--permission-mode bypassPermissions
           --disallowed-tools 'WebFetch WebSearch')
  else
    args+=(--disallowed-tools 'Edit Write NotebookEdit WebFetch WebSearch')
  fi

  local rc=0
  AF_STEP="$step" claude "${args[@]}" "$prompt" > "$log" 2>>"$log.stderr" || rc=$?
  if [ "$rc" -ne 0 ]; then
    af_die "step '$step': claude exited $rc (see $log)" "$AF_EX_SCHEMA"
  fi
  if ! jq -e '.is_error == false and .subtype == "success"' "$log" >/dev/null 2>&1; then
    af_die "step '$step': agent reported failure (see $log)" "$AF_EX_SCHEMA"
  fi
  if ! jq -e '.structured_output != null' "$log" >/dev/null 2>&1; then
    af_die "step '$step': no structured_output (see $log)" "$AF_EX_SCHEMA"
  fi
  jq '.structured_output' "$log" > "$out"

  local cost
  cost="$(jq -r '.total_cost_usd // 0' "$log")"
  AF_SPEND="$(awk -v a="$AF_SPEND" -v b="$cost" 'BEGIN{printf "%.2f", a+b}')"

  if jq -e '(.permission_denials | length) > 0' "$log" >/dev/null 2>&1; then
    af_log warn "step '$step' had tool denials; see $log"
  fi
}
```

Add a minimal `af_log` above it (the full logger arrives in Task 13):

```bash
af_log() { printf '[%s] %s\n' "$1" "$2" >&2; }
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/agent.bats`
Expected: 8 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Add the schema constants**

Add to `agentfixer.sh` below the wrapper. These are copied verbatim from spec section 12.

```bash
# ---------------------------------------------------------------- schemas
read -r -d '' AF_SCHEMA_FINDINGS <<'SCHEMA' || true
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
SCHEMA

read -r -d '' AF_SCHEMA_VERDICTS <<'SCHEMA' || true
{"type":"object","required":["verdicts"],"properties":{
 "verdicts":{"type":"array","items":{"type":"object",
  "required":["id","confirmed","reason"],
  "properties":{
   "id":{"type":"string"},
   "confirmed":{"type":"boolean"},
   "reason":{"type":"string"},
   "severity_adjusted":{"type":"string","enum":["CRITICAL","HIGH","MEDIUM","LOW"]}
  }}}}}
SCHEMA

read -r -d '' AF_SCHEMA_FIXED <<'SCHEMA' || true
{"type":"object","required":["results"],"properties":{
 "results":{"type":"array","items":{"type":"object",
  "required":["id","status","files_changed"],
  "properties":{
   "id":{"type":"string"},
   "status":{"type":"string","enum":["fixed","skipped"]},
   "files_changed":{"type":"array","items":{"type":"string"}},
   "note":{"type":"string"}
  }}}}}
SCHEMA
```

Note: `read -r -d ''` returns 1 at EOF, hence `|| true` under `set -e`.

- [ ] **Step 6: Verify schemas are valid JSON**

Run: `bash -c "source ./agentfixer.sh; for s in \"\$AF_SCHEMA_FINDINGS\" \"\$AF_SCHEMA_VERDICTS\" \"\$AF_SCHEMA_FIXED\"; do printf '%s' \"\$s\" | jq -e type >/dev/null || exit 1; done; echo OK"`
Expected: `OK`

- [ ] **Step 7: Commit**

```bash
git add agentfixer.sh tests/agent.bats
git commit -m "feat: agent invocation wrapper with G4 schema validation

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Preflight

**Files:**
- Modify: `agentfixer.sh`, `tests/helpers.bash`
- Create: `tests/preflight.bats`

**Interfaces:**
- Consumes: `af_die`, `AF_EX_USAGE`.
- Produces: `af_repo_slug <dir>` (prints `owner/repo`), `af_base_branch <dir>` (prints the remote HEAD branch name), `af_preflight <dir>` (exits `AF_EX_USAGE` on failure).
- Test helper added: `gh_key <arg1> <arg2>`.

- [ ] **Step 1: Add the `gh_key` helper**

Append to `tests/helpers.bash`:

```bash
# gh_key <arg1> <arg2> -- mirrors the sanitizing in tests/stubs/gh
gh_key() { printf '%s_%s' "${1:-}" "${2:-}" | tr -c 'a-zA-Z0-9' '_'; }
```

- [ ] **Step 2: Write the failing test**

Create `tests/preflight.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  stub_gh "$(gh_key auth status)" ""
}

@test "extracts owner/repo from an https remote" {
  run bash -c "$SRC af_repo_slug '$REPO'"
  [ "$output" = "test/alpha" ]
}

@test "extracts owner/repo from an ssh remote" {
  git -C "$REPO" remote set-url origin "git@github.com:test/alpha.git"
  run bash -c "$SRC af_repo_slug '$REPO'"
  [ "$output" = "test/alpha" ]
}

@test "passes when the base branch is protected" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 0 ]
}

@test "fails when the base branch is unprotected" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch protection"* ]]
  [[ "$output" == *"settings/branches"* ]]
}

@test "fails when there is no origin remote" {
  git -C "$REPO" remote remove origin
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin"* ]]
}

@test "fails when origin is not github" {
  git -C "$REPO" remote set-url origin "https://gitlab.com/test/alpha.git"
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
}

@test "preflight failure spends nothing" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_preflight '$REPO'"
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `bats tests/preflight.bats`
Expected: 7 failures — `af_repo_slug: command not found`.

- [ ] **Step 4: Implement**

Add to `agentfixer.sh`:

```bash
# ----------------------------------------------------------------- preflight
af_repo_slug() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    git@github.com:*) printf '%s\n' "${url#git@github.com:}" ;;
    https://github.com/*) printf '%s\n' "${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
}

af_base_branch() {
  local ref
  if ref="$(git -C "$1" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref##*/}"
    return 0
  fi
  printf 'main\n'
}

af_preflight() {
  local dir="$1" slug base protected c
  for c in claude gh jq git; do
    command -v "$c" >/dev/null || af_die "missing dependency: $c" "$AF_EX_USAGE"
  done
  gh auth status >/dev/null 2>&1 || af_die "gh is not authenticated; run: gh auth login" "$AF_EX_USAGE"

  slug="$(af_repo_slug "$dir")" \
    || af_die "$dir has no github.com origin remote" "$AF_EX_USAGE"

  git -C "$dir" fetch --quiet origin \
    || af_die "$slug: git fetch origin failed" "$AF_EX_USAGE"

  base="${AF_BASE:-$(af_base_branch "$dir")}"
  git -C "$dir" rev-parse --verify --quiet "origin/$base" >/dev/null \
    || af_die "$slug: base branch origin/$base does not exist" "$AF_EX_USAGE"

  protected="$(gh api "repos/$slug/branches/$base" --jq '.protected' 2>/dev/null || echo false)"
  if [ "$protected" != "true" ]; then
    af_die "$slug: branch protection is not enabled on '$base'.
agentfixer refuses to merge into an unprotected branch.
Enable it at: https://github.com/$slug/settings/branches" "$AF_EX_USAGE"
  fi
  printf '%s\n' "$base"
}
```

Note: `af_preflight` prints the resolved base branch on success; callers capture it.

- [ ] **Step 5: Run to verify it passes**

Run: `bats tests/preflight.bats`
Expected: 7 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 6: Commit**

```bash
git add agentfixer.sh tests/helpers.bash tests/preflight.bats
git commit -m "feat: preflight requiring a protected base branch

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Run directory and worktree lifecycle

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/worktree.bats`

**Interfaces:**
- Consumes: `af_die`.
- Produces: `af_setup_run <repo_dir> <repo_name> <base>` (sets globals `AF_RUN_DIR`, `AF_WORKTREE`, `AF_BRANCH`, `AF_BASE_SHA`), `af_iter_dir <n>` (prints and creates the iteration dir), `af_cleanup_worktree <repo_dir>`.

- [ ] **Step 1: Write the failing test**

Create `tests/worktree.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
}

@test "creates a worktree on a new branch off the base" {
  run bash -c "$SRC af_setup_run '$REPO' alpha main; echo \"\$AF_WORKTREE\"; echo \"\$AF_BRANCH\""
  [ "$status" -eq 0 ]
  wt="$(echo "$output" | sed -n 1p)"
  br="$(echo "$output" | sed -n 2p)"
  [ -f "$wt/README.md" ]
  [[ "$br" == agentfixer/* ]]
}

@test "the user's working tree is untouched" {
  echo "dirty" > "$REPO/scratch.txt"
  bash -c "$SRC af_setup_run '$REPO' alpha main"
  [ -f "$REPO/scratch.txt" ]
  run git -C "$REPO" rev-parse --abbrev-ref HEAD
  [ "$output" = "main" ]
}

@test "iteration directories are created" {
  run bash -c "$SRC af_setup_run '$REPO' alpha main >/dev/null; af_iter_dir 2"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  [[ "$output" == *"/iter-02" ]]
}

@test "cleanup removes a merged clean worktree" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main
    af_cleanup_worktree '$REPO'
    [ -d \"\$AF_WORKTREE\" ] && echo STILL_THERE || echo GONE"
  [[ "$output" == *"GONE"* ]]
}

@test "cleanup leaves an unmerged worktree in place and says where" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main
    echo change > \"\$AF_WORKTREE/new.txt\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm work
    af_cleanup_worktree '$REPO'
    [ -d \"\$AF_WORKTREE\" ] && echo STILL_THERE || echo GONE"
  [[ "$output" == *"STILL_THERE"* ]]
  [[ "$output" == *"unmerged"* ]]
}

@test "cleanup leaves a dirty worktree in place" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main
    echo dirt > \"\$AF_WORKTREE/dirty.txt\"
    af_cleanup_worktree '$REPO'
    [ -d \"\$AF_WORKTREE\" ] && echo STILL_THERE || echo GONE"
  [[ "$output" == *"STILL_THERE"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/worktree.bats`
Expected: 6 failures.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
# ------------------------------------------------------------ run lifecycle
AF_RUN_DIR=""
AF_WORKTREE=""
AF_BRANCH=""
AF_BASE_SHA=""

af_setup_run() {
  local dir="$1" name="$2" base="$3" stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  AF_RUN_DIR="${AF_CACHE:-$HOME/.cache/agentfixer}/$name/$stamp"
  AF_WORKTREE="$AF_RUN_DIR/worktree"
  AF_BRANCH="agentfixer/$stamp"
  mkdir -p "$AF_RUN_DIR"
  AF_BASE_SHA="$(git -C "$dir" rev-parse "origin/$base")"
  git -C "$dir" worktree add --quiet -b "$AF_BRANCH" "$AF_WORKTREE" "$AF_BASE_SHA" \
    || af_die "could not create worktree at $AF_WORKTREE"
}

af_iter_dir() {
  local d
  d="$(printf '%s/iter-%02d' "$AF_RUN_DIR" "$1")"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# Conservative: only remove a worktree that is clean AND fully merged.
# Deleting a worktree holding unmerged work is data loss; tidiness is not
# worth it.
af_cleanup_worktree() {
  local dir="$1"
  [ -n "$AF_WORKTREE" ] && [ -d "$AF_WORKTREE" ] || return 0
  if [ -n "$(git -C "$AF_WORKTREE" status --porcelain)" ]; then
    af_log warn "worktree is dirty, leaving it: $AF_WORKTREE"
    return 0
  fi
  if [ -n "$(git -C "$AF_WORKTREE" log --oneline "$AF_BASE_SHA..HEAD")" ]; then
    af_log warn "worktree has unmerged commits, leaving it: $AF_WORKTREE"
    return 0
  fi
  git -C "$dir" worktree remove --force "$AF_WORKTREE"
  git -C "$dir" branch -D "$AF_BRANCH" >/dev/null 2>&1 || true
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/worktree.bats`
Expected: 6 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/worktree.bats
git commit -m "feat: isolated worktree lifecycle with conservative cleanup

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Audit (parallel) and combine

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/audit.bats`

**Interfaces:**
- Consumes: `af_run_agent`, `AF_SCHEMA_FINDINGS`, `af_iter_dir`, `AF_WORKTREE`.
- Produces: `af_step_audit <iterdir>` (writes `audit-sec.json`, `audit-hostile.json`), `af_step_combine <iterdir> <iter_n>` (writes `findings.json`).

- [ ] **Step 1: Write the failing test**

Create `tests/audit.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  export AF_WORKTREE="$AF_TMP/wt"
  mkdir -p "$AF_WORKTREE"
}

FIND='{"findings":[{"id":"a1","severity":"HIGH","file":"x.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'

@test "runs both auditors and writes both files" {
  stub_claude audit-sec "$FIND"
  stub_claude audit-hostile "$FIND"
  run bash -c "$SRC af_step_audit '$ITER'"
  [ "$status" -eq 0 ]
  [ -f "$ITER/audit-sec.json" ]
  [ -f "$ITER/audit-hostile.json" ]
}

@test "auditors are read-only" {
  stub_claude audit-sec "$FIND"
  stub_claude audit-hostile "$FIND"
  bash -c "$SRC af_step_audit '$ITER'"
  grep -q 'Edit Write' "$AF_STUB_DIR/claude/audit-sec.args"
  ! grep -q 'bypassPermissions' "$AF_STUB_DIR/claude/audit-sec.args"
}

@test "auditors invoke their skills" {
  stub_claude audit-sec "$FIND"
  stub_claude audit-hostile "$FIND"
  bash -c "$SRC af_step_audit '$ITER'"
  grep -q 'security-audit' "$AF_STUB_DIR/claude/audit-sec.args"
  grep -q 'hostile-review' "$AF_STUB_DIR/claude/audit-hostile.args"
}

@test "a failing auditor propagates exit 4" {
  stub_claude audit-sec "$FIND"
  stub_claude_raw audit-hostile 'not json'
  run bash -c "$SRC af_step_audit '$ITER'"
  [ "$status" -eq 4 ]
}

@test "combine assigns canonical F-<iter>-<n> ids" {
  printf '%s' "$FIND" > "$ITER/audit-sec.json"
  printf '%s' "$FIND" > "$ITER/audit-hostile.json"
  stub_claude combine '{"findings":[{"id":"F-01-1","severity":"HIGH","file":"x.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e","source":"both"}]}'
  run bash -c "$SRC af_step_combine '$ITER' 1"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].id' "$ITER/findings.json")" = "F-01-1" ]
}

@test "combine rejects ids that do not match the canonical form" {
  printf '%s' "$FIND" > "$ITER/audit-sec.json"
  printf '%s' "$FIND" > "$ITER/audit-hostile.json"
  stub_claude combine '{"findings":[{"id":"whatever","severity":"HIGH","file":"x.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'
  run bash -c "$SRC af_step_combine '$ITER' 1"
  [ "$status" -eq 4 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/audit.bats`
Expected: 6 failures.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
# --------------------------------------------------------------- pipeline
AF_MODEL_AUDIT="${AF_MODEL_AUDIT:-opus}"
AF_MODEL_COMBINE="${AF_MODEL_COMBINE:-sonnet}"
AF_BUDGET_AUDIT="${AF_BUDGET_AUDIT:-3}"
AF_BUDGET_COMBINE="${AF_BUDGET_COMBINE:-1}"

af_prompt_audit() {
  cat <<PROMPT
Run the /$1 skill against this repository.

Report every finding as a structured record. Rules:
- Only report defects you can point at in the code. No speculation.
- 'evidence' must quote the actual offending code or command output.
- 'blurb' is a single line under 80 characters for a terminal display.
- 'id' may be any unique string; it will be reassigned downstream.
- If you find nothing, return an empty findings array. That is a valid answer.
PROMPT
}

af_step_audit() {
  local iter="$1" pid_s pid_h
  ( cd "$AF_WORKTREE" && af_run_agent audit-sec "$AF_MODEL_AUDIT" \
      "$AF_BUDGET_AUDIT" ro "$AF_SCHEMA_FINDINGS" \
      "$iter/audit-sec.json" "$iter/audit-sec.log" \
      "$(af_prompt_audit security-audit)" ) & pid_s=$!
  ( cd "$AF_WORKTREE" && af_run_agent audit-hostile "$AF_MODEL_AUDIT" \
      "$AF_BUDGET_AUDIT" ro "$AF_SCHEMA_FINDINGS" \
      "$iter/audit-hostile.json" "$iter/audit-hostile.log" \
      "$(af_prompt_audit hostile-review)" ) & pid_h=$!
  wait "$pid_s" || af_die "audit-sec failed" "$?"
  wait "$pid_h" || af_die "audit-hostile failed" "$?"
}

af_step_combine() {
  local iter="$1" n="$2" prompt bad
  prompt="$(cat <<PROMPT
Two independent auditors reviewed this repository. Their findings are below.

security-audit:
$(cat "$iter/audit-sec.json")

hostile-review:
$(cat "$iter/audit-hostile.json")

Merge them into one list:
- Collapse findings that describe the same defect, even when worded very
  differently. Set 'source' to "both" when they do.
- Sort by severity: CRITICAL, HIGH, MEDIUM, LOW.
- Assign each finding an id of exactly the form F-$(printf '%02d' "$n")-N,
  where N counts up from 1 in the sorted order.
- Preserve the strongest evidence from either auditor.
PROMPT
)"
  ( cd "$AF_WORKTREE" && af_run_agent combine "$AF_MODEL_COMBINE" \
      "$AF_BUDGET_COMBINE" ro "$AF_SCHEMA_FINDINGS" \
      "$iter/findings.json" "$iter/combine.log" "$prompt" ) \
    || af_die "combine failed" "$?"

  bad="$(jq -r --arg p "F-$(printf '%02d' "$n")-" \
    '[.findings[].id | select(startswith($p) | not)] | join(", ")' \
    "$iter/findings.json")"
  [ -z "$bad" ] || af_die "combine produced non-canonical ids: $bad" "$AF_EX_SCHEMA"
}
```

Note on the subshells: `af_run_agent` calls `af_die`, which exits. Wrapping each
call in `( ... )` means that exit terminates the subshell, and `wait`/`||`
propagates the code to the parent. Do not "simplify" these into a pipeline —
`af_die` inside a pipeline exits a subshell the parent never sees.

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/audit.bats`
Expected: 6 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/audit.bats
git commit -m "feat: parallel audit and semantic combine step

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Verify and gate G2

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/verify.bats`

**Interfaces:**
- Consumes: `af_run_agent`, `AF_SCHEMA_VERDICTS`.
- Produces: `af_assert_id_sets <fileA> <jqA> <fileB> <jqB> <label>` (G2), `af_step_verify <iterdir>` (writes `verified.json`), `af_confirmed <iterdir>` (prints the confirmed findings as a JSON array).

- [ ] **Step 1: Write the failing test**

Create `tests/verify.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  export AF_WORKTREE="$AF_TMP/wt"
  mkdir -p "$AF_WORKTREE"
  cat > "$ITER/findings.json" <<'J'
{"findings":[
 {"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"b1","detail":"d","evidence":"e"},
 {"id":"F-01-2","severity":"LOW","file":"b.ts","line":2,"title":"t2","blurb":"b2","detail":"d","evidence":"e"}]}
J
}

@test "writes verified.json when every id is accounted for" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"},{"id":"F-01-2","confirmed":false,"reason":"false positive"}]}'
  run bash -c "$SRC af_step_verify '$ITER'"
  [ "$status" -eq 0 ]
  [ -f "$ITER/verified.json" ]
}

@test "G2: a dropped finding exits 4" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"}]}'
  run bash -c "$SRC af_step_verify '$ITER'"
  [ "$status" -eq 4 ]
  [[ "$output" == *"G2"* ]]
}

@test "G2: an invented finding id exits 4" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"r"},{"id":"F-01-2","confirmed":true,"reason":"r"},{"id":"F-01-9","confirmed":true,"reason":"r"}]}'
  run bash -c "$SRC af_step_verify '$ITER'"
  [ "$status" -eq 4 ]
}

@test "rejected findings are excluded from the confirmed set" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"},{"id":"F-01-2","confirmed":false,"reason":"nope"}]}'
  bash -c "$SRC af_step_verify '$ITER'"
  run bash -c "$SRC af_confirmed '$ITER'"
  [ "$(echo "$output" | jq -r 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "F-01-1" ]
}

@test "verify is read-only" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"r"},{"id":"F-01-2","confirmed":true,"reason":"r"}]}'
  bash -c "$SRC af_step_verify '$ITER'"
  ! grep -q 'bypassPermissions' "$AF_STUB_DIR/claude/verify.args"
}

@test "verify prompt instructs refute-by-default" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"r"},{"id":"F-01-2","confirmed":true,"reason":"r"}]}'
  bash -c "$SRC af_step_verify '$ITER'"
  grep -qi 'refute' "$AF_STUB_DIR/claude/verify.args"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/verify.bats`
Expected: 6 failures.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
AF_MODEL_VERIFY="${AF_MODEL_VERIFY:-opus}"
AF_BUDGET_VERIFY="${AF_BUDGET_VERIFY:-3}"

# G2 - the id set going in must equal the id set coming out, exactly.
af_assert_id_sets() {
  local fa="$1" ja="$2" fb="$3" jb="$4" label="$5" a b
  a="$(jq -c "[$ja] | sort" "$fa")"
  b="$(jq -c "[$jb] | sort" "$fb")"
  if [ "$a" != "$b" ]; then
    af_die "G2 ($label): id set mismatch
  expected: $a
  received: $b" "$AF_EX_SCHEMA"
  fi
}

af_step_verify() {
  local iter="$1" prompt
  prompt="$(cat <<PROMPT
An unidentified tool produced the claims below about this repository. You do
not know how it reached them and must not assume competence.

$(cat "$iter/findings.json")

Spawn one subagent per finding. Give each subagent exactly one finding and no
others - a verifier that has seen the whole list is anchored by the findings it
is not judging.

Instruct every subagent to attempt to REFUTE its finding by reading the actual
code, and to return confirmed=false whenever it is uncertain. A false positive
that reaches the fix stage costs more than a missed finding, which the next
iteration can catch anyway.

Return exactly one verdict per finding id, no more and no fewer.
PROMPT
)"
  ( cd "$AF_WORKTREE" && af_run_agent verify "$AF_MODEL_VERIFY" \
      "$AF_BUDGET_VERIFY" ro "$AF_SCHEMA_VERDICTS" \
      "$iter/verified.json" "$iter/verify.log" "$prompt" ) \
    || af_die "verify failed" "$?"

  af_assert_id_sets "$iter/findings.json" '.findings[].id' \
                    "$iter/verified.json" '.verdicts[].id' verify
}

# Prints the confirmed findings, severity carried over from any adjustment.
af_confirmed() {
  local iter="$1"
  jq -c -s '
    .[0].findings as $f | .[1].verdicts as $v
    | [ $v[] | select(.confirmed)
        | . as $vd
        | ($f[] | select(.id == $vd.id))
        | .severity = ($vd.severity_adjusted // .severity) ]
  ' "$iter/findings.json" "$iter/verified.json"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/verify.bats`
Expected: 6 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/verify.bats
git commit -m "feat: isolated per-finding verification with G2 id completeness

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Fix, gate G1, and commit

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/fix.bats`

**Interfaces:**
- Consumes: `af_run_agent`, `AF_SCHEMA_FIXED`, `af_confirmed`, `af_assert_id_sets`, `AF_WORKTREE`, `AF_BASE_SHA`.
- Produces: `af_gate_workflows <newline-separated paths>` (G1), `af_changed_paths` (prints working-tree paths), `af_step_fix <iterdir>` (writes `fixed.json`), `af_commit_fixes <iterdir> <iter_n>`.

- [ ] **Step 1: Write the failing test**

Create `tests/fix.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  cat > "$ITER/findings.json" <<'J'
{"findings":[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"sqli in where clause","detail":"d","evidence":"e"}]}
J
  cat > "$ITER/verified.json" <<'J'
{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"}]}
J
}

@test "G1 rejects a .github path" {
  run bash -c "$SRC af_gate_workflows '.github/workflows/ci.yml
src/a.ts'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 accepts ordinary paths" {
  run bash -c "$SRC af_gate_workflows 'src/a.ts
README.md'"
  [ "$status" -eq 0 ]
}

@test "G1 accepts an empty path list" {
  run bash -c "$SRC af_gate_workflows ''"
  [ "$status" -eq 0 ]
}

@test "fix runs with write access and produces fixed.json" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 0 ]
  grep -q 'bypassPermissions' "$AF_STUB_DIR/claude/fix.args"
}

@test "G2: fix dropping a finding exits 4" {
  stub_claude fix '{"results":[]}'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 4 ]
}

@test "G1 trips when the fix agent edits a workflow" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":[".github/workflows/ci.yml"]}]}'
  stub_claude_side_effect fix 'mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "makes exactly one commit with the trailer" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'
    af_commit_fixes '$ITER' 1
    git -C \"\$AF_WORKTREE\" log --format=%s%n%b \"\$AF_BASE_SHA\"..HEAD
    echo COUNT=\$(git -C \"\$AF_WORKTREE\" rev-list --count \"\$AF_BASE_SHA\"..HEAD)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=1"* ]]
  [[ "$output" == *"Co-Authored-By: Claude Opus 5 (1M context)"* ]]
  [[ "$output" == *"HIGH a.ts:1"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/fix.bats`
Expected: 7 failures.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
AF_MODEL_FIX="${AF_MODEL_FIX:-opus}"
AF_BUDGET_FIX="${AF_BUDGET_FIX:-6}"
AF_TRAILER="Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"

# G1 - an agent that can edit workflows can make CI green by deleting the
# tests. Takes paths as one argument, newline separated. Not a pipeline:
# af_die inside a pipeline exits a subshell the caller never sees.
af_gate_workflows() {
  local bad
  bad="$(printf '%s\n' "$1" | grep -E '^\.github/' || true)"
  if [ -n "$bad" ]; then
    af_die "G1: agent modified workflow or CI configuration:
$bad" "$AF_EX_GATE"
  fi
}

af_changed_paths() {
  git -C "$AF_WORKTREE" status --porcelain | awk '{print $NF}'
}

af_step_fix() {
  local iter="$1" prompt confirmed
  confirmed="$(af_confirmed "$iter")"
  prompt="$(cat <<PROMPT
These findings were independently verified as real. Fix all of them.

$confirmed

Rules:
- Spawn subagents to work in parallel, but group the findings by file first.
  Run subagents in parallel ACROSS files and sequentially WITHIN a file.
  Two subagents editing one path concurrently will clobber each other.
- Fix the defect, not the symptom. Do not suppress, silence, or delete a test.
- Never create or modify anything under .github/. The run aborts if you do.
- If the repository has a test command, run it and make it pass.
- Do not commit. The caller commits.
- Return one result per finding id. If you cannot fix one, return status
  "skipped" with a note explaining why. Do not omit it.
PROMPT
)"
  ( cd "$AF_WORKTREE" && af_run_agent fix "$AF_MODEL_FIX" \
      "$AF_BUDGET_FIX" rw "$AF_SCHEMA_FIXED" \
      "$iter/fixed.json" "$iter/fix.log" "$prompt" ) \
    || af_die "fix failed" "$?"

  printf '%s' "$confirmed" > "$iter/confirmed.json"
  af_assert_id_sets "$iter/confirmed.json" '.[].id' \
                    "$iter/fixed.json" '.results[].id' fix
  af_gate_workflows "$(af_changed_paths)"
}

af_commit_fixes() {
  local iter="$1" n="$2" body count msg
  count="$(jq -r '[.results[] | select(.status == "fixed")] | length' "$iter/fixed.json")"
  body="$(jq -r -s '
    .[0] as $c | .[1].results as $r
    | [ $r[] | select(.status == "fixed") | .id as $id
        | ($c[] | select(.id == $id))
        | "- \(.severity) \(.file):\(.line) — \(.title)" ] | join("\n")
  ' "$iter/confirmed.json" "$iter/fixed.json")"

  msg="$(printf 'fix: %s verified findings from agentfixer iteration %d\n\n%s\n\n%s' \
    "$count" "$n" "$body" "$AF_TRAILER")"

  git -C "$AF_WORKTREE" add -A
  git -C "$AF_WORKTREE" \
    -c user.name="agentfixer" -c user.email="noreply@anthropic.com" \
    commit -q -m "$msg"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/fix.bats`
Expected: 7 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/fix.bats
git commit -m "feat: fix step with G1 workflow tamper gate and single commit

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: PR creation and agent attribution

**Files:**
- Modify: `agentfixer.sh`, `tests/helpers.bash`
- Create: `tests/pr.bats`

**Interfaces:**
- Consumes: `AF_WORKTREE`, `AF_BRANCH`, `AF_RUN_DIR`, `AF_TRAILER`.
- Produces: `af_ensure_labels`, `af_pr_body <iterdir> <n> <total>` (prints markdown), `af_step_pr <iterdir> <n> <total> <base>` (sets `AF_PR_NUM`, `AF_PR_URL`).
- Test helper added: `add_bare_remote <name> <repo_dir>`.

- [ ] **Step 1: Add the bare-remote helper**

Append to `tests/helpers.bash`. This keeps the origin URL looking like GitHub — so `af_repo_slug` still parses it — while `insteadOf` transparently redirects fetch and push to a local bare repo. No test-only backdoor in the production code.

```bash
# add_bare_remote <name> <repo_dir>
add_bare_remote() {
  local name="$1" repo="$2"
  mkdir -p "$AF_TMP/remotes"
  git init -q --bare "$AF_TMP/remotes/$name.git"
  git -C "$repo" config "url.$AF_TMP/remotes/.insteadOf" "https://github.com/test/"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  git -C "$repo" remote set-head origin main
}
```

- [ ] **Step 2: Write the failing test**

Create `tests/pr.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  cat > "$ITER/confirmed.json" <<'J'
[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"sqli","blurb":"b","detail":"d","evidence":"e"}]
J
  cat > "$ITER/findings.json" <<'J'
{"findings":[
 {"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"sqli","blurb":"b","detail":"d","evidence":"e"},
 {"id":"F-01-2","severity":"LOW","file":"b.ts","line":2,"title":"nit","blurb":"b","detail":"d","evidence":"e"}]}
J
  cat > "$ITER/verified.json" <<'J'
{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"},{"id":"F-01-2","confirmed":false,"reason":"not exploitable"}]}
J
  cat > "$ITER/fixed.json" <<'J'
{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}
J
}

@test "body marks the PR as agent authored" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"Agent-authored"* ]]
  [[ "$output" == *"iteration 1/3"* ]]
}

@test "body lists fixed findings" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"**HIGH** \`a.ts:1\` — sqli"* ]]
}

@test "body lists findings rejected by verification" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"Rejected during verification"* ]]
  [[ "$output" == *"not exploitable"* ]]
}

@test "body includes a provenance table and the run log path" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"| step | model |"* ]]
  [[ "$output" == *"$AF_TMP/run"* ]]
  [[ "$output" == *"Generated with"* ]]
}

@test "labels are created idempotently and applied" {
  bash -c "$SRC af_ensure_labels"
  grep -q 'label create agent-authored' "$AF_STUB_DIR/gh/calls.log"
  grep -q 'label create agentfixer' "$AF_STUB_DIR/gh/calls.log"
}

@test "label creation tolerates a label that already exists" {
  printf '1' > "$AF_STUB_DIR/gh/$(gh_key label create).exit"
  run bash -c "$SRC af_ensure_labels"
  [ "$status" -eq 0 ]
}

@test "pushes the branch and opens a labelled PR" {
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix
    af_step_pr '$ITER' 1 3 main
    echo NUM=\$AF_PR_NUM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NUM=7"* ]]
  grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--label agent-authored' "$AF_STUB_DIR/gh/calls.log"
  git -C "$AF_TMP/remotes/alpha.git" rev-parse --verify "refs/heads/$(cd "$AF_TMP" && true; echo)" >/dev/null 2>&1 || true
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref --format='%(refname)' refs/heads/"
  [[ "$output" == *"agentfixer/"* ]]
}

@test "never force pushes" {
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix
    af_step_pr '$ITER' 1 3 main"
  ! grep -rq 'force' "$AF_STUB_DIR/gh/calls.log"
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `bats tests/pr.bats`
Expected: 8 failures.

- [ ] **Step 4: Implement**

Add to `agentfixer.sh`:

```bash
# ---------------------------------------------------------------- pull request
AF_PR_NUM=""
AF_PR_URL=""

af_ensure_labels() {
  gh label create agent-authored --color B60205 \
    --description "Authored by an automated agent" >/dev/null 2>&1 || true
  gh label create agentfixer --color 0E8A16 \
    --description "Opened by agentfixer" >/dev/null 2>&1 || true
}

af_pr_body() {
  local iter="$1" n="$2" total="$3" fixed rejected
  fixed="$(jq -r -s '
    .[0] as $c | .[1].results as $r
    | [ $r[] | select(.status == "fixed") | .id as $id
        | ($c[] | select(.id == $id))
        | "- **\(.severity)** `\(.file):\(.line)` — \(.title)" ] | join("\n")
  ' "$iter/confirmed.json" "$iter/fixed.json")"
  rejected="$(jq -r -s '
    .[0].findings as $f | .[1].verdicts as $v
    | [ $v[] | select(.confirmed | not) | . as $vd
        | ($f[] | select(.id == $vd.id))
        | "- `\(.file):\(.line)` — \(.title). \($vd.reason) Not changed." ]
    | if length == 0 then "_None. Every finding was confirmed._" else join("\n") end
  ' "$iter/findings.json" "$iter/verified.json")"

  cat <<BODY
## agentfixer · iteration $n/$total

Agent-authored. Findings produced by \`security-audit\` and \`hostile-review\`,
then independently re-verified in isolated contexts before any code changed.

### Fixed
$fixed

### Rejected during verification
$rejected

### Provenance
| step | model |
|---|---|
| audit | $AF_MODEL_AUDIT |
| combine | $AF_MODEL_COMBINE |
| verify | $AF_MODEL_VERIFY |
| fix | $AF_MODEL_FIX |

Run log: \`$AF_RUN_DIR\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
}

af_step_pr() {
  local iter="$1" n="$2" total="$3" base="$4" title bodyfile
  bodyfile="$iter/pr-body.md"
  af_pr_body "$iter" "$n" "$total" > "$bodyfile"
  title="fix: $(jq -r '[.results[] | select(.status == "fixed")] | length' \
    "$iter/fixed.json") verified findings (agentfixer $n/$total)"

  git -C "$AF_WORKTREE" push --quiet --set-upstream origin "$AF_BRANCH"
  af_ensure_labels

  AF_PR_URL="$(cd "$AF_WORKTREE" && gh pr create \
    --base "$base" --head "$AF_BRANCH" \
    --title "$title" --body-file "$bodyfile" \
    --label agent-authored --label agentfixer)"
  AF_PR_NUM="${AF_PR_URL##*/}"
  printf '%s\n' "$AF_PR_URL" > "$iter/pr.txt"
  [ -n "$AF_PR_NUM" ] || af_die "could not determine PR number from: $AF_PR_URL"
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bats tests/pr.bats`
Expected: 8 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 6: Commit**

```bash
git add agentfixer.sh tests/helpers.bash tests/pr.bats
git commit -m "feat: PR creation with agent-authored attribution and labels

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: CI wait, cifix retries, and halt

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/ci.bats`

**Interfaces:**
- Consumes: `af_run_agent`, `af_gate_workflows`, `AF_WORKTREE`, `AF_PR_NUM`, `AF_EX_CI`.
- Produces: `AF_SCHEMA_CIFIX`, `af_check_state <pr>` (prints `none`|`pass`|`fail`|`pending`), `af_wait_ci <pr>` (prints `none`|`pass`|`fail`|`timeout`), `af_step_cifix <iterdir> <attempt> <pr>`, `af_ci_loop <iterdir> <pr>`.

- [ ] **Step 1: Write the failing test**

Create `tests/ci.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_POLL=0; AF_CI_RETRIES=3;"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
}

@test "an empty required-check array reads as none" {
  stub_gh "$(gh_key pr checks)" '[]'
  run bash -c "$SRC af_check_state 7"
  [ "$output" = "none" ]
}

@test "all pass reads as pass" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"test"}]'
  run bash -c "$SRC af_check_state 7"
  [ "$output" = "pass" ]
}

@test "any fail reads as fail" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"lint"},{"bucket":"fail","name":"test"}]'
  run bash -c "$SRC af_check_state 7"
  [ "$output" = "fail" ]
}

@test "pending reads as pending" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pending","name":"test"}]'
  run bash -c "$SRC af_check_state 7"
  [ "$output" = "pending" ]
}

@test "skipped checks do not count as failures" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"a"},{"bucket":"skipping","name":"b"}]'
  run bash -c "$SRC af_check_state 7"
  [ "$output" = "pass" ]
}

@test "wait polls through pending to pass" {
  stub_gh_seq "$(gh_key pr checks)" 1 '[{"bucket":"pending","name":"t"}]'
  stub_gh_seq "$(gh_key pr checks)" 2 '[{"bucket":"pending","name":"t"}]'
  stub_gh_seq "$(gh_key pr checks)" 3 '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC af_wait_ci 7"
  [ "$output" = "pass" ]
}

@test "wait times out" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pending","name":"t"}]'
  run bash -c "$SRC AF_CI_TIMEOUT=1; af_wait_ci 7"
  [ "$output" = "timeout" ]
}

@test "ci loop returns immediately when checks already pass" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/cifix.args" ]
}

@test "one failure then pass runs cifix once" {
  stub_gh_seq "$(gh_key pr checks)" 1 '[{"bucket":"fail","name":"t"}]'
  stub_gh_seq "$(gh_key pr checks)" 2 '[{"bucket":"pass","name":"t"}]'
  stub_gh "$(gh_key run view)" 'FAIL: expected 1 got 2'
  stub_claude cifix '{"diagnosis":"off by one","files_changed":["a.ts"],"confident":true}'
  stub_claude_side_effect cifix 'echo fixed > a.ts'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    git -C \"\$AF_WORKTREE\" push -q --set-upstream origin \"\$AF_BRANCH\"
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AF_STUB_DIR/claude/cifix.args")" -eq 1 ]
}

@test "three failures halt the whole run with exit 2 and label the PR" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run view)" 'FAIL'
  stub_claude cifix '{"diagnosis":"d","files_changed":["a.ts"],"confident":false}'
  stub_claude_side_effect cifix 'echo again > a.ts'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    git -C \"\$AF_WORKTREE\" push -q --set-upstream origin \"\$AF_BRANCH\"
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 2 ]
  [ "$(wc -l < "$AF_STUB_DIR/claude/cifix.args")" -eq 3 ]
  grep -q 'needs-human' "$AF_STUB_DIR/gh/calls.log"
}

@test "no required checks halts with exit 3" {
  stub_gh "$(gh_key pr checks)" '[]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no required checks"* ]]
}

@test "G1 trips if cifix edits a workflow" {
  stub_gh_seq "$(gh_key pr checks)" 1 '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run view)" 'FAIL'
  stub_claude cifix '{"diagnosis":"d","files_changed":[".github/workflows/ci.yml"],"confident":true}'
  stub_claude_side_effect cifix 'mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    git -C \"\$AF_WORKTREE\" push -q --set-upstream origin \"\$AF_BRANCH\"
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 3 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/ci.bats`
Expected: 12 failures.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
# ----------------------------------------------------------------------- ci
AF_MODEL_CIFIX="${AF_MODEL_CIFIX:-sonnet}"
AF_BUDGET_CIFIX="${AF_BUDGET_CIFIX:-3}"
AF_CI_RETRIES="${AF_CI_RETRIES:-3}"
AF_CI_TIMEOUT="${AF_CI_TIMEOUT:-1800}"
AF_POLL="${AF_POLL:-15}"

read -r -d '' AF_SCHEMA_CIFIX <<'SCHEMA' || true
{"type":"object","required":["diagnosis","files_changed","confident"],
 "properties":{
  "diagnosis":{"type":"string"},
  "files_changed":{"type":"array","items":{"type":"string"}},
  "confident":{"type":"boolean"}}}
SCHEMA

# An empty required-check set is "none", never "pass". Green with nothing to
# be green about is not evidence.
af_check_state() {
  local json
  json="$(gh pr checks "$1" --required --json bucket,name 2>/dev/null || echo '[]')"
  printf '%s' "$json" | jq -r '
    if length == 0 then "none"
    elif any(.[]; .bucket == "fail" or .bucket == "cancel") then "fail"
    elif any(.[]; .bucket == "pending") then "pending"
    else "pass" end'
}

af_wait_ci() {
  local pr="$1" waited=0 state
  while :; do
    state="$(af_check_state "$pr")"
    [ "$state" = "pending" ] || { printf '%s\n' "$state"; return 0; }
    if [ "$waited" -ge "$AF_CI_TIMEOUT" ]; then printf 'timeout\n'; return 0; fi
    if [ "$AF_POLL" -gt 0 ]; then
      sleep "$AF_POLL"
      waited=$(( waited + AF_POLL ))
    else
      waited=$(( waited + 1 ))   # tests set AF_POLL=0; still advance the clock
    fi
  done
}

af_step_cifix() {
  local iter="$1" attempt="$2" pr="$3" logs prompt
  logs="$(gh run view --log-failed 2>/dev/null | tail -n 400 || true)"
  prompt="$(cat <<PROMPT
CI is failing on this branch. The tail of the failing jobs' logs:

$logs

Diagnose and fix the underlying cause in the source.

Rules:
- Never create or modify anything under .github/. The run aborts if you do.
- Do not delete, skip, or weaken a test to make it pass. Fix the code.
- Do not commit or push. The caller does that.
PROMPT
)"
  ( cd "$AF_WORKTREE" && af_run_agent cifix "$AF_MODEL_CIFIX" \
      "$AF_BUDGET_CIFIX" rw "$AF_SCHEMA_CIFIX" \
      "$iter/cifix-$attempt.json" "$iter/cifix-$attempt.log" "$prompt" ) \
    || af_die "cifix attempt $attempt failed" "$?"

  af_gate_workflows "$(af_changed_paths)"
  git -C "$AF_WORKTREE" add -A
  git -C "$AF_WORKTREE" \
    -c user.name="agentfixer" -c user.email="noreply@anthropic.com" \
    commit -q -m "$(printf 'fix: address CI failure (attempt %s)\n\n%s' \
      "$attempt" "$AF_TRAILER")"
  git -C "$AF_WORKTREE" push --quiet origin "$AF_BRANCH"
}

af_ci_loop() {
  local iter="$1" pr="$2" attempt=0 state
  while :; do
    state="$(af_wait_ci "$pr")"
    case "$state" in
      pass) return 0 ;;
      none)
        gh pr edit "$pr" --add-label needs-human >/dev/null 2>&1 || true
        af_die "G3: PR #$pr has no required checks. Enable required status
checks in branch protection. PR left open." "$AF_EX_GATE" ;;
      timeout)
        gh pr edit "$pr" --add-label needs-human >/dev/null 2>&1 || true
        af_die "CI did not settle within ${AF_CI_TIMEOUT}s. PR #$pr left open." \
          "$AF_EX_CI" ;;
    esac
    attempt=$(( attempt + 1 ))
    if [ "$attempt" -gt "$AF_CI_RETRIES" ]; then
      gh pr edit "$pr" --add-label needs-human >/dev/null 2>&1 || true
      af_die "CI still failing after $AF_CI_RETRIES attempts. PR #$pr left open.
Halting the run: a PR that cannot be made green means something systemic." \
        "$AF_EX_CI"
    fi
    af_log info "CI failed, cifix attempt $attempt/$AF_CI_RETRIES"
    af_step_cifix "$iter" "$attempt" "$pr"
  done
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/ci.bats`
Expected: 12 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/ci.bats
git commit -m "feat: CI polling, bounded cifix retries, halt on exhaustion

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Merge gate G3

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/merge.bats`

**Interfaces:**
- Consumes: `af_check_state`, `af_gate_workflows`, `AF_WORKTREE`, `AF_BASE_SHA`, `AF_EX_GATE`.
- Produces: `af_step_merge <pr>`.

- [ ] **Step 1: Write the failing test**

Create `tests/merge.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_POLL=0;"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  PREP="af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix"
}

@test "merges when required checks exist and pass" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--squash' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--match-head-commit' "$AF_STUB_DIR/gh/calls.log"
}

@test "G3: refuses to merge when there are no required checks" {
  stub_gh "$(gh_key pr checks)" '[]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
  ! grep -q 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "G3: refuses to merge on a failing check" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
  ! grep -q 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "G1 re-runs against the commit range before merging" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    mkdir -p \"\$AF_WORKTREE/.github/workflows\"
    echo evil > \"\$AF_WORKTREE/.github/workflows/ci.yml\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  ! grep -q 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "passes the current head sha to --match-head-commit" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP
    sha=\$(git -C \"\$AF_WORKTREE\" rev-parse HEAD)
    af_step_merge 7
    echo SHA=\$sha"
  sha="$(echo "$output" | sed -n 's/^SHA=//p')"
  grep -q -- "--match-head-commit $sha" "$AF_STUB_DIR/gh/calls.log"
}

@test "a refused merge exits 3" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  printf '1' > "$AF_STUB_DIR/gh/$(gh_key pr merge).exit"
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/merge.bats`
Expected: 6 failures.

- [ ] **Step 3: Implement**

Add to `agentfixer.sh`:

```bash
# -------------------------------------------------------------------- merge
af_step_merge() {
  local pr="$1" state head
  state="$(af_check_state "$pr")"
  case "$state" in
    pass) : ;;
    none) af_die "G3: PR #$pr has no required checks; refusing to merge." "$AF_EX_GATE" ;;
    *) af_die "G3: PR #$pr checks are '$state'; refusing to merge." "$AF_EX_GATE" ;;
  esac

  af_gate_workflows "$(git -C "$AF_WORKTREE" diff --name-only "$AF_BASE_SHA..HEAD")"

  head="$(git -C "$AF_WORKTREE" rev-parse HEAD)"
  ( cd "$AF_WORKTREE" && gh pr merge "$pr" --squash --delete-branch \
      --match-head-commit "$head" ) \
    || af_die "G3: merge of PR #$pr was refused (head moved, or not mergeable)." \
        "$AF_EX_GATE"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/merge.bats`
Expected: 6 passing. Then `shellcheck agentfixer.sh`.

- [ ] **Step 5: Commit**

```bash
git add agentfixer.sh tests/merge.bats
git commit -m "feat: G3 merge gate requiring non-empty passing required checks

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Display, spend accounting, and `--plain`

This task also fixes a latent bug in Task 3: `af_run_agent` updates `AF_SPEND`
as a shell variable, but Task 6 already runs it in background subshells and
this task adds a spinner that does the same. Variable assignments in a subshell
are lost. Spend must go to a file.

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/display.bats`

**Interfaces:**
- Consumes: `AF_RUN_DIR`.
- Produces: `af_total_spend` (prints dollars), `af_status <step> <state> <note>`, `af_set_blurb <json_array>`, `af_render`, `af_with_spinner <step> <cmd...>`, `AF_PLAIN`.
- Modified: `af_run_agent` appends its cost to `$AF_RUN_DIR/spend.txt` instead of assigning `AF_SPEND`.

- [ ] **Step 1: Write the failing test**

Create `tests/display.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1; AF_RUN_DIR='$AF_TMP/run'; mkdir -p \"\$AF_RUN_DIR\";"
}

@test "spend survives a subshell" {
  stub_claude probe '{}'
  run bash -c "$SRC
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi ) &
    wait
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o2.json' '$AF_TMP/o2.log' hi ) &
    wait
    af_total_spend"
  [ "$status" -eq 0 ]
  [ "$output" = "0.02" ]
}

@test "spend is zero before any agent runs" {
  run bash -c "$SRC af_total_spend"
  [ "$output" = "0.00" ]
}

@test "plain mode emits one timestamped line per status change" {
  run bash -c "$SRC af_status audit active 'starting'; af_status audit done '7 findings'"
  [[ "$output" == *"audit"* ]]
  [[ "$output" == *"7 findings"* ]]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "plain mode emits no ANSI escapes" {
  run bash -c "$SRC af_status audit active 'x'"
  ! [[ "$output" == *$'\e['* ]]
}

@test "blurb renders severity, location and text" {
  run bash -c "$SRC
    af_set_blurb '[{\"id\":\"F-01-1\",\"severity\":\"HIGH\",\"file\":\"src/db/query.ts\",\"line\":88,\"blurb\":\"sqli in where clause\"}]'
    af_status fix active '1 finding'"
  [[ "$output" == *"HIGH"* ]]
  [[ "$output" == *"src/db/query.ts:88"* ]]
  [[ "$output" == *"sqli in where clause"* ]]
}

@test "blurb lines are truncated to the terminal width" {
  long="$(printf 'x%.0s' $(seq 1 200))"
  run bash -c "$SRC COLUMNS=60
    af_set_blurb '[{\"id\":\"F-01-1\",\"severity\":\"LOW\",\"file\":\"a.ts\",\"line\":1,\"blurb\":\"$long\"}]'
    af_status fix active 'x'"
  while read -r line; do [ "${#line}" -le 60 ]; done <<< "$output"
}

@test "spinner waits for the command and propagates its exit code" {
  run bash -c "$SRC AF_SPIN_POLL=0; af_with_spinner fix bash -c 'exit 4'"
  [ "$status" -eq 4 ]
}

@test "spinner returns 0 for a successful command" {
  run bash -c "$SRC AF_SPIN_POLL=0; af_with_spinner fix true"
  [ "$status" -eq 0 ]
}

@test "plain mode is forced when stdout is not a tty" {
  run bash -c "source '$AF_SCRIPT'; af_init_display; echo PLAIN=\$AF_PLAIN"
  [[ "$output" == *"PLAIN=1"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/display.bats`
Expected: 9 failures.

- [ ] **Step 3: Change `af_run_agent` to record spend in a file**

In `agentfixer.sh`, replace the two lines

```bash
  local cost
  cost="$(jq -r '.total_cost_usd // 0' "$log")"
  AF_SPEND="$(awk -v a="$AF_SPEND" -v b="$cost" 'BEGIN{printf "%.2f", a+b}')"
```

with

```bash
  # Recorded in a file, not a variable: this function runs in background
  # subshells for the parallel audits and under the spinner, and a subshell's
  # variable assignments do not reach the parent.
  jq -r '.total_cost_usd // 0' "$log" >> "${AF_RUN_DIR:-.}/spend.txt"
```

and delete the `AF_SPEND="0"` declaration.

- [ ] **Step 4: Implement the display**

Add to `agentfixer.sh`, replacing the placeholder `af_log` from Task 3:

```bash
# ------------------------------------------------------------------ display
AF_PLAIN="${AF_PLAIN:-0}"
AF_SPIN_POLL="${AF_SPIN_POLL:-1}"
AF_SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
AF_REPO_LABEL=""
AF_ITER_LABEL=""
AF_BLURB=""
AF_LINES=0
AF_STEPS=(audit combine verify fix pr ci merge)
declare -A AF_STATE=()
declare -A AF_NOTE=()

af_init_display() {
  if [ ! -t 1 ]; then AF_PLAIN=1; fi
  local s
  for s in "${AF_STEPS[@]}"; do AF_STATE[$s]=pending; AF_NOTE[$s]=""; done
}

af_log() { printf '%s  %-5s %s\n' "$(date +%H:%M:%S)" "$1" "$2" >&2; }

af_total_spend() {
  awk '{t += $1} END {printf "%.2f\n", t}' "${AF_RUN_DIR:-.}/spend.txt" 2>/dev/null \
    || printf '0.00\n'
}

af_width() { printf '%s' "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"; }

# af_set_blurb <json array of findings>
af_set_blurb() {
  local w
  w="$(af_width)"
  AF_BLURB="$(printf '%s' "$1" | jq -r '
    .[] | "     \(.severity)  \(.file):\(.line)  \(.blurb)"' \
    | cut -c "1-$w")"
}

af_status() {
  AF_STATE[$1]="$2"
  AF_NOTE[$1]="${3:-}"
  af_render "$1"
}

af_render() {
  if [ "$AF_PLAIN" = "1" ]; then
    af_log "${AF_STATE[$1]:-info}" "$(printf '%-8s %s' "$1" "${AF_NOTE[$1]:-}")"
    [ -n "$AF_BLURB" ] && printf '%s\n' "$AF_BLURB"
    return 0
  fi
  af_render_tty
}

af_render_tty() {
  local out="" s mark
  # Rewind over whatever we drew last time.
  if [ "$AF_LINES" -gt 0 ]; then
    printf '\033[%dA\033[J' "$AF_LINES"
  fi
  out+=" agentfixer · $AF_REPO_LABEL · $AF_ITER_LABEL"$'\n'
  out+=" $(printf '─%.0s' $(seq 1 50))"$'\n'
  for s in "${AF_STEPS[@]}"; do
    case "${AF_STATE[$s]:-pending}" in
      done)    mark="✔" ;;
      failed)  mark="✘" ;;
      active)  mark="${AF_SPIN_FRAMES:0:1}" ;;
      *)       mark="·" ;;
    esac
    out+="$(printf '  %s %-9s %s' "$mark" "$s" "${AF_NOTE[$s]:-}")"$'\n'
    if [ "${AF_STATE[$s]:-}" = "active" ] && [ -n "$AF_BLURB" ]; then
      out+="$AF_BLURB"$'\n'
    fi
  done
  out+=" $(printf '─%.0s' $(seq 1 50))"$'\n'
  out+=" spent: \$$(af_total_spend)"$'\n'
  printf '%s' "$out"
  AF_LINES="$(printf '%s' "$out" | grep -c '')"
}

# Runs a command in the background and redraws until it exits. kill -0 polls a
# real condition; nothing here sleeps and hopes, and nothing is killed by name.
af_with_spinner() {
  local step="$1"; shift
  "$@" & local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$AF_PLAIN" != "1" ]; then
      AF_SPIN_FRAMES="${AF_SPIN_FRAMES:1}${AF_SPIN_FRAMES:0:1}"
      af_render "$step"
    fi
    if [ "$AF_SPIN_POLL" -gt 0 ]; then sleep "$AF_SPIN_POLL"; else break; fi
    i=$(( i + 1 ))
  done
  wait "$pid"
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bats tests/display.bats`
Expected: 9 passing.

- [ ] **Step 6: Re-run the whole suite — the spend change touches Task 3**

Run: `bats tests/`
Expected: all passing. Fix `tests/agent.bats`'s "accumulates spend" case to use `af_total_spend` with `AF_RUN_DIR` set. Then `shellcheck agentfixer.sh`.

- [ ] **Step 7: Commit**

```bash
git add agentfixer.sh tests/display.bats tests/agent.bats
git commit -m "feat: live status display, file-backed spend accounting, plain mode

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Iteration loop, CLI parsing, and `--dry-run`

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/loop.bats`

**Interfaces:**
- Consumes: every `af_step_*`, `af_preflight`, `af_setup_run`, `af_cleanup_worktree`, `af_status`, `af_with_spinner`.
- Produces: `af_run_repo <repo_dir> <name> <iterations>`, `af_main` (rewritten with full option parsing).

- [ ] **Step 1: Write the failing test**

Create `tests/loop.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1; AF_POLL=0; AF_SPIN_POLL=0;"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  stub_gh "$(gh_key auth status)" ""
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  F='{"findings":[{"id":"x","severity":"HIGH","file":"a.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'
  C='{"findings":[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e","source":"both"}]}'
  stub_claude audit-sec "$F"
  stub_claude audit-hostile "$F"
  stub_claude combine "$C"
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"}]}'
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
}

@test "a full green iteration merges and exits 0" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
}

@test "requested iteration count is honoured" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AF_STUB_DIR/claude/audit-sec.args")" -eq 2 ]
}

@test "an audit with no findings stops early and exits 0" {
  stub_claude audit-sec '{"findings":[]}'
  stub_claude audit-hostile '{"findings":[]}'
  stub_claude combine '{"findings":[]}'
  run bash -c "$SRC af_run_repo '$REPO' alpha 3"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  [[ "$output" == *"clean"* ]]
}

@test "all findings rejected opens no PR but continues" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":false,"reason":"no"}]}'
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  ! grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  [ "$(wc -l < "$AF_STUB_DIR/claude/audit-sec.args")" -eq 2 ]
}

@test "dry-run stops after verify and never branches or pushes" {
  run bash -c "$SRC AF_DRY_RUN=1; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  ! grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  ! [[ "$output" == *"agentfixer/"* ]]
}

@test "preflight failure exits 1 before any agent runs" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}

@test "CI exhaustion halts before the second iteration" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run view)" 'FAIL'
  stub_claude cifix '{"diagnosis":"d","files_changed":["a.ts"],"confident":false}'
  stub_claude_side_effect cifix 'echo more > a.ts'
  run bash -c "$SRC AF_CI_RETRIES=1; af_run_repo '$REPO' alpha 5"
  [ "$status" -eq 2 ]
  [ "$(wc -l < "$AF_STUB_DIR/claude/audit-sec.args")" -eq 1 ]
}

@test "reports total spend on completion" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [[ "$output" == *"spent"* ]]
}

@test "--iterations must be a positive integer" {
  run "$AF_SCRIPT" --repo alpha --iterations zero
  [ "$status" -eq 1 ]
}

@test "--repo naming a missing directory exits 1" {
  run "$AF_SCRIPT" --repo nosuchrepo --workspace "$AF_TMP/ws" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"nosuchrepo"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/loop.bats`
Expected: 10 failures.

- [ ] **Step 3: Implement the loop**

Add to `agentfixer.sh`:

```bash
# ---------------------------------------------------------------- iteration
AF_DRY_RUN="${AF_DRY_RUN:-0}"

af_run_repo() {
  local dir="$1" name="$2" iters="$3" base n iter nfind nconf
  af_init_display
  AF_REPO_LABEL="$name"

  base="$(af_preflight "$dir")"
  af_setup_run "$dir" "$name" "$base"
  trap 'af_cleanup_worktree "$dir"' EXIT

  for (( n = 1; n <= iters; n++ )); do
    AF_ITER_LABEL="iteration $n/$iters"
    iter="$(af_iter_dir "$n")"

    af_status audit active "2 auditors"
    af_with_spinner audit af_step_audit "$iter"
    af_status audit done "sec $(jq '.findings|length' "$iter/audit-sec.json") · hostile $(jq '.findings|length' "$iter/audit-hostile.json")"

    af_status combine active ""
    af_with_spinner combine af_step_combine "$iter" "$n"
    nfind="$(jq '.findings | length' "$iter/findings.json")"
    af_status combine done "$nfind unique"

    if [ "$nfind" -eq 0 ]; then
      af_log info "$name is clean: no findings in iteration $n. Stopping."
      break
    fi

    af_status verify active "$nfind claims"
    af_with_spinner verify af_step_verify "$iter"
    nconf="$(jq '[.verdicts[] | select(.confirmed)] | length' "$iter/verified.json")"
    af_status verify done "$nconf confirmed · $(( nfind - nconf )) rejected"

    if [ "$nconf" -eq 0 ]; then
      af_log info "iteration $n: every finding was rejected by verification"
      continue
    fi

    af_confirmed "$iter" > "$iter/confirmed.json"
    af_set_blurb "$(cat "$iter/confirmed.json")"

    if [ "$AF_DRY_RUN" = "1" ]; then
      af_log info "dry run: would fix $nconf findings"
      jq -r '.[] | "  \(.severity)  \(.file):\(.line)  \(.title)"' "$iter/confirmed.json"
      break
    fi

    af_status fix active "$nconf findings · parallel subagents"
    af_with_spinner fix af_step_fix "$iter"
    af_commit_fixes "$iter" "$n"
    af_status fix done "$nconf fixed"
    AF_BLURB=""

    af_status pr active ""
    af_step_pr "$iter" "$n" "$iters" "$base"
    af_status pr done "#$AF_PR_NUM"

    af_status ci active "waiting"
    af_ci_loop "$iter" "$AF_PR_NUM"
    af_status ci done "green"

    af_status merge active ""
    af_step_merge "$AF_PR_NUM"
    af_status merge done "squashed"

    git -C "$dir" fetch --quiet origin
    AF_BASE_SHA="$(git -C "$dir" rev-parse "origin/$base")"
    git -C "$AF_WORKTREE" reset --hard --quiet "$AF_BASE_SHA"
  done

  af_log info "$name finished. spent \$$(af_total_spend)"
}
```

Note the `reset --hard` at the end of each iteration: after a squash-merge the
worktree branch is stale, and the next iteration must audit the merged base,
not the pre-merge branch.

- [ ] **Step 4: Rewrite `af_main` with full option parsing**

Replace the Task 1 `af_main` with:

```bash
af_main() {
  local repo="" iters=1 ws="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)       repo="${2:-}"; shift 2 ;;
      --iterations) iters="${2:-}"; shift 2 ;;
      --workspace)  ws="${2:-}"; shift 2 ;;
      --base)       AF_BASE="${2:-}"; shift 2 ;;
      --plain)      AF_PLAIN=1; shift ;;
      --dry-run)    AF_DRY_RUN=1; shift ;;
      --yes|-y)     yes=1; shift ;;
      --version)    printf 'agentfixer %s\n' "$AF_VERSION"; return 0 ;;
      -h|--help)    af_usage; return 0 ;;
      *)            af_die "unknown option: $1" "$AF_EX_USAGE" ;;
    esac
  done

  case "$iters" in
    ''|*[!0-9]*) af_die "--iterations must be a positive integer" "$AF_EX_USAGE" ;;
  esac
  [ "$iters" -ge 1 ] || af_die "--iterations must be at least 1" "$AF_EX_USAGE"

  [ -n "$ws" ] || ws="$(af_resolve_workspace)"

  if [ -n "$repo" ]; then
    [ -d "$ws/$repo/.git" ] || af_die "no git repo named '$repo' in $ws" "$AF_EX_USAGE"
    af_run_repo "$ws/$repo" "$repo" "$iters"
    return 0
  fi

  af_interactive "$ws" "$iters" "$yes"
}

af_usage() {
  cat <<'USAGE'
usage: agentfixer.sh [options]

  --repo NAME         repo in the workspace to run against; omit for a picker
  --iterations N      how many audit/fix/merge cycles to run (default 1)
  --workspace DIR     directory holding the repos (default: parent of this repo)
  --base BRANCH       base branch (default: the remote HEAD)
  --dry-run           audit and verify only; change nothing
  --plain             line output instead of a live display
  --yes, -y           skip the confirmation prompt
  --version, -h
USAGE
}
```

- [ ] **Step 5: Run to verify it passes**

`af_interactive` arrives in Task 14; stub it for now so the suite runs:

```bash
af_interactive() { af_die "interactive mode not implemented yet" "$AF_EX_USAGE"; }
```

Run: `bats tests/loop.bats`
Expected: 10 passing. Then `bats tests/` and `shellcheck agentfixer.sh`.

- [ ] **Step 6: Commit**

```bash
git add agentfixer.sh tests/loop.bats
git commit -m "feat: iteration loop, option parsing, dry-run

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Interactive picker and tmux tabs

**Files:**
- Modify: `agentfixer.sh`
- Create: `tests/stubs/fzf`, `tests/stubs/tmux`, `tests/interactive.bats`
- Modify: `tests/helpers.bash` (copy the two new stubs), `.github/workflows/ci.yml` (shellcheck the new stubs)

**Interfaces:**
- Consumes: `af_list_repos`, `af_run_repo`, `af_die`.
- Produces: `af_pick_repos <workspace>`, `af_confirm <repos> <iters>`, `af_launch_tmux <iters> <repo...>`, `af_interactive <workspace> <iters> <yes>` (replacing the Task 13 stub).

- [ ] **Step 1: Write the fzf and tmux stubs**

Create `tests/stubs/fzf`:

```bash
#!/usr/bin/env bash
# Stub fzf: echoes whatever $AF_STUB_FZF says, ignoring stdin.
set -euo pipefail
cat >/dev/null
printf '%s\n' "${AF_STUB_FZF:-}"
```

Create `tests/stubs/tmux`:

```bash
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${AF_STUB_DIR:?}/tmux.log"
# `has-session` succeeds only when the test says the session exists.
if [ "${1:-}" = "has-session" ] && [ "${AF_STUB_TMUX_HAS:-0}" != "1" ]; then
  exit 1
fi
exit 0
```

Add both to `setup_stub_env` in `tests/helpers.bash`, alongside `claude` and `gh`:

```bash
  cp "$AF_ROOT/tests/stubs/fzf" "$AF_TMP/bin/fzf"
  cp "$AF_ROOT/tests/stubs/tmux" "$AF_TMP/bin/tmux"
  chmod +x "$AF_TMP/bin/fzf" "$AF_TMP/bin/tmux"
```

Add a helper:

```bash
tmux_calls() { cat "$AF_STUB_DIR/tmux.log" 2>/dev/null || true; }
```

- [ ] **Step 2: Write the failing test**

Create `tests/interactive.bats`:

```bash
setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1;"
  make_repo alpha >/dev/null
  make_repo beta >/dev/null
  unset TMUX
}

@test "picker returns the fzf selection" {
  run bash -c "AF_STUB_FZF='alpha' $SRC af_pick_repos '$AF_TMP/ws'"
  [ "$output" = "alpha" ]
}

@test "an empty selection exits 1" {
  run bash -c "AF_STUB_FZF='' $SRC af_pick_repos '$AF_TMP/ws'"
  [ "$status" -eq 1 ]
}

@test "confirmation states the repos, iterations and worst-case spend" {
  run bash -c "$SRC af_confirm 'alpha
beta' 3 </dev/null"
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" == *"3"* ]]
  [[ "$output" == *'$'* ]]
}

@test "declining the confirmation exits 1 and runs nothing" {
  run bash -c "$SRC echo n | af_confirm 'alpha' 1"
  [ "$status" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}

@test "two repos create one tmux window each, named after the repo" {
  run bash -c "$SRC af_launch_tmux 2 alpha beta"
  [ "$status" -eq 0 ]
  grep -q 'new-session' "$AF_STUB_DIR/tmux.log"
  grep -q -- '-n alpha' "$AF_STUB_DIR/tmux.log"
  grep -q -- '-n beta' "$AF_STUB_DIR/tmux.log"
  grep -q -- '--iterations 2' "$AF_STUB_DIR/tmux.log"
  grep -q -- '--yes' "$AF_STUB_DIR/tmux.log"
}

@test "inside tmux it adds windows instead of nesting a session" {
  run bash -c "TMUX=/tmp/fake,1,0 $SRC af_launch_tmux 1 alpha beta"
  [ "$status" -eq 0 ]
  ! grep -q 'new-session' "$AF_STUB_DIR/tmux.log"
  grep -q 'new-window' "$AF_STUB_DIR/tmux.log"
}

@test "a single repo runs in the foreground, not tmux" {
  run bash -c "AF_STUB_FZF='alpha' $SRC
    af_run_repo() { echo FOREGROUND \"\$2\"; }
    af_interactive '$AF_TMP/ws' 1 1"
  [[ "$output" == *"FOREGROUND alpha"* ]]
  [ ! -f "$AF_STUB_DIR/tmux.log" ]
}

@test "tmux is required for a multi-repo run" {
  run bash -c "AF_STUB_FZF='alpha
beta' $SRC
    PATH=\"\$(echo \"\$PATH\" | tr ':' '\n' | grep -v \"$AF_TMP/bin\" | paste -sd:)\"
    PATH=\"$AF_TMP/bin2:\$PATH\"
    af_interactive '$AF_TMP/ws' 1 1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tmux"* ]]
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `bats tests/interactive.bats`
Expected: 8 failures.

- [ ] **Step 4: Implement**

Replace the `af_interactive` stub in `agentfixer.sh` with:

```bash
# -------------------------------------------------------------- interactive
af_pick_repos() {
  local ws="$1" repos sel
  repos="$(af_list_repos "$ws")"
  [ -n "$repos" ] || af_die "no git repos found in $ws" "$AF_EX_USAGE"
  sel="$(printf '%s\n' "$repos" | fzf --multi \
    --prompt 'repos > ' --header 'TAB to select multiple, ENTER to confirm')"
  [ -n "$sel" ] || af_die "nothing selected" "$AF_EX_USAGE"
  printf '%s\n' "$sel"
}

# Worst case per iteration, from the budget caps: both audits, combine,
# verify, fix, and every permitted cifix retry.
af_worst_case() {
  awk -v a="$AF_BUDGET_AUDIT" -v c="$AF_BUDGET_COMBINE" -v v="$AF_BUDGET_VERIFY" \
      -v f="$AF_BUDGET_FIX" -v x="$AF_BUDGET_CIFIX" -v r="$AF_CI_RETRIES" \
      -v n="$1" -v i="$2" \
      'BEGIN { printf "%.2f", n * i * (2*a + c + v + f + r*x) }'
}

af_confirm() {
  local repos="$1" iters="$2" count reply
  count="$(printf '%s\n' "$repos" | grep -c '')"
  printf '\n  repos:      %s\n' "$(printf '%s' "$repos" | tr '\n' ' ')"
  printf '  iterations: %s each\n' "$iters"
  printf '  worst case: $%s (budget caps, not an estimate)\n' \
    "$(af_worst_case "$count" "$iters")"
  printf '\n  Agents will open and merge PRs in these repos. Continue? [y/N] '
  read -r reply
  case "$reply" in
    y|Y) return 0 ;;
    *) af_die "cancelled" "$AF_EX_USAGE" ;;
  esac
}

af_launch_tmux() {
  local iters="$1"; shift
  local self repo first=1
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  command -v tmux >/dev/null || af_die "tmux is required for a multi-repo run" "$AF_EX_USAGE"

  for repo in "$@"; do
    local cmd="$self --repo $repo --iterations $iters --yes"
    if [ -n "${TMUX:-}" ]; then
      tmux new-window -n "$repo" "$cmd"
    elif [ "$first" = "1" ]; then
      tmux new-session -d -s agentfixer -n "$repo" "$cmd"
      first=0
    else
      tmux new-window -t agentfixer -n "$repo" "$cmd"
    fi
  done
  [ -n "${TMUX:-}" ] || tmux attach-session -t agentfixer
}

af_interactive() {
  local ws="$1" iters="$2" yes="$3" sel count
  sel="$(af_pick_repos "$ws")"
  [ "$yes" = "1" ] || af_confirm "$sel" "$iters"
  count="$(printf '%s\n' "$sel" | grep -c '')"
  if [ "$count" -eq 1 ]; then
    af_run_repo "$ws/$sel" "$sel" "$iters"
  else
    # shellcheck disable=SC2086
    af_launch_tmux "$iters" $sel
  fi
}
```

Also prompt for the iteration count when it was not given. Add to `af_main`,
just before the `af_interactive` call:

```bash
  if [ -t 0 ] && [ "$iters" = "1" ] && [ "$yes" = "0" ]; then
    printf 'iterations [1]: '
    read -r reply
    case "$reply" in
      ''|*[!0-9]*) : ;;
      *) iters="$reply" ;;
    esac
  fi
```

Declare `local reply` at the top of `af_main`.

- [ ] **Step 5: Run to verify it passes**

Run: `bats tests/interactive.bats`
Expected: 8 passing. Then `bats tests/` and
`shellcheck agentfixer.sh tests/stubs/*`.

- [ ] **Step 6: Add the new stubs to CI lint**

In `.github/workflows/ci.yml`, change the shellcheck line to:

```yaml
      - run: shellcheck agentfixer.sh tests/stubs/*
```

- [ ] **Step 7: Commit**

```bash
git add agentfixer.sh tests .github/workflows/ci.yml
git commit -m "feat: fzf repo picker, confirmation screen, tmux tabs

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: README and install

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: no code.

- [ ] **Step 1: Write the README**

Create `README.md`:

````markdown
# agentfixer

Point it at a git repo. It audits the code with two independent Claude agents,
re-verifies every finding in a fresh context, fixes the confirmed ones, opens a
PR, drives it to green CI, and merges. Repeat N times.

Every pipeline step is a separate `claude -p` process, so each one starts with
a clean context. Merge policy, retry caps, and tamper gates are shell
conditionals — not instructions in a prompt.

## Install

```bash
git clone git@github.com:<you>/agentfixer.git ~/git/agentfixer
ln -s ~/git/agentfixer/agentfixer.sh ~/git/agentfixer.sh
```

Requires `claude`, `gh` (authenticated), `jq`, `git`, `fzf`, and `tmux` for
multi-repo runs.

## Use

```bash
~/git/agentfixer.sh                                  # pick repos, pick N, go
~/git/agentfixer.sh --repo myapp --iterations 5      # headless, one repo
~/git/agentfixer.sh --repo myapp --dry-run           # audit and verify only
~/git/agentfixer.sh --repo myapp --plain --yes       # for cron
```

Selecting two or more repos opens a tmux session with one tab per repo. Detach
with `C-b d`; the run keeps going.

## Branch protection is required

agentfixer refuses to run against a repo whose base branch is unprotected, and
refuses to merge a PR that has **zero** required status checks. Green with
nothing to be green about is not evidence, and this tool's last step is a merge.

Enable it at `https://github.com/<owner>/<repo>/settings/branches`, requiring at
least one status check.

## What it will not do

- Push to a branch directly. It only opens PRs.
- Create or modify anything under `.github/`. An agent that can edit workflows
  can make CI green by deleting the tests, so a diff check aborts the run.
- Force push. Ever.
- Touch your working tree. All work happens in a throwaway git worktree under
  `~/.cache/agentfixer/`.
- Delete a worktree that holds unmerged commits or uncommitted changes.

## Exit codes

| code | meaning |
|---|---|
| 0 | completed |
| 1 | usage or preflight failure; nothing was spent |
| 2 | CI could not be made green; PR left open and labelled `needs-human` |
| 3 | a safety gate tripped |
| 4 | an agent returned invalid or incomplete output |

## Cost

Each step has a `--max-budget-usd` cap. Worst case per iteration is $25 with the
defaults; the confirmation screen shows the worst case for the whole run before
anything starts. Override with `AF_BUDGET_AUDIT`, `AF_BUDGET_FIX`, and friends.

## Development

```bash
bats tests/
shellcheck agentfixer.sh tests/stubs/*
```

Tests stub `claude` and `gh` on `PATH` and run against real temporary git
repos. `git` is never stubbed — git behaviour is what needs proving.
````

- [ ] **Step 2: Verify the documented commands are real**

Run: `./agentfixer.sh --help` and confirm every flag in the README appears.
Run: `bats tests/ && shellcheck agentfixer.sh tests/stubs/*`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with install, safety guarantees, and exit codes

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Enable branch protection on this repo**

Manual, and required — agentfixer refuses to merge into unprotected branches,
so its own repo must not be an exception. Push to GitHub, then at
`https://github.com/<you>/agentfixer/settings/branches` add a rule for the
default branch requiring the `lint` and `test` checks.

Verify: `gh api repos/<you>/agentfixer/branches/main --jq .protected` → `true`
