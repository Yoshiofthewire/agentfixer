#!/usr/bin/env bash
# agentfixer - repeated audit/verify/fix/PR/CI/merge loop driven by Claude agents.
set -euo pipefail

AF_VERSION="0.1.0"

# ---------------------------------------------------------------- exit codes
readonly AF_EX_USAGE=1
# shellcheck disable=SC2034  # AF_EX_CI is used by later pipeline steps
readonly AF_EX_CI=2
readonly AF_EX_GATE=3
# shellcheck disable=SC2034
readonly AF_EX_SCHEMA=4

af_die() { printf 'agentfixer: %s\n' "$1" >&2; exit "${2:-$AF_EX_USAGE}"; }

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
  awk '{t += $1} END {printf "%.2f\n", t}' "$AF_RUN_DIR/spend.txt" 2>/dev/null \
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

# ---------------------------------------------------------------- preflight
# Hard-assigned, never `${AF_SLUG:-}`: ambient environment must not be able to
# point this tool's gh calls at a repository the user did not name.
AF_SLUG=""
AF_BASE_BRANCH=""

af_repo_slug() {
  local url
  url="$(git -C "$1" config --get remote.origin.url 2>/dev/null)" || return 1
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

# Results go to globals, NOT stdout: a `base="$(af_preflight ...)"` caller runs
# this in a subshell, where the AF_SLUG assignment dies with it and every later
# `gh --repo "$AF_SLUG"` falls back to git-remote discovery in the launch
# directory - a different repository than the one being merged.
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
  AF_SLUG="$slug"
  AF_BASE_BRANCH="$base"
}

# Every gh call in this tool passes --repo "$AF_SLUG". Real gh does not error
# on an empty --repo: it silently falls back to the cwd's git remote. That is
# the wrong repository at every call site that does not cd into the worktree,
# so an unset slug must stop the run, not be papered over.
af_require_slug() {
  [ -n "$AF_SLUG" ] || af_die "internal error: AF_SLUG unset" "$AF_EX_USAGE"
}

# ------------------------------------------------------------------ sandbox
# Confines write-mode (rw) agents: they ingest untrusted repo content and run
# with bypassPermissions, so a prompt injection there has unrestricted Bash.
# Read-only steps are never sandboxed - they need ~/.claude/skills on the real
# filesystem to resolve /security-audit and /hostile-review.
AF_SANDBOX="${AF_SANDBOX:-1}"

af_sandbox_available() { command -v bwrap >/dev/null 2>&1; }

af_sandbox_warn() {
  af_log WARNING "running a write-mode agent unsandboxed; it can read every file your user can, including ~/.ssh and ~/.config/gh"
}

# Prints the bwrap argv prefix, one argument per line, for mapfile. Pure: no
# side effects. Order matters - --tmpfs "$HOME" masks the whole home
# directory, then --ro-bind re-exposes just ~/.claude, read-only, since its
# settings.json can define hooks that run on the user's next `claude` session.
#
# What this does and does not protect, precisely:
#   - Protects: everything under $HOME is hidden (masked by the tmpfs),
#     including ~/.ssh, ~/.config/gh, ~/.aws, shell history, and any other
#     repo checked out under $HOME. Only $HOME/.claude (read-only) and
#     $AF_WORKTREE (read-write) are re-exposed.
#   - Does NOT block network egress - claude is itself an LLM API client, so
#     unshare-net would break it. This is an accepted residual risk, not an
#     oversight.
#   - Does NOT hide anything outside $HOME - the whole host filesystem is
#     bound read-only via --ro-bind / /, so other repos, /etc, and any
#     world-readable file outside $HOME remain readable inside the sandbox.
#   - Re-exposes the target repository's git directory, READ-ONLY. A linked
#     worktree's .git is only a pointer to <repo>/.git/worktrees/<name>, which
#     lives under $HOME behind the tmpfs; without this bind every git command
#     inside the sandbox fails with "not a git repository", so the agent
#     cannot run a test suite that shells out to git, read history, or diff
#     its own work. Read-only is enough for all three and keeps the property
#     that only bash ever writes git state. The whole repository history
#     becomes readable inside the sandbox - it is the repository the agent is
#     already editing.
af_sandbox_prefix() {
  local -a gitdir=()
  if [ -n "${AF_GITDIR:-}" ]; then
    gitdir=(--ro-bind "$AF_GITDIR" "$AF_GITDIR")
  fi
  printf '%s\n' bwrap \
    --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp \
    --tmpfs "$HOME" \
    --ro-bind "$HOME/.claude" "$HOME/.claude" \
    --bind "$AF_WORKTREE" "$AF_WORKTREE" \
    "${gitdir[@]}" \
    --unshare-pid --new-session --die-with-parent \
    --setenv HOME "$HOME"
}

# ------------------------------------------------------------ agent wrapper

# af_run_agent STEP MODEL BUDGET MODE SCHEMA OUT LOG PROMPT
# MODE is "ro" (read-only) or "rw" (write, bypassPermissions, sandboxed).
# Writes .structured_output to OUT, the raw envelope to LOG.
af_run_agent() {
  local step="$1" model="$2" budget="$3" mode="$4" schema="$5"
  local out="$6" log="$7" prompt="$8"
  : "${AF_RUN_DIR:?internal error: agent invoked before af_setup_run}"
  local -a args=(
    --print --output-format json --no-session-persistence
    --model "$model" --max-budget-usd "$budget" --json-schema "$schema"
  )
  local -a sandbox_pfx=()
  local -a cred_scrub=()
  if [ "$mode" = "rw" ]; then
    args+=(--permission-mode bypassPermissions
           --disallowed-tools 'WebFetch WebSearch')
    # The fix/cifix agents never need GitHub or SSH credentials - bash does
    # every git push, gh pr create, and gh pr merge in this tool. Scrub them
    # regardless of AF_SANDBOX: defence in depth against a bind-mount mistake.
    cred_scrub=(env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
                -u GITHUB_ENTERPRISE_TOKEN -u SSH_AUTH_SOCK -u GH_CONFIG_DIR \
                -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY)
    # Create ~/.claude if a fresh runner lacks it, so the ro-bind source
    # exists; never widen it to a writable bind.
    mkdir -p "$HOME/.claude"
    if [ "$AF_SANDBOX" = "1" ]; then
      af_sandbox_available \
        || af_die "step '$step': bwrap not found; write-mode steps require bubblewrap for filesystem confinement. Install bubblewrap, or pass --no-sandbox to run unsandboxed (not recommended)." "$AF_EX_GATE"
      mapfile -t sandbox_pfx < <(af_sandbox_prefix)
    else
      af_sandbox_warn
    fi
  else
    args+=(--disallowed-tools 'Edit Write NotebookEdit WebFetch WebSearch')
  fi

  local rc=0
  if [ "$mode" = "rw" ]; then
    AF_STEP="$step" "${sandbox_pfx[@]}" "${cred_scrub[@]}" claude "${args[@]}" "$prompt" \
      > "$log" 2>>"$log.stderr" || rc=$?
  else
    AF_STEP="$step" claude "${args[@]}" "$prompt" > "$log" 2>>"$log.stderr" || rc=$?
  fi
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

  # Recorded in a file, not a variable: this function runs in background
  # subshells for the parallel audits and under the spinner, and a subshell's
  # variable assignments do not reach the parent.
  jq -r '.total_cost_usd // 0' "$log" >> "$AF_RUN_DIR/spend.txt"

  if jq -e '(.permission_denials | length) > 0' "$log" >/dev/null 2>&1; then
    af_log warn "step '$step' had tool denials; see $log"
  fi
}

# ---------------------------------------------------------------- schemas
# shellcheck disable=SC2034  # AF_SCHEMA_* are consumed by later pipeline steps
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

# shellcheck disable=SC2034
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

# shellcheck disable=SC2034
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

# ------------------------------------------------------------ run lifecycle
AF_RUN_DIR="${AF_RUN_DIR:-}"
AF_WORKTREE="${AF_WORKTREE:-}"
AF_BRANCH="${AF_BRANCH:-}"
# Set by af_run_repo, read by its EXIT trap. A `local` here would not do: a
# set -e-triggered exit (as opposed to an explicit `exit` call) fires the
# trap after the failing function's local scope has already been popped, so
# a local var reads as unbound under set -u. A global survives that.
AF_REPO_DIR="${AF_REPO_DIR:-}"
AF_BASE_SHA="${AF_BASE_SHA:-}"
# Hard-assigned, never from the environment: this path is bound into the
# write-mode sandbox, so ambient state must not be able to choose it.
AF_GITDIR=""

af_setup_run() {
  local dir="$1" name="$2" base="$3" stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  AF_RUN_DIR="${AF_CACHE:-$HOME/.cache/agentfixer}/$name/$stamp"
  AF_WORKTREE="$AF_RUN_DIR/worktree"
  AF_BRANCH="agentfixer/$stamp"
  # Absolute: `rev-parse --git-common-dir` alone prints a path relative to the
  # repository, which is useless as a bind-mount source. --path-format needs
  # git >= 2.31.
  AF_GITDIR="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)" \
    || af_die "could not resolve the git directory of $dir"
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
  # A cat failure inside the nested $(...) below is swallowed by the outer
  # command substitution: the prompt would silently go out half-empty
  # instead of the step failing loudly. Check explicitly first.
  [ -f "$iter/audit-sec.json" ] \
    || af_die "combine: missing $iter/audit-sec.json (audit did not run)" "$AF_EX_USAGE"
  [ -f "$iter/audit-hostile.json" ] \
    || af_die "combine: missing $iter/audit-hostile.json (audit did not run)" "$AF_EX_USAGE"
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

AF_MODEL_FIX="${AF_MODEL_FIX:-opus}"
AF_BUDGET_FIX="${AF_BUDGET_FIX:-6}"
AF_TRAILER="Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"

# G1 - an agent that can edit workflows can make CI green by deleting the
# tests. Takes paths as one argument, newline separated. Not a pipeline:
# af_die inside a pipeline exits a subshell the caller never sees.
# ($|/) rather than a bare /: a symlink or gitlink mounted at exactly
# .github (no pre-existing tracked .github/ entry to expand into a
# directory) is reported by git status as the bare string ".github", with
# no trailing slash, and a plain ^\.github/ prefix match misses it.
af_gate_workflows() {
  local bad
  bad="$(printf '%s\n' "$1" | grep -E '^\.github($|/)' || true)"
  if [ -n "$bad" ]; then
    af_die "G1: agent modified workflow or CI configuration:
$bad" "$AF_EX_GATE"
  fi
}

# -z is NUL-delimited and never quotes/escapes paths, unlike plain
# --porcelain: a path containing a space or a quote character silently
# corrupts awk/field-splitting parses and can hide a .github/ write from G1.
# For a rename/copy, git emits the new path (status-prefixed) followed by a
# second NUL-terminated record holding the bare old path; both are printed,
# so a rename INTO or OUT OF .github/ is visible to the gate either way.
af_changed_paths() {
  local rec status pending=0
  while IFS= read -r -d '' rec; do
    if [ "$pending" = 1 ]; then
      printf '%s\n' "$rec"
      pending=0
      continue
    fi
    status="${rec:0:2}"
    printf '%s\n' "${rec:3}"
    case "$status" in
      R*|C*) pending=1 ;;
    esac
  done < <(git -C "$AF_WORKTREE" status --porcelain -z)
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
  # Every finding may come back "skipped" - schema-valid, passes G2, nothing
  # staged. That is a valid outcome, not a failure: let git's raw "nothing to
  # commit" (exit 1, this project's usage/preflight code) leak through here
  # and a clean iteration reads as a preflight bug in a cron log. Report it as
  # a distinct non-zero status instead, so the caller skips the PR rather than
  # pushing a zero-commit branch for `gh pr create` to reject.
  if [ "$count" -eq 0 ]; then
    af_log warn "iteration $n: every finding was skipped, nothing to commit"
    return 1
  fi
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

# ---------------------------------------------------------------- pull request
AF_PR_NUM=""
AF_PR_URL=""

af_ensure_labels() {
  gh label create agent-authored --repo "$AF_SLUG" --color B60205 \
    --description "Authored by an automated agent" >/dev/null 2>&1 || true
  gh label create agentfixer --repo "$AF_SLUG" --color 0E8A16 \
    --description "Opened by agentfixer" >/dev/null 2>&1 || true
}

af_pr_body() {
  local iter="$1" n="$2" total="$3" fixed rejected
  fixed="$(jq -r -s '
    .[0] as $c | .[1].results as $r
    | [ $r[] | select(.status == "fixed") | .id as $id
        | ($c[] | select(.id == $id))
        | "- **\(.severity)** `\(.file):\(.line)` — \(.title)" ]
    | if length == 0 then "_None. Every confirmed finding was skipped._" else join("\n") end
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
  af_require_slug
  bodyfile="$iter/pr-body.md"
  af_pr_body "$iter" "$n" "$total" > "$bodyfile"
  title="fix: $(jq -r '[.results[] | select(.status == "fixed")] | length' \
    "$iter/fixed.json") verified findings (agentfixer $n/$total)"

  git -C "$AF_WORKTREE" push --quiet --set-upstream origin "$AF_BRANCH"
  af_ensure_labels

  AF_PR_URL="$(cd "$AF_WORKTREE" && gh pr create --repo "$AF_SLUG" \
    --base "$base" --head "$AF_BRANCH" \
    --title "$title" --body-file "$bodyfile" \
    --label agent-authored --label agentfixer)"
  AF_PR_NUM="${AF_PR_URL##*/}"
  printf '%s\n' "$AF_PR_URL" > "$iter/pr.txt"
  [ -n "$AF_PR_NUM" ] || af_die "could not determine PR number from: $AF_PR_URL" "$AF_EX_SCHEMA"
}

# ------------------------------------------------------------------- ci
AF_MODEL_CIFIX="${AF_MODEL_CIFIX:-sonnet}"
AF_BUDGET_CIFIX="${AF_BUDGET_CIFIX:-3}"
AF_CI_RETRIES="${AF_CI_RETRIES:-3}"
AF_CI_TIMEOUT="${AF_CI_TIMEOUT:-1800}"
AF_POLL="${AF_POLL:-15}"

# shellcheck disable=SC2034
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
  af_require_slug
  json="$(gh pr checks "$1" --required --repo "$AF_SLUG" --json bucket,name 2>/dev/null || echo '[]')"
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
  local iter="$1" attempt="$2" pr="$3" logs prompt run_id
  af_require_slug
  # `gh run view` with no run id needs a TTY - non-interactively it exits 1
  # with "run or job ID required when not running interactively" - and even
  # with a TTY it would pick the repository's most recent run, not this
  # branch's. Resolve the run explicitly, and never hand the repair agent an
  # empty log: it edits and pushes under bypassPermissions on whatever
  # evidence it is given, so no evidence must halt rather than proceed.
  run_id="$(gh run list --repo "$AF_SLUG" --branch "$AF_BRANCH" --limit 1 \
    --json databaseId --jq '.[0].databaseId // empty')" \
    || af_die "cifix: could not list workflow runs for $AF_BRANCH" "$AF_EX_CI"
  [ -n "$run_id" ] \
    || af_die "cifix: no workflow run found for $AF_BRANCH" "$AF_EX_CI"
  logs="$(gh run view "$run_id" --repo "$AF_SLUG" --log-failed | tail -n 400)" \
    || af_die "cifix: could not read the failing logs of run $run_id" "$AF_EX_CI"
  [ -n "$logs" ] \
    || af_die "cifix: run $run_id reported no failing job logs" "$AF_EX_CI"
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
  # A cifix attempt that makes no net change (or repeats a prior attempt's
  # edit verbatim) leaves nothing to commit. Same as af_commit_fixes: let
  # git's raw "nothing to commit" (exit 1, this project's own usage/preflight
  # code) leak through here and it looks like a preflight bug in a cron log,
  # and worse, silently truncates the retry loop before AF_CI_RETRIES.
  if [ -z "$(git -C "$AF_WORKTREE" status --porcelain)" ]; then
    af_log warn "cifix attempt $attempt made no changes; nothing to commit"
    return 0
  fi
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
        gh pr edit "$pr" --repo "$AF_SLUG" --add-label needs-human >/dev/null 2>&1 || true
        af_die "G3: PR #$pr has no required checks. Enable required status
checks in branch protection. PR left open." "$AF_EX_GATE" ;;
      timeout)
        gh pr edit "$pr" --repo "$AF_SLUG" --add-label needs-human >/dev/null 2>&1 || true
        af_die "CI did not settle within ${AF_CI_TIMEOUT}s. PR #$pr left open." \
          "$AF_EX_CI" ;;
    esac
    attempt=$(( attempt + 1 ))
    if [ "$attempt" -gt "$AF_CI_RETRIES" ]; then
      gh pr edit "$pr" --repo "$AF_SLUG" --add-label needs-human >/dev/null 2>&1 || true
      af_die "CI still failing after $AF_CI_RETRIES attempts. PR #$pr left open.
Halting the run: a PR that cannot be made green means something systemic." \
        "$AF_EX_CI"
    fi
    af_log info "CI failed, cifix attempt $attempt/$AF_CI_RETRIES"
    af_step_cifix "$iter" "$attempt" "$pr"
  done
}

# -------------------------------------------------------------------- merge
# --name-status, not --name-only: --name-only prints only the resulting path
# of a rename, silently dropping the old one. A commit that renames a
# required workflow OUT of .github/workflows/ (disabling it) would then
# produce no .github-prefixed entry at all and the gate would never trip.
# -z is NUL-delimited and never quotes/escapes paths, unlike the default
# format: a path containing a double quote, backslash, or non-ASCII byte is
# otherwise rewritten with the whole entry wrapped in quotes (e.g.
# `".github/workflows/ci \"x\".yml"`), which no longer starts with
# `.github` and also defeats the prefix match. Same two hazards
# af_changed_paths already hardens for the working-tree path (rename/copy
# awareness and -z); this is the committed-range counterpart used just
# before merge, so it must emit both old and new paths for R/C records.
af_range_paths() {
  local status old new path
  while IFS= read -r -d '' status; do
    case "$status" in
      R*|C*)
        IFS= read -r -d '' old
        IFS= read -r -d '' new
        printf '%s\n%s\n' "$old" "$new"
        ;;
      *)
        IFS= read -r -d '' path
        printf '%s\n' "$path"
        ;;
    esac
  done < <(git -C "$AF_WORKTREE" diff --name-status -z "$1")
}

af_step_merge() {
  local pr="$1" state head
  af_require_slug
  state="$(af_check_state "$pr")"
  case "$state" in
    pass) : ;;
    none) af_die "G3: PR #$pr has no required checks; refusing to merge." "$AF_EX_GATE" ;;
    *) af_die "G3: PR #$pr checks are '$state'; refusing to merge." "$AF_EX_GATE" ;;
  esac

  af_gate_workflows "$(af_range_paths "$AF_BASE_SHA..HEAD")"

  head="$(git -C "$AF_WORKTREE" rev-parse HEAD)"
  ( cd "$AF_WORKTREE" && gh pr merge "$pr" --repo "$AF_SLUG" --squash --delete-branch \
      --match-head-commit "$head" ) \
    || af_die "G3: merge of PR #$pr was refused (head moved, or not mergeable)." \
        "$AF_EX_GATE"
}

# ---------------------------------------------------------------- iteration
AF_DRY_RUN="${AF_DRY_RUN:-0}"

af_run_repo() {
  local dir="$1" name="$2" iters="$3" base n iter nfind nconf nfixed
  af_init_display
  AF_REPO_LABEL="$name"

  af_preflight "$dir"
  base="$AF_BASE_BRANCH"
  af_setup_run "$dir" "$name" "$base"
  AF_REPO_DIR="$dir"
  trap 'af_cleanup_worktree "$AF_REPO_DIR"' EXIT

  for (( n = 1; n <= iters; n++ )); do
    AF_ITER_LABEL="iteration $n/$iters"
    iter="$(af_iter_dir "$n")"

    af_status audit active "2 auditors"
    af_with_spinner audit af_step_audit "$iter"
    af_status audit "done" "sec $(jq '.findings|length' "$iter/audit-sec.json") · hostile $(jq '.findings|length' "$iter/audit-hostile.json")"

    af_status combine active ""
    af_with_spinner combine af_step_combine "$iter" "$n"
    nfind="$(jq '.findings | length' "$iter/findings.json")"
    af_status combine "done" "$nfind unique"

    if [ "$nfind" -eq 0 ]; then
      af_log info "$name is clean: no findings in iteration $n. Stopping."
      break
    fi

    af_status verify active "$nfind claims"
    af_with_spinner verify af_step_verify "$iter"
    nconf="$(jq '[.verdicts[] | select(.confirmed)] | length' "$iter/verified.json")"
    af_status verify "done" "$nconf confirmed · $(( nfind - nconf )) rejected"

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
    # `continue`, not `break`: a later iteration may still land something.
    if ! af_commit_fixes "$iter" "$n"; then
      af_status fix "done" "nothing committed"
      AF_BLURB=""
      af_log info "iteration $n: nothing committed, no PR"
      continue
    fi
    nfixed="$(jq -r '[.results[] | select(.status == "fixed")] | length' \
      "$iter/fixed.json")"
    af_status fix "done" "$nfixed fixed"
    AF_BLURB=""

    af_status pr active ""
    af_step_pr "$iter" "$n" "$iters" "$base"
    af_status pr "done" "#$AF_PR_NUM"

    af_status ci active "waiting"
    af_ci_loop "$iter" "$AF_PR_NUM"
    af_status ci "done" "green"

    af_status merge active ""
    af_step_merge "$AF_PR_NUM"
    af_status merge "done" "squashed"

    git -C "$dir" fetch --quiet origin
    AF_BASE_SHA="$(git -C "$dir" rev-parse "origin/$base")"
    git -C "$AF_WORKTREE" reset --hard --quiet "$AF_BASE_SHA"
  done

  af_log info "$name finished. spent \$$(af_total_spend)"
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
  --no-sandbox        run write-mode agents unsandboxed (not recommended)
  --yes, -y           skip the confirmation prompt
  --version           print the version and exit
  --help, -h          print this usage and exit
USAGE
}

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

  # `--` then argv, never a joined string: tmux's shell-command form runs a
  # single string through `sh -c`, which would let a repo directory name
  # containing shell metacharacters (e.g. `; rm -rf ~#`) execute arbitrary
  # commands. Passed as distinct arguments after `--`, tmux execs directly
  # with no shell in between - $repo can only ever land in argv, never in
  # anything a shell parses.
  for repo in "$@"; do
    if [ -n "${TMUX:-}" ]; then
      tmux new-window -n "$repo" -- "$self" --repo "$repo" --iterations "$iters" --yes
    elif [ "$first" = "1" ]; then
      tmux new-session -d -s agentfixer -n "$repo" -- "$self" --repo "$repo" --iterations "$iters" --yes
      first=0
    else
      tmux new-window -t agentfixer -n "$repo" -- "$self" --repo "$repo" --iterations "$iters" --yes
    fi
  done
  [ -n "${TMUX:-}" ] || tmux attach-session -t agentfixer
}

af_interactive() {
  local ws="$1" iters="$2" yes="$3" sel
  local -a repos
  sel="$(af_pick_repos "$ws")"
  [ "$yes" = "1" ] || af_confirm "$sel" "$iters"
  mapfile -t repos <<< "$sel"
  if [ "${#repos[@]}" -eq 1 ]; then
    af_run_repo "$ws/${repos[0]}" "${repos[0]}" "$iters"
  else
    af_launch_tmux "$iters" "${repos[@]}"
  fi
}

af_main() {
  # Internal run state is computed by af_setup_run, never inherited. These five
  # gate `git worktree remove --force` and, later, write-mode agent access.
  # AF_SANDBOX is reset too: ambient environment must not be able to disable
  # the sandbox without an explicit, logged --no-sandbox flag.
  AF_RUN_DIR=""; AF_WORKTREE=""; AF_BRANCH=""; AF_BASE_SHA=""; AF_REPO_DIR=""
  AF_SANDBOX=1
  local repo="" iters=1 ws="" yes=0 reply
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)       [ $# -ge 2 ] || af_die "--repo requires a value" "$AF_EX_USAGE"
                    repo="$2"; shift 2 ;;
      --iterations) [ $# -ge 2 ] || af_die "--iterations requires a value" "$AF_EX_USAGE"
                    iters="$2"; shift 2 ;;
      --workspace)  [ $# -ge 2 ] || af_die "--workspace requires a value" "$AF_EX_USAGE"
                    ws="$2"; shift 2 ;;
      --base)       [ $# -ge 2 ] || af_die "--base requires a value" "$AF_EX_USAGE"
                    AF_BASE="$2"; shift 2 ;;
      --plain)      AF_PLAIN=1; shift ;;
      --dry-run)    AF_DRY_RUN=1; shift ;;
      --no-sandbox) AF_SANDBOX=0; af_sandbox_warn; shift ;;
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

  if [ -t 0 ] && [ "$iters" = "1" ] && [ "$yes" = "0" ]; then
    printf 'iterations [1]: '
    read -r reply
    case "$reply" in
      ''|*[!0-9]*) : ;;
      *) iters="$reply" ;;
    esac
  fi

  af_interactive "$ws" "$iters" "$yes"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  af_main "$@"
fi
