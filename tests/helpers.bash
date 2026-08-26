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

# stub_gh_side_effect <key> <bash source>  -- runs before the stubbed call returns
stub_gh_side_effect() { printf '%s' "$2" > "$AF_STUB_DIR/gh/$1.sh"; }

# stub_gh_seq <key> <n> <body>  -- response for the Nth call
stub_gh_seq() { printf '%s' "$3" > "$AF_STUB_DIR/gh/$1.$2"; }

gh_calls() { cat "$AF_STUB_DIR/gh/calls.log" 2>/dev/null || true; }

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
