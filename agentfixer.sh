#!/usr/bin/env bash
# agentfixer - repeated audit/verify/fix/PR/CI/merge loop driven by Claude agents.
set -euo pipefail

AF_VERSION="0.1.0"

# ---------------------------------------------------------------- exit codes
export AF_EX_USAGE=1
export AF_EX_CI=2
export AF_EX_GATE=3
export AF_EX_SCHEMA=4

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
