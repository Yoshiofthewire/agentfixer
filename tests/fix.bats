setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  cat > "$ITER/findings.json" <<'J'
{"findings":[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"sqli in where clause","detail":"d","evidence":"e"}]}
J
  cat > "$ITER/verified.json" <<'J'
{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"}]}
J
}

@test "G1 rejects a .github path" {
  run bash -c "$SRC af_gate_workflows '.github/workflows/ci.yml
src/a.ts'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 accepts ordinary paths" {
  run bash -c "$SRC af_gate_workflows 'src/a.ts
README.md'"
  [ "$status" -eq 0 ]
}

@test "G1 accepts an empty path list" {
  run bash -c "$SRC af_gate_workflows ''"
  [ "$status" -eq 0 ]
}

@test "fix runs with write access and produces fixed.json" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 0 ]
  grep -q 'bypassPermissions' "$AF_STUB_DIR/claude/fix.args"
}

@test "G2: fix dropping a finding exits 4" {
  stub_claude fix '{"results":[]}'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 4 ]
}

@test "G1 trips when the fix agent edits a workflow" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":[".github/workflows/ci.yml"]}]}'
  stub_claude_side_effect fix 'mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "makes exactly one commit with the trailer" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'
    af_commit_fixes '$ITER' 1
    git -C \"\$AF_WORKTREE\" log --format=%s%n%b \"\$AF_BASE_SHA\"..HEAD
    echo COUNT=\$(git -C \"\$AF_WORKTREE\" rev-list --count \"\$AF_BASE_SHA\"..HEAD)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=1"* ]]
  [[ "$output" == *"Co-Authored-By: Claude Opus 5 (1M context)"* ]]
  [[ "$output" == *"HIGH a.ts:1"* ]]
}
