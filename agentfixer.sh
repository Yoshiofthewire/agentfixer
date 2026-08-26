#!/usr/bin/env bash
# agentfixer - repeated audit/verify/fix/PR/CI/merge loop driven by Claude agents.
set -euo pipefail

AF_VERSION="0.1.0"

# ---------------------------------------------------------------- exit codes
readonly AF_EX_USAGE=1
# shellcheck disable=SC2034  # AF_EX_CI/GATE/SCHEMA are used by later pipeline steps
readonly AF_EX_CI=2
# shellcheck disable=SC2034
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

af_log() { printf '[%s] %s\n' "$1" "$2" >&2; }

# ---------------------------------------------------------------- preflight
AF_SLUG=""

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
  # shellcheck disable=SC2034  # AF_SLUG is used by later pipeline steps (tasks 9-11)
  AF_SLUG="$slug"
  printf '%s\n' "$base"
}

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
AF_BASE_SHA="${AF_BASE_SHA:-}"

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

af_main() {
  # Internal run state is computed by af_setup_run, never inherited. These four
  # gate `git worktree remove --force` and, later, write-mode agent access.
  AF_RUN_DIR=""; AF_WORKTREE=""; AF_BRANCH=""; AF_BASE_SHA=""
  case "${1:-}" in
    --version) printf 'agentfixer %s\n' "$AF_VERSION"; return 0 ;;
    -h|--help) printf 'usage: agentfixer.sh [--repo NAME] [--iterations N]\n'; return 0 ;;
    *) af_die "unknown option: ${1:-}" "$AF_EX_USAGE" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  af_main "$@"
fi
