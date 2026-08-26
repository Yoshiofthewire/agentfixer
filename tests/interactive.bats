setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1;"
  make_repo alpha >/dev/null
  make_repo beta >/dev/null
  unset TMUX
}

# `VAR=val $SRC ...` (the brief's literal form, prefixing the assignment
# before the `source` command) does not work: bash only keeps a
# command-prefix assignment alive past a special builtin like `source` in
# strict POSIX mode, which this shell isn't in, and a later bare (non-export)
# assignment wouldn't reach the `fzf` child process either way. Every other
# env-var-setting test in this suite puts the assignment as its own statement
# after $SRC; AF_STUB_FZF additionally needs `export` since a stub binary,
# not a sourced function, reads it. Verified: the literal brief form silently
# leaves AF_STUB_FZF unset in the fzf subprocess.
@test "picker returns the fzf selection" {
  run bash -c "$SRC export AF_STUB_FZF='alpha'; af_pick_repos '$AF_TMP/ws'"
  [ "$output" = "alpha" ]
}

@test "an empty selection exits 1" {
  run bash -c "$SRC export AF_STUB_FZF=''; af_pick_repos '$AF_TMP/ws'"
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
  run bash -c "$SRC export AF_STUB_FZF='alpha'
    af_run_repo() { echo FOREGROUND \"\$2\"; }
    af_interactive '$AF_TMP/ws' 1 1"
  [[ "$output" == *"FOREGROUND alpha"* ]]
  [ ! -f "$AF_STUB_DIR/tmux.log" ]
}

# The brief's literal version of this test strips $AF_TMP/bin from PATH and
# relies on the host having neither a real fzf nor a real tmux, so that the
# stub-less af_pick_repos still resolves *some* fzf and af_launch_tmux's
# `command -v tmux` genuinely fails. That is false on any box with fzf and
# tmux actually installed (this dev machine included: /usr/bin/fzf and
# /usr/bin/tmux both exist) - real fzf then errors for lack of a controlling
# tty before af_launch_tmux is ever reached, so the test fails for the wrong
# reason (exit 2, "inappropriate ioctl for device", no "tmux" in the output),
# and worse, on a box where only tmux is genuinely absent it would still find
# real fzf and could try to spin up other real host state. Build a minimal,
# host-independent PATH instead: our own fzf stub plus exactly the coreutils
# af_pick_repos/af_launch_tmux need, with no directory that could also
# contain a real tmux.
@test "tmux is required for a multi-repo run" {
  mkdir -p "$AF_TMP/bin2"
  cp "$AF_ROOT/tests/stubs/fzf" "$AF_TMP/bin2/fzf"
  chmod +x "$AF_TMP/bin2/fzf"
  local tool
  for tool in basename sort readlink grep bash cat; do
    ln -s "$(command -v "$tool")" "$AF_TMP/bin2/$tool"
  done
  run env AF_STUB_FZF="alpha
beta" PATH="$AF_TMP/bin2" AF_STUB_DIR="$AF_STUB_DIR" \
    bash -c "$SRC af_interactive '$AF_TMP/ws' 1 1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tmux"* ]]
  [ ! -f "$AF_STUB_DIR/tmux.log" ]
}

# Genuine end-to-end proof the confirmation gate is load-bearing: unlike the
# "declining ... exits 1" test above (which calls af_confirm directly and so
# can never reach af_run_repo/af_launch_tmux regardless of whether the gate
# works), this drives af_interactive with yes=0 and overrides both dispatch
# targets, so it fails if the gate is ever bypassed or the decline is
# swallowed.
@test "declining inside af_interactive dispatches to nothing" {
  run bash -c "$SRC export AF_STUB_FZF='alpha'
    af_run_repo() { echo SHOULD_NOT_RUN; }
    af_launch_tmux() { echo SHOULD_NOT_RUN; }
    echo n | af_interactive '$AF_TMP/ws' 1 0"
  [ "$status" -eq 1 ]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}
