setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
}

@test "sandbox prefix binds the worktree read-write" {
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; af_sandbox_prefix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--bind"* ]]
  [[ "$output" == *"/tmp/wt"* ]]
}

@test "sandbox prefix masks HOME with a tmpfs" {
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; af_sandbox_prefix"
  [[ "$output" == *"--tmpfs"* ]]
  [[ "$output" == *"$HOME"* ]]
}

@test "sandbox prefix re-exposes .claude read-only, not read-write" {
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; af_sandbox_prefix"
  [[ "$output" == *"--ro-bind"* ]]
  [[ "$output" == *"$HOME/.claude"* ]]
  [[ "$output" != *"--bind"$'\n'"$HOME/.claude"* ]]
}

# BUG A - ~/.claude.json is a separate file at $HOME level, not inside
# ~/.claude/, so --tmpfs "$HOME" hides it too. Without a bind for it, `claude`
# starts with no configuration at all: verified against the real `claude`
# binary, `claude mcp list` inside this exact bwrap invocation (minus this
# bind) prints "Claude configuration file not found at: $HOME/.claude.json"
# and every write-mode step dies. Read-only for the same reason ~/.claude is
# read-only: it's user configuration a write-mode agent must not rewrite.
@test "sandbox prefix re-exposes .claude.json read-only when it exists" {
  echo '{}' > "$HOME/.claude.json"
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; af_sandbox_prefix"
  [[ "$output" == *"--ro-bind"* ]]
  [[ "$output" == *"$HOME/.claude.json"* ]]
  [[ "$output" != *"--bind"$'\n'"$HOME/.claude.json"* ]]
}

# A fresh machine may not have ~/.claude.json yet (first-ever `claude` run).
# Emitting a bind against a missing source makes bwrap fail outright - same
# reasoning as the AF_GITDIR bind below.
@test "sandbox prefix emits no .claude.json bind when the file does not exist" {
  rm -f "$HOME/.claude.json"
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; af_sandbox_prefix"
  [ "$status" -eq 0 ]
  refute_grep -Fx "$HOME/.claude.json" <<<"$output"
}

# C3 - `git worktree add` leaves $AF_WORKTREE/.git a pointer file to
# <repo>/.git/worktrees/<name>. In production that gitdir sits under $HOME,
# which the tmpfs masks, so every git command inside the sandbox died with
# "fatal: not a git repository: (null)" - the fix agent could not run a suite
# that shells out to git, and cifix (whose whole job is reproducing a CI
# failure) could not run one at all. Real bwrap, real git, no stubs.
@test "CONFINEMENT: git works inside the sandbox for the run's worktree" {
  require_bwrap
  local repo
  repo="$(make_repo alpha)"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$HOME/.claude"
  run bash -c "$SRC
    af_setup_run '$repo' alpha main >/dev/null
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" git -C \"\$AF_WORKTREE\" log --oneline -1
    \"\${pfx[@]}\" git -C \"\$AF_WORKTREE\" status --porcelain
    \"\${pfx[@]}\" git -C \"\$AF_WORKTREE\" diff --name-only"
  debug_output
  [ "$status" -eq 0 ]
  [[ "$output" == *"init"* ]]
}

# Read-only is sufficient for the agent to inspect history and run a suite.
# It does NOT cover $AF_WORKTREE/.git, which is in the read-write bind: see
# the E1 tests in fix.bats for what stops that pointer file being trusted.
@test "CONFINEMENT: the repository gitdir is exposed read-only" {
  require_bwrap
  local repo
  repo="$(make_repo alpha)"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$HOME/.claude"
  # Positive control before the negative assertion: prove the sandbox
  # actually started and mounted the gitdir by reading HEAD through it.
  # Without this, a bwrap that fails to launch at all would satisfy "the
  # write failed" trivially, and the test would pass for the wrong reason.
  run bash -c "$SRC
    af_setup_run '$repo' alpha main >/dev/null
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" cat '$repo/.git/HEAD' >/dev/null
    echo POSITIVE_CONTROL_OK
    \"\${pfx[@]}\" bash -c \"echo hack > '$repo/.git/hack'\""
  debug_output
  [ "$status" -ne 0 ]
  [[ "$output" == *"POSITIVE_CONTROL_OK"* ]]
  [ ! -f "$repo/.git/hack" ]
}

# BUG A, real bwrap confinement: ~/.claude.json is readable inside the
# sandbox (so `claude` finds its configuration) but not writable (same
# read-only guarantee as ~/.claude itself).
@test "CONFINEMENT: .claude.json is exposed read-only" {
  require_bwrap
  mkdir -p "$HOME/.claude"
  echo '{"marker":"CLAUDE_JSON_MARKER"}' > "$HOME/.claude.json"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mkdir -p \"\$AF_WORKTREE\"
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" cat '$HOME/.claude.json'
    echo POSITIVE_CONTROL_OK
    \"\${pfx[@]}\" bash -c \"echo hack > '$HOME/.claude.json'\""
  debug_output
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_JSON_MARKER"* ]]
  [[ "$output" == *"POSITIVE_CONTROL_OK"* ]]
  [ "$(cat "$HOME/.claude.json")" = '{"marker":"CLAUDE_JSON_MARKER"}' ]
}

# af_sandbox_prefix is also called directly (unit tests, and the ro path never
# sandboxes at all), where no run has been set up. An empty AF_GITDIR must
# produce no bind rather than a bind with an empty path.
@test "sandbox prefix emits no gitdir bind when no run has been set up" {
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; AF_GITDIR=''; af_sandbox_prefix"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^--ro-bind$' <<<"$output")" -eq 2 ]
  [[ "$output" != *$'\n\n'* ]]

  run bash -c "$SRC AF_WORKTREE=/tmp/wt; AF_GITDIR=/tmp/repo/.git; af_sandbox_prefix"
  [ "$(grep -c '^--ro-bind$' <<<"$output")" -eq 3 ]
  [ "$(grep -c '^/tmp/repo/.git$' <<<"$output")" -eq 2 ]
}

@test "sandbox prefix uses new-session to block TIOCSTI injection" {
  run bash -c "$SRC AF_WORKTREE=/tmp/wt; af_sandbox_prefix"
  [[ "$output" == *"--new-session"* ]]
}

# The stub records $* to $step.args, but env(1) consumes -u before claude ever
# sees it, so scrubbing isn't observable there. Instead the stub records which
# of the credential vars were still SET in its own environment to $step.cmd -
# this fails honestly if scrubbing is missing (leaked vars show up as SET) and
# passes honestly when it works (nothing recorded).
@test "write mode scrubs github and ssh credentials" {
  stub_claude probe '{}'
  GH_TOKEN=leaked GITHUB_TOKEN=leaked SSH_AUTH_SOCK=/tmp/agent.sock \
    AWS_ACCESS_KEY_ID=leaked \
    bash -c "$SRC AF_SANDBOX=0 AF_RUN_DIR='$AF_TMP'; af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi"
  [ ! -f "$AF_STUB_DIR/claude/probe.cmd" ] || ! grep -qE 'GH_TOKEN|SSH_AUTH_SOCK|AWS_ACCESS_KEY_ID' "$AF_STUB_DIR/claude/probe.cmd"
}

# bwrap exec's into its target, so the wrapped process's own argv never
# contains "bwrap" whether or not it was sandboxed - grepping for it is
# vacuously true either way. Assert an observable *effect* instead: a marker
# file outside $AF_WORKTREE, read from the stub's side-effect script (which
# runs with whatever environment the claude process itself would see). ro
# mode must still see it, because ro is never sandboxed.
@test "read-only mode is not sandboxed" {
  mkdir -p "$AF_TMP/wt"
  echo MARKER > "$HOME/marker.txt"
  stub_claude probe '{}'
  stub_claude_side_effect probe "cat '$HOME/marker.txt' > '$AF_STUB_DIR/claude/probe.read' 2>&1 || true"
  bash -c "$SRC AF_WORKTREE='$AF_TMP/wt' AF_RUN_DIR='$AF_TMP'; af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi"
  grep -q MARKER "$AF_STUB_DIR/claude/probe.read"
}

@test "write mode refuses to run unsandboxed when bwrap is missing" {
  stub_claude probe '{}'
  run bash -c "$SRC
    af_sandbox_available() { return 1; }
    AF_SANDBOX=1 AF_RUN_DIR='$AF_TMP'
    af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bubblewrap"* ]] || [[ "$output" == *"no-sandbox"* ]]
  [ ! -f "$AF_STUB_DIR/claude/probe.args" ]
}

@test "--no-sandbox warns loudly" {
  run bash -c "$SRC
    af_sandbox_available() { return 1; }
    AF_SANDBOX=0 AF_RUN_DIR='$AF_TMP'
    af_sandbox_warn 2>&1"
  [[ "$output" == *"WARNING"* ]] || [[ "$output" == *"unsandboxed"* ]]
}

@test "--no-sandbox flag is accepted by af_main and does not error" {
  run "$AF_SCRIPT" --no-sandbox --version
  [ "$status" -eq 0 ]
}

# AF_SANDBOX must not be disable-able by ambient environment - only by the
# explicit, logged --no-sandbox flag. af_main resets it just like it resets
# AF_RUN_DIR/AF_WORKTREE/AF_BRANCH/AF_BASE_SHA for the same reason.
@test "af_main resets AF_SANDBOX; ambient environment cannot disable it" {
  run bash -c "$SRC AF_SANDBOX=0; af_main --version; echo AF_SANDBOX=\$AF_SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AF_SANDBOX=1"* ]]
}

# --- real confinement, not just argv construction ---

@test "CONFINEMENT: secrets outside the worktree are unreadable" {
  require_bwrap
  mkdir -p "$HOME/.ssh"
  echo "SUPERSECRET" > "$HOME/.ssh/id_test"
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  echo POSITIVE_CONTROL_MARKER > "$HOME/.claude/marker"
  # Positive control before the negative assertion: prove the sandbox
  # actually started by reading a file that IS bound in (~/.claude, ro).
  # A bwrap that never launches would otherwise satisfy "the secret is
  # unreadable" trivially - this is exactly the defect a stub bwrap that
  # always exits 1 exposed: both negative confinement tests reported `ok`.
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" cat '$HOME/.claude/marker'
    \"\${pfx[@]}\" cat '$HOME/.ssh/id_test'"
  debug_output
  [ "$status" -ne 0 ]
  [[ "$output" == *"POSITIVE_CONTROL_MARKER"* ]]
  [[ "$output" != *"SUPERSECRET"* ]]
}

@test "CONFINEMENT: the worktree is writable inside the sandbox" {
  require_bwrap
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" bash -c 'echo ok > $AF_TMP/wt/f; cat $AF_TMP/wt/f'"
  debug_output
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "CONFINEMENT: the filesystem outside the worktree is read-only" {
  require_bwrap
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  echo POSITIVE_CONTROL_MARKER > "$AF_TMP/wt/marker"
  # Positive control before the negative assertion: prove the sandbox
  # actually started by reading a file through its read-write worktree bind,
  # so a bwrap that fails to launch cannot satisfy "the write failed" for
  # free.
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" cat '$AF_TMP/wt/marker'
    \"\${pfx[@]}\" bash -c 'echo bad > /etc/af_test_should_fail'"
  debug_output
  [ "$status" -ne 0 ]
  [[ "$output" == *"POSITIVE_CONTROL_MARKER"* ]]
}

@test "CONFINEMENT: network still works, because claude needs it" {
  require_bwrap
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" bash -c 'getent hosts api.anthropic.com >/dev/null'"
  debug_output
  [ "$status" -eq 0 ]
}

# Regression guard for the missing-~/.claude case (fresh CI runner). Runs with
# AF_SANDBOX=0 so it does not depend on a real bwrap invocation finding the
# stub `claude` on PATH (PATH's stub dir lives under /tmp, which bwrap masks;
# only AF_WORKTREE and $HOME/.claude are re-exposed inside the sandbox).
@test "write mode creates ~/.claude if missing so bwrap would not fail" {
  stub_claude probe '{}'
  rm -rf "$HOME/.claude"
  bash -c "$SRC AF_SANDBOX=0 AF_RUN_DIR='$AF_TMP'; af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi"
  [ -d "$HOME/.claude" ]
}

# End-to-end coverage of the path that actually ships: af_run_agent's rw
# branch, composed (sandbox prefix + credential scrub + claude), under real
# bwrap confinement - not af_sandbox_prefix wrapping a bare `cat`, and not
# af_run_agent with AF_SANDBOX=0. The PATH-stubbed claude and its bookkeeping
# dir live inside $AF_WORKTREE (bound read-write, so visible in the sandbox)
# rather than under $AF_STUB_DIR (which lives under /tmp and is masked).
@test "E2E: rw mode through af_run_agent reaches claude and extracts output under real bwrap" {
  require_bwrap
  mkdir -p "$HOME/.claude" "$AF_TMP/wt/bin" "$AF_TMP/wt/stub/claude"
  cp "$AF_ROOT/tests/stubs/claude" "$AF_TMP/wt/bin/claude"
  chmod +x "$AF_TMP/wt/bin/claude"
  AF_STUB_DIR="$AF_TMP/wt/stub" stub_claude probe '{"ok":true}'

  run env AF_STUB_DIR="$AF_TMP/wt/stub" PATH="$AF_TMP/wt/bin:$PATH" \
    bash -c "$SRC AF_WORKTREE='$AF_TMP/wt' AF_SANDBOX=1 AF_RUN_DIR='$AF_TMP'
      af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi"
  debug_output
  # af_run_agent's own error only names the log files; print their content
  # too, since that's where claude/bwrap's actual stderr landed.
  [ -f "$AF_TMP/o.log.stderr" ] && cat "$AF_TMP/o.log.stderr" >&2
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$AF_TMP/o.json")" = '{"ok":true}' ]
  grep -q -- 'bypassPermissions' "$AF_TMP/wt/stub/claude/probe.args"
}
