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
  ! [[ "$output" == *"--bind"$'\n'"$HOME/.claude"* ]]
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

@test "read-only mode is not sandboxed" {
  stub_claude probe '{}'
  bash -c "$SRC AF_RUN_DIR='$AF_TMP'; af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi"
  ! grep -q 'bwrap' "$AF_STUB_DIR/claude/probe.args"
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

# --- real confinement, not just argv construction ---

@test "CONFINEMENT: secrets outside the worktree are unreadable" {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  mkdir -p "$HOME/.ssh"
  echo "SUPERSECRET" > "$HOME/.ssh/id_test"
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" cat '$HOME/.ssh/id_test'"
  [ "$status" -ne 0 ]
  ! [[ "$output" == *"SUPERSECRET"* ]]
}

@test "CONFINEMENT: the worktree is writable inside the sandbox" {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" bash -c 'echo ok > $AF_TMP/wt/f; cat $AF_TMP/wt/f'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "CONFINEMENT: the filesystem outside the worktree is read-only" {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" bash -c 'echo bad > /etc/af_test_should_fail'"
  [ "$status" -ne 0 ]
}

@test "CONFINEMENT: network still works, because claude needs it" {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  mkdir -p "$HOME/.claude" "$AF_TMP/wt"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/wt'
    mapfile -t pfx < <(af_sandbox_prefix)
    \"\${pfx[@]}\" bash -c 'getent hosts api.anthropic.com >/dev/null'"
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
