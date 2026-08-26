setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_RUN_DIR='$AF_TMP';"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  export AF_WORKTREE="$AF_TMP/wt"
  mkdir -p "$AF_WORKTREE"
}

FIND='{"findings":[{"id":"a1","severity":"HIGH","file":"x.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'

@test "runs both auditors and writes both files" {
  stub_claude audit-sec "$FIND"
  stub_claude audit-hostile "$FIND"
  run bash -c "$SRC af_step_audit '$ITER'"
  [ "$status" -eq 0 ]
  [ -f "$ITER/audit-sec.json" ]
  [ -f "$ITER/audit-hostile.json" ]
}

@test "auditors are read-only" {
  stub_claude audit-sec "$FIND"
  stub_claude audit-hostile "$FIND"
  bash -c "$SRC af_step_audit '$ITER'"
  grep -q 'Edit Write' "$AF_STUB_DIR/claude/audit-sec.args"
  refute_grep 'bypassPermissions' "$AF_STUB_DIR/claude/audit-sec.args"
}

@test "auditors invoke their skills" {
  stub_claude audit-sec "$FIND"
  stub_claude audit-hostile "$FIND"
  bash -c "$SRC af_step_audit '$ITER'"
  grep -q 'security-audit' "$AF_STUB_DIR/claude/audit-sec.args"
  grep -q 'hostile-review' "$AF_STUB_DIR/claude/audit-hostile.args"
}

@test "a failing auditor propagates exit 4" {
  stub_claude audit-sec "$FIND"
  stub_claude_raw audit-hostile 'not json'
  run bash -c "$SRC af_step_audit '$ITER'"
  [ "$status" -eq 4 ]
}

@test "combine assigns canonical F-<iter>-<n> ids" {
  printf '%s' "$FIND" > "$ITER/audit-sec.json"
  printf '%s' "$FIND" > "$ITER/audit-hostile.json"
  stub_claude combine '{"findings":[{"id":"F-01-1","severity":"HIGH","file":"x.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e","source":"both"}]}'
  run bash -c "$SRC af_step_combine '$ITER' 1"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].id' "$ITER/findings.json")" = "F-01-1" ]
}

@test "combine rejects ids that do not match the canonical form" {
  printf '%s' "$FIND" > "$ITER/audit-sec.json"
  printf '%s' "$FIND" > "$ITER/audit-hostile.json"
  stub_claude combine '{"findings":[{"id":"whatever","severity":"HIGH","file":"x.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'
  run bash -c "$SRC af_step_combine '$ITER' 1"
  [ "$status" -eq 4 ]
}

# Without the guard, cat's failure on the missing file is swallowed inside
# the nested command substitution that builds the prompt, and combine would
# silently call the agent with an empty audit section instead of failing.
@test "combine dies loudly when audit output is missing, without calling the agent" {
  stub_claude combine "$FIND"
  run bash -c "$SRC af_step_combine '$ITER' 1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"audit-sec.json"* ]]
  [ ! -f "$AF_STUB_DIR/claude/combine.args" ]
}
