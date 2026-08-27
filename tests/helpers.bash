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
  cp "$AF_ROOT/tests/stubs/fzf" "$AF_TMP/bin/fzf"
  cp "$AF_ROOT/tests/stubs/tmux" "$AF_TMP/bin/tmux"
  chmod +x "$AF_TMP/bin/claude" "$AF_TMP/bin/gh" "$AF_TMP/bin/fzf" "$AF_TMP/bin/tmux"
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

# stub_gh_side_effect <key> <bash source>  -- runs before the stubbed call returns
stub_gh_side_effect() { printf '%s' "$2" > "$AF_STUB_DIR/gh/$1.sh"; }

# stub_gh_seq <key> <n> <body>  -- response for the Nth call
stub_gh_seq() { printf '%s' "$3" > "$AF_STUB_DIR/gh/$1.$2"; }

# stub_gh_fail <key> <exit code> <stderr text>  -- a failing gh call
stub_gh_fail() {
  printf '%s' "$2" > "$AF_STUB_DIR/gh/$1.exit"
  printf '%s\n' "$3" > "$AF_STUB_DIR/gh/$1.err"
}

# refute_grep <grep args...> -- fails the test if grep MATCHES.
#
# Never write `! grep -q ...` in a test body: bash's set -e (and so bats'
# failure detection) explicitly exempts a command whose status is inverted
# with `!`, so unless it happens to be the very last statement of the test,
# a negated assertion is silently ignored and can never fail. Verified
# against bats 1.14: a mid-body `! grep -q PRESENT file` reports `ok`.
# A function that `return 1`s is a plain command failure, which is caught.
refute_grep() {
  if grep -q "$@"; then
    printf 'refute_grep: unexpectedly matched: %s\n' "$*" >&2
    return 1
  fi
}

# require_bwrap -- skip unless bwrap can actually confine a process.
#
# `command -v bwrap` only proves the binary is on PATH. On Ubuntu 24.04+,
# kernel.apparmor_restrict_unprivileged_userns=1 blocks the unprivileged user
# namespace bwrap needs, so a present-but-non-functional bwrap exits
# immediately - and CONFINEMENT tests that assert "X is unreadable"/"Y fails"
# would then pass for free, proving nothing. Verified locally with a bwrap
# stub on PATH that always exits 1: both negative confinement tests still
# reported `ok` when guarded only by `command -v bwrap`.
#
# Distinguishes the two failure modes in the skip reason because they need
# different fixes: install the package, vs. permit user namespaces
# (kernel.apparmor_restrict_unprivileged_userns=0) or run privileged/in a
# container.
require_bwrap() {
  command -v bwrap >/dev/null 2>&1 || skip "bwrap not installed"
  local err
  err="$(bwrap --ro-bind / / --tmpfs /tmp --unshare-pid --die-with-parent true 2>&1)" && return 0
  skip "bwrap installed but cannot create a user namespace (${err//$'\n'/ })"
}

# debug_output -- call right after `run`. Bats only shows a test's own stdout
# when the test fails, so this is silent on success. `run` merges stderr into
# $output by default, so this is what puts bwrap's actual error in the CI log
# instead of a bare "status -eq 0 failed" with no cause, which is what made
# the original CI failures undiagnosable from the log alone.
debug_output() { printf 'output was:\n%s\n' "$output"; }

gh_calls() { cat "$AF_STUB_DIR/gh/calls.log" 2>/dev/null || true; }

tmux_calls() { cat "$AF_STUB_DIR/tmux.log" 2>/dev/null || true; }

# gh_key <arg1> <arg2> -- mirrors the sanitizing in tests/stubs/gh
gh_key() { printf '%s_%s' "${1:-}" "${2:-}" | tr -c 'a-zA-Z0-9' '_'; }

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
