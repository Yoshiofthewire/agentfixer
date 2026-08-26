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
  grep -q -- '--repo test/alpha' "$AF_STUB_DIR/gh/calls.log"
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
  grep -q -- '--repo test/alpha' "$AF_STUB_DIR/gh/calls.log"
  git -C "$AF_TMP/remotes/alpha.git" rev-parse --verify "refs/heads/$(cd "$AF_TMP" && true; echo)" >/dev/null 2>&1 || true
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref --format='%(refname)' refs/heads/"
  [[ "$output" == *"agentfixer/"* ]]
}

@test "never force pushes" {
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  bash -c "$SRC
    AF_SLUG='test/alpha'
    af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix
    af_step_pr '$ITER' 1 3 main"
  ! grep -rq 'force' "$AF_STUB_DIR/gh/calls.log"
}
