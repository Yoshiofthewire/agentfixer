setup() {
  load helpers
  setup_stub_env
  # AF_SANDBOX=0: the stub `claude` lives under $AF_TMP (/tmp), which real
  # bwrap sandboxing (the default) masks with a tmpfs, hiding the stub from
  # rw-mode steps (fix, cifix). See tests/ci.bats for the same workaround.
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1; AF_POLL=0; AF_SPIN_POLL=0; AF_SANDBOX=0;"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  stub_gh "$(gh_key auth status)" ""
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  # Real `gh pr merge --delete-branch` deletes the remote branch on GitHub,
  # so a second iteration's push of the same run-scoped branch name lands
  # cleanly. The fake gh never touches the real bare remote, so simulate
  # that one side effect directly for a multi-iteration run to be possible.
  stub_gh_side_effect "$(gh_key pr merge)" '
for b in $(git -C "$AF_TMP/remotes/alpha.git" for-each-ref --format="%(refname:short)" "refs/heads/agentfixer/*"); do
  git -C "$AF_TMP/remotes/alpha.git" branch -D "$b"
done
'
  F='{"findings":[{"id":"x","severity":"HIGH","file":"a.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'
  stub_claude audit-sec "$F"
  stub_claude audit-hostile "$F"

  # combine assigns a canonical id per iteration (F-<NN>-1), enforced by
  # af_step_combine's own id-canonicalization check. A static response can't
  # track that across iterations of a multi-iteration test, so combine,
  # verify and fix each derive the current call's id from their own
  # cumulative args log (which contains this call's prompt, embedding
  # either the target prefix or the real upstream id) and answer for it.
  stub_claude_side_effect combine '
p=$(grep -oE "F-[0-9]{2}-" "$AF_STUB_DIR/claude/combine.args" | tail -1)
printf "{\"findings\":[{\"id\":\"%s1\",\"severity\":\"HIGH\",\"file\":\"a.ts\",\"line\":1,\"title\":\"t\",\"blurb\":\"b\",\"detail\":\"d\",\"evidence\":\"e\",\"source\":\"both\"}]}" "$p" > "$AF_STUB_DIR/claude/combine.json"
'
  stub_claude_side_effect verify '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/verify.args" | tail -1)
printf "{\"verdicts\":[{\"id\":\"%s\",\"confirmed\":true,\"reason\":\"real\"}]}" "$p" > "$AF_STUB_DIR/claude/verify.json"
'
  stub_claude_side_effect fix '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/fix.args" | tail -1)
printf "{\"results\":[{\"id\":\"%s\",\"status\":\"fixed\",\"files_changed\":[\"a.ts\"]}]}" "$p" > "$AF_STUB_DIR/claude/fix.json"
echo patched > a.ts
'
}

@test "a full green iteration merges and exits 0" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
}

@test "requested iteration count is honoured" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Run the /security-audit skill' "$AF_STUB_DIR/claude/audit-sec.args")" -eq 2 ]
}

@test "an audit with no findings stops early and exits 0" {
  stub_claude audit-sec '{"findings":[]}'
  stub_claude audit-hostile '{"findings":[]}'
  stub_claude_side_effect combine ':'
  stub_claude combine '{"findings":[]}'
  run bash -c "$SRC af_run_repo '$REPO' alpha 3"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  [[ "$output" == *"clean"* ]]
}

@test "all findings rejected opens no PR but continues" {
  stub_claude_side_effect verify '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/verify.args" | tail -1)
printf "{\"verdicts\":[{\"id\":\"%s\",\"confirmed\":false,\"reason\":\"no\"}]}" "$p" > "$AF_STUB_DIR/claude/verify.json"
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  ! grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  [ "$(grep -c 'Run the /security-audit skill' "$AF_STUB_DIR/claude/audit-sec.args")" -eq 2 ]
}

@test "dry-run stops after verify and never branches or pushes" {
  run bash -c "$SRC AF_DRY_RUN=1; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  ! grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  ! [[ "$output" == *"agentfixer/"* ]]
}

@test "preflight failure exits 1 before any agent runs" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}

@test "CI exhaustion halts before the second iteration" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run view)" 'FAIL'
  stub_claude cifix '{"diagnosis":"d","files_changed":["a.ts"],"confident":false}'
  stub_claude_side_effect cifix 'echo more > a.ts'
  run bash -c "$SRC AF_CI_RETRIES=1; af_run_repo '$REPO' alpha 5"
  [ "$status" -eq 2 ]
  [ "$(grep -c 'Run the /security-audit skill' "$AF_STUB_DIR/claude/audit-sec.args")" -eq 1 ]
}

@test "reports total spend on completion" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [[ "$output" == *"spent"* ]]
}

@test "--iterations must be a positive integer" {
  run "$AF_SCRIPT" --repo alpha --iterations zero
  [ "$status" -eq 1 ]
}

@test "--repo naming a missing directory exits 1" {
  run "$AF_SCRIPT" --repo nosuchrepo --workspace "$AF_TMP/ws" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"nosuchrepo"* ]]
}
