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

# C1 - an empty --repo is not an error to gh; it resolves the repository from
# the cwd's git remote instead. Reading check state for the wrong repository is
# how a green PR #N somewhere else could satisfy G3, so an unset slug must stop
# the run before gh is ever invoked.
@test "an unset slug is an internal error and reaches no gh call" {
  run bash -c "source '$AF_SCRIPT'; AF_SLUG=''; af_check_state 7"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AF_SLUG"* ]]
  [ ! -f "$AF_STUB_DIR/gh/calls.log" ]
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

# I7 - af_check_state masked every gh failure as [] -> "none", and af_ci_loop
# then told the user "PR #N has no required checks. Enable required status
# checks in branch protection", which is false when the real cause was a gh
# error. Still fails closed either way; it just has to say which.
#
# The two cases are distinguished by gh's own message. Measured against real
# gh 2.98.0, `gh pr checks <n> --required --json bucket,name`:
#   zero required checks -> rc=1, empty stdout,
#                           stderr "no required checks reported on the 'X' branch"
#   pending / failing     -> rc=0 with JSON (the documented exit 8 applies to
#                           the human-readable output, not --json)
@test "gh's genuine no-required-checks failure still reads as none" {
  stub_gh_fail "$(gh_key pr checks)" 1 "no required checks reported on the 'agentfixer/x' branch"
  run bash -c "$SRC af_check_state 7"
  [ "$output" = "none" ]
}

@test "any other gh failure reads as an error, not as zero required checks" {
  stub_gh_fail "$(gh_key pr checks)" 1 "HTTP 503: Service unavailable (api.github.com)"
  run bash -c "$SRC af_check_state 7"
  [[ "$output" == error* ]]
  [[ "$output" == *"503"* ]]
}

@test "the ci loop blames gh, not branch protection, when gh fails" {
  stub_gh_fail "$(gh_key pr checks)" 1 "HTTP 503: Service unavailable (api.github.com)"
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"503"* ]]
  [[ "$output" != *"no required checks"* ]]
  [ ! -f "$AF_STUB_DIR/claude/cifix.args" ]
  grep -q 'needs-human' "$AF_STUB_DIR/gh/calls.log"
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
  stub_gh "$(gh_key run list)" '4242'
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
  stub_gh "$(gh_key run list)" '4242'
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

# C2 - `gh run view` with no run id exits 1 non-interactively ("run or job ID
# required when not running interactively"), and even with a TTY would return
# the repository's most recent run rather than this branch's. Both the branch
# filter and the resolved id have to appear in the call log, and the log's
# content has to reach the agent's prompt.
@test "cifix resolves this branch's failing run and feeds its log to the agent" {
  stub_gh_seq "$(gh_key pr checks)" 1 '[{"bucket":"fail","name":"t"}]'
  stub_gh_seq "$(gh_key pr checks)" 2 '[{"bucket":"pass","name":"t"}]'
  stub_gh "$(gh_key run list)" '4242'
  stub_gh "$(gh_key run view)" 'FAIL: expected 1 got 2'
  stub_claude cifix '{"diagnosis":"d","files_changed":["a.ts"],"confident":true}'
  stub_claude_side_effect cifix 'echo fixed > a.ts'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    git -C \"\$AF_WORKTREE\" push -q --set-upstream origin \"\$AF_BRANCH\"
    af_ci_loop '$ITER' 7
    echo BRANCH=\$AF_BRANCH"
  [ "$status" -eq 0 ]
  branch="$(sed -n 's/^BRANCH=//p' <<<"$output")"
  grep -q -- "run list --repo test/alpha --branch $branch" "$AF_STUB_DIR/gh/calls.log"
  grep -q -- 'run view 4242 --repo test/alpha --log-failed' "$AF_STUB_DIR/gh/calls.log"
  grep -q 'FAIL: expected 1 got 2' "$AF_STUB_DIR/claude/cifix.args"
}

# The agent edits and pushes under bypassPermissions. With no log to work
# from it is guessing, so no log must halt the run rather than start it.
@test "cifix halts instead of prompting the agent with an empty log" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run list)" ''
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no workflow run found"* ]]
  [ ! -f "$AF_STUB_DIR/claude/cifix.args" ]
}

@test "cifix halts when the failing run's log cannot be read" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run list)" '4242'
  printf '1' > "$AF_STUB_DIR/gh/$(gh_key run view).exit"
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 2 ]
  [ ! -f "$AF_STUB_DIR/claude/cifix.args" ]
}

@test "cifix halts when the failing run reports no logs at all" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run list)" '4242'
  stub_gh "$(gh_key run view)" ''
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 2 ]
  [ ! -f "$AF_STUB_DIR/claude/cifix.args" ]
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
  stub_gh "$(gh_key run list)" '4242'
  stub_gh "$(gh_key run view)" 'FAIL'
  stub_claude cifix '{"diagnosis":"d","files_changed":[".github/workflows/ci.yml"],"confident":true}'
  stub_claude_side_effect cifix 'mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    git -C \"\$AF_WORKTREE\" push -q --set-upstream origin \"\$AF_BRANCH\"
    af_ci_loop '$ITER' 7"
  [ "$status" -eq 3 ]
}
