setup() {
  load helpers
  setup_stub_env
  # AF_SANDBOX=0: the stub `claude` lives under $AF_TMP (/tmp), which real
  # bwrap confinement masks; cifix is a write-mode (rw) step, same as fix.bats.
  SRC="source '$AF_SCRIPT'; AF_POLL=0; AF_CI_RETRIES=3; AF_SLUG='test/alpha'; AF_SANDBOX=0;"
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
  # Not wc -l: the recorded prompt and json-schema args are themselves
  # multi-line, so the file has far more than one line per invocation.
  # --print is emitted exactly once per af_run_agent call - a reliable
  # per-invocation marker.
  [ "$(grep -c -- '--print' "$AF_STUB_DIR/claude/cifix.args")" -eq 1 ]
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
  [ "$(grep -c -- '--print' "$AF_STUB_DIR/claude/cifix.args")" -eq 3 ]
  grep -q 'needs-human' "$AF_STUB_DIR/gh/calls.log"
  # Per-call, not log-wide: no recorded gh call (checks, run view, or the
  # needs-human label edit) may be missing --repo. A log-wide grep -q would
  # pass even if one call site forgot the flag; this inverted form does not.
  run grep -vq -- '--repo test/alpha' "$AF_STUB_DIR/gh/calls.log"
  [ "$status" -eq 1 ]
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
