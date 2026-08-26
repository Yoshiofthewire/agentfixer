setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  cat > "$ITER/confirmed.json" <<'J'
[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"sqli","blurb":"b","detail":"d","evidence":"e"}]
J
  cat > "$ITER/findings.json" <<'J'
{"findings":[
 {"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"sqli","blurb":"b","detail":"d","evidence":"e"},
 {"id":"F-01-2","severity":"LOW","file":"b.ts","line":2,"title":"nit","blurb":"b","detail":"d","evidence":"e"}]}
J
  cat > "$ITER/verified.json" <<'J'
{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"},{"id":"F-01-2","confirmed":false,"reason":"not exploitable"}]}
J
  cat > "$ITER/fixed.json" <<'J'
{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}
J
}

@test "body marks the PR as agent authored" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"Agent-authored"* ]]
  [[ "$output" == *"iteration 1/3"* ]]
}

@test "body lists fixed findings" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"**HIGH** \`a.ts:1\` — sqli"* ]]
}

# I4 - the $rejected jq has an empty-case fallback and the $fixed jq did not,
# so a results list with nothing "fixed" rendered a blank `### Fixed` section.
@test "body renders a placeholder when nothing was fixed" {
  cat > "$ITER/fixed.json" <<'J'
{"results":[{"id":"F-01-1","status":"skipped","files_changed":[],"note":"cannot repro"}]}
J
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### Fixed"$'\n'"_None."* ]]
}

@test "body lists findings rejected by verification" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"Rejected during verification"* ]]
  [[ "$output" == *"not exploitable"* ]]
}

@test "body includes a provenance table and the run log path" {
  run bash -c "$SRC AF_RUN_DIR='$AF_TMP/run'; af_pr_body '$ITER' 1 3"
  [[ "$output" == *"| step | model |"* ]]
  [[ "$output" == *"$AF_TMP/run"* ]]
  [[ "$output" == *"Generated with"* ]]
}

@test "labels are created idempotently and applied" {
  bash -c "$SRC AF_SLUG='test/alpha'; af_ensure_labels"
  grep -q 'label create agent-authored' "$AF_STUB_DIR/gh/calls.log"
  grep -q 'label create agentfixer' "$AF_STUB_DIR/gh/calls.log"
  # Per-call, not log-wide: no recorded call may be missing --repo.
  run grep -vq -- '--repo test/alpha' "$AF_STUB_DIR/gh/calls.log"
  [ "$status" -eq 1 ]
}

@test "label creation tolerates a label that already exists" {
  printf '1' > "$AF_STUB_DIR/gh/$(gh_key label create).exit"
  run bash -c "$SRC AF_SLUG='test/alpha'; af_ensure_labels"
  [ "$status" -eq 0 ]
}

@test "pushes the branch and opens a labelled PR" {
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  run bash -c "$SRC
    AF_SLUG='test/alpha'
    af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix
    af_step_pr '$ITER' 1 3 main
    echo NUM=\$AF_PR_NUM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NUM=7"* ]]
  grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--label agent-authored' "$AF_STUB_DIR/gh/calls.log"
  # Per-call, not log-wide: no recorded call (labels or pr create) may lack --repo.
  run grep -vq -- '--repo test/alpha' "$AF_STUB_DIR/gh/calls.log"
  [ "$status" -eq 1 ]
  git -C "$AF_TMP/remotes/alpha.git" rev-parse --verify "refs/heads/$(cd "$AF_TMP" && true; echo)" >/dev/null 2>&1 || true
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref --format='%(refname)' refs/heads/"
  [[ "$output" == *"agentfixer/"* ]]
}

# The only thing that could force-push is the real, unstubbed `git push`
# inside af_step_pr - gh's call log can never prove or disprove force. So
# prove it with real git semantics: push a diverging commit to the remote
# under the same branch name af_step_pr is about to use, then assert the
# real push is rejected (non-fast-forward) instead of silently overwritten.
# If af_step_pr ever grows a --force, this diverged push would succeed and
# the assertion below would fail.
@test "never force pushes: a diverged remote branch is rejected, not overwritten" {
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  run bash -c "$SRC
    AF_SLUG='test/alpha'
    af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix

    # Someone else already pushed a diverging commit under the exact branch
    # name af_step_pr is about to use. Use a second linked worktree on a
    # differently-named local branch to do it, since the branch name itself
    # is already checked out in \$AF_WORKTREE and git refuses to check out
    # the same branch twice.
    git -C '$REPO' worktree add -q '$AF_TMP/other' -b other-tmp origin/main
    echo other > '$AF_TMP/other/other.txt'
    git -C '$AF_TMP/other' add -A
    git -C '$AF_TMP/other' -c user.email=t@t -c user.name=t commit -qm other
    git -C '$AF_TMP/other' push -q origin \"other-tmp:refs/heads/\$AF_BRANCH\"
    echo BRANCH=\$AF_BRANCH

    af_step_pr '$ITER' 1 3 main"
  [ "$status" -ne 0 ]
  branch="$(grep -o 'BRANCH=agentfixer/[0-9-]*' <<<"$output" | cut -d= -f2)"
  [ -n "$branch" ]
  # The remote ref must still hold the diverging "other" commit unchanged -
  # proof nothing was overwritten, not just that af_step_pr exited nonzero.
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' log -1 --format=%s 'refs/heads/$branch'"
  [[ "$output" == "other" ]]
}

@test "a PR URL with no parseable number exits with the schema-failure code" {
  stub_gh "$(gh_key pr create)" ''
  run bash -c "$SRC
    AF_SLUG='test/alpha'
    af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix
    af_step_pr '$ITER' 1 3 main"
  [ "$status" -eq 4 ]
}
