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
