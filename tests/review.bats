setup() {
  load helpers
  setup_stub_env
  # AF_SANDBOX=0 for the same reason as loop.bats: real bwrap masks /tmp,
  # where the stub `claude` lives, hiding it from rw-mode steps (fix, refix).
  # AF_CACHE is pinned so the tests can read the run's own pr-body.md.
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1; AF_POLL=0; AF_SPIN_POLL=0; AF_SANDBOX=0; AF_CACHE='$AF_TMP/cache';"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  stub_gh "$(gh_key auth status)" ""
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/7'
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  stub_gh_side_effect "$(gh_key pr merge)" '
for b in $(git -C "$AF_TMP/remotes/alpha.git" for-each-ref --format="%(refname:short)" "refs/heads/agentfixer/*"); do
  git -C "$AF_TMP/remotes/alpha.git" branch -D "$b"
done
'
  F='{"findings":[{"id":"x","severity":"HIGH","file":"a.ts","line":1,"title":"t","blurb":"b","detail":"d","evidence":"e"}]}'
  stub_claude audit-sec "$F"
  stub_claude audit-hostile "$F"
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

  # One line of argv per `claude` call is appended to <step>.args, and every
  # call carries --print, so that is the call counter. The reviewer answers
  # for whichever finding id its own prompt embeds, exactly as the verify and
  # fix stubs do, so the id stays right across iterations.
  REVIEW_OK='
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/review.args" | tail -1)
printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":true,\"reason\":\"fixes the finding\"}]}" "$p" > "$AF_STUB_DIR/claude/review.json"
'
  REVIEW_NEVER='
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/review.args" | tail -1)
printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":false,\"reason\":\"no\",\"objection\":\"OBJECTION-MARKER the null check is still missing\"}]}" "$p" > "$AF_STUB_DIR/claude/review.json"
'
  # Objects on the FIRST call of the run only; approves from the second on.
  REVIEW_ONCE='
n=$(grep -c -- "--print" "$AF_STUB_DIR/claude/review.args")
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/review.args" | tail -1)
if [ "$n" -ge 2 ]; then
  printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":true,\"reason\":\"now correct\"}]}" "$p" > "$AF_STUB_DIR/claude/review.json"
else
  printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":false,\"reason\":\"no\",\"objection\":\"OBJECTION-MARKER the null check is missing\"}]}" "$p" > "$AF_STUB_DIR/claude/review.json"
fi
'
  REFIX_OK='
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/refix.args" | tail -1)
printf "{\"results\":[{\"id\":\"%s\",\"status\":\"fixed\",\"files_changed\":[\"a.ts\"]}]}" "$p" > "$AF_STUB_DIR/claude/refix.json"
echo repatched >> a.ts
'
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
}

agent_calls() {
  grep -c -- '--print' "$AF_STUB_DIR/claude/$1.args" 2>/dev/null || echo 0
}

pr_body() { cat "$AF_TMP"/cache/alpha/*/"$1"/pr-body.md; }

# --------------------------------------------------------------- fast path

@test "an approval on round 1 costs exactly one review call and no re-fix" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 0 ]
  [ "$(agent_calls review)" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/refix.args" ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
}

@test "the review step is read-only and never sandboxed into write mode" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  refute_grep 'bypassPermissions' "$AF_STUB_DIR/claude/review.args"
  grep -q -- 'Edit Write' "$AF_STUB_DIR/claude/review.args"
}

# The verdict has to be anchored to the finding it claims to address, so the
# prompt must carry both the finding record and the actual committed diff.
@test "the review prompt carries the commit diff and the confirmed findings" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  grep -q 'F-01-1' "$AF_STUB_DIR/claude/review.args"
  grep -q 'diff --git' "$AF_STUB_DIR/claude/review.args"
  grep -q '^+patched' "$AF_STUB_DIR/claude/review.args"
}

@test "a first-round approval is recorded in the PR body" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  run pr_body iter-01
  [[ "$output" == *"Fix review"* ]]
  [[ "$output" == *"first round"* ]]
}

# ------------------------------------------------------- object, then clear

@test "one objection sends the work back to the fix step and then proceeds" {
  stub_claude_side_effect review "$REVIEW_ONCE"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 0 ]
  [ "$(agent_calls review)" -eq 2 ]
  [ "$(agent_calls refix)" -eq 1 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
}

@test "the re-fix agent is given the reviewer's specific objection" {
  stub_claude_side_effect review "$REVIEW_ONCE"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  grep -q 'OBJECTION-MARKER the null check is missing' "$AF_STUB_DIR/claude/refix.args"
}

# Same reason this tool already lists the findings REJECTED during
# verification: which findings were hard is information a human reviewer of
# the PR wants, and it is lost the moment the objection is resolved.
@test "objections resolved in a later round still reach the PR body" {
  stub_claude_side_effect review "$REVIEW_ONCE"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  run pr_body iter-01
  [[ "$output" == *"OBJECTION-MARKER"* ]]
  [[ "$output" == *"round 2"* ]]
}

@test "the re-fix round's work is a second commit on the same branch" {
  # No branch deletion on merge, so the pushed ref survives for inspection.
  stub_gh_side_effect "$(gh_key pr merge)" ':'
  stub_claude_side_effect review "$REVIEW_ONCE"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 0 ]
  br="$(git -C "$AF_TMP/remotes/alpha.git" for-each-ref \
    --format='%(refname:short)' 'refs/heads/agentfixer/*')"
  [ -n "$br" ]
  run git -C "$AF_TMP/remotes/alpha.git" show "$br:a.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"patched"* ]]
  [[ "$output" == *"repatched"* ]]
  # One commit from the fix pass, one from the re-fix round.
  run git -C "$AF_TMP/remotes/alpha.git" log --format=%s "$br" -2
  [[ "$output" == *"address review objections (round 1)"* ]]
  [[ "$output" == *"verified findings from agentfixer iteration 1"* ]]
}

# G1 has to hold on the AMENDED work exactly as it does on the first pass -
# a re-fix agent can reach for .github/ just as readily as a fix agent.
@test "G1 trips when the re-fix agent edits a workflow" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  stub_claude_side_effect refix "$REFIX_OK"'
mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
}

@test "G2 holds on the re-fix agent's output" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  stub_claude_side_effect refix 'printf "{\"results\":[]}" > "$AF_STUB_DIR/claude/refix.json"'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"G2"* ]]
}

# ------------------------------------------------------------- cap reached

@test "objections at the cap open a PR, label it needs-human, and never merge" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC AF_REVIEW_ROUNDS=2; af_run_repo '$REPO' alpha 2"
  debug_output
  [ "$status" -eq 3 ]
  [ "$(agent_calls review)" -eq 2 ]
  [ "$(agent_calls refix)" -eq 1 ]
  grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--add-label needs-human' "$AF_STUB_DIR/gh/calls.log"
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
  # Halted, not merely un-merged: iteration 2 never gets to audit.
  [ "$(grep -c 'Run the /security-audit skill' "$AF_STUB_DIR/claude/audit-sec.args")" -eq 1 ]
}

@test "the branch is pushed when the cap is reached, so the PR has content" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC AF_REVIEW_ROUNDS=2; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 3 ]
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref --format='%(refname:short)' 'refs/heads/agentfixer/*'"
  [[ "$output" == *"agentfixer/"* ]]
}

@test "unresolved objections are written into the PR body under a clear heading" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC AF_REVIEW_ROUNDS=2; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 3 ]
  run pr_body iter-01
  [[ "$output" == *"Fix review"* ]]
  [[ "$output" == *"Not approved"* ]]
  [[ "$output" == *"OBJECTION-MARKER"* ]]
  [[ "$output" == *"needs a human"* ]]
}

# ---------------------------------------------------------------- G2 on review

@test "G2: a reviewer that drops a finding exits 4" {
  stub_claude review '{"reviews":[{"id":"F-01-1","approved":true,"reason":"r"}]}'
  cat > "$ITER/confirmed.json" <<'J'
[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"b","detail":"d","evidence":"e"},
 {"id":"F-01-2","severity":"LOW","file":"b.ts","line":2,"title":"t2","blurb":"b","detail":"d","evidence":"e"}]
J
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_review '$ITER' 1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"G2"* ]]
}

@test "G2: a reviewer that invents a finding id exits 4" {
  stub_claude review '{"reviews":[{"id":"F-01-1","approved":true,"reason":"r"},{"id":"F-01-9","approved":true,"reason":"r"}]}'
  cat > "$ITER/confirmed.json" <<'J'
[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"b","detail":"d","evidence":"e"}]
J
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_review '$ITER' 1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"G2"* ]]
}

# ------------------------------------------------------------ round limits

# 0 means "do not review", not "review once": any other reading makes 0 a
# synonym for 1, which is a lie the README would then have to tell.
@test "AF_REVIEW_ROUNDS=0 disables the stage entirely and still merges" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  run bash -c "$SRC AF_REVIEW_ROUNDS=0; af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/review.args" ]
  [ ! -f "$AF_STUB_DIR/claude/refix.args" ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
  run pr_body iter-01
  [[ "$output" == *"AF_REVIEW_ROUNDS=0"* ]]
}

@test "AF_REVIEW_ROUNDS=1 reviews once and never re-fixes" {
  stub_claude_side_effect review "$REVIEW_NEVER"
  stub_claude_side_effect refix "$REFIX_OK"
  run bash -c "$SRC AF_REVIEW_ROUNDS=1; af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 3 ]
  [ "$(agent_calls review)" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/refix.args" ]
  grep -q -- '--add-label needs-human' "$AF_STUB_DIR/gh/calls.log"
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "AF_REVIEW_ROUNDS=1 with an approval merges normally" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC AF_REVIEW_ROUNDS=1; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  [ "$(agent_calls review)" -eq 1 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
}

@test "a non-numeric AF_REVIEW_ROUNDS is rejected, not silently treated as 1" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC AF_REVIEW_ROUNDS=lots; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AF_REVIEW_ROUNDS"* ]]
}

# ------------------------------------------------------ iteration hygiene

# A review loop that ran hot must not leak into the next iteration - neither
# working-tree scratch nor the previous iteration's objection history.
@test "a hot review loop leaves nothing for the next iteration" {
  stub_gh_side_effect "$(gh_key pr merge)" ':'
  stub_claude_side_effect review "$REVIEW_ONCE"
  stub_claude_side_effect refix "$REFIX_OK"'
echo stray > stray-r1.txt
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  debug_output
  [ "$status" -eq 0 ]
  # Iteration 1: one objection, one re-fix. Iteration 2: clean first round.
  [ "$(agent_calls review)" -eq 3 ]
  [ "$(agent_calls refix)" -eq 1 ]
  # Iteration 2's PR body reports a first-round approval, with none of
  # iteration 1's objection history bleeding into it.
  run pr_body iter-02
  [[ "$output" == *"first round"* ]]
  [[ "$output" != *"OBJECTION-MARKER"* ]]
  # And none of iteration 1's working-tree scratch is in iteration 2's tree.
  run git -C "$AF_TMP/remotes/alpha.git" ls-tree -r --name-only \
    "$(git -C "$AF_TMP/remotes/alpha.git" for-each-ref \
       --format='%(refname:short)' 'refs/heads/agentfixer/*' | grep iter02)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.ts"* ]]
  [[ "$output" != *"stray-r1.txt"* ]]
}

# ------------------------------------------------------------ bookkeeping

@test "worst-case spend accounts for the review rounds and their re-fixes" {
  # per instance: 2*2 + 1 + 2 + 4 (fix) + 2*1 (cifix)
  #             + 2*3 (2 reviews) + 1*4 (1 re-fix) = 23
  run bash -c "$SRC AF_BUDGET_AUDIT=2 AF_BUDGET_COMBINE=1 AF_BUDGET_VERIFY=2 AF_BUDGET_FIX=4 AF_BUDGET_CIFIX=1 AF_CI_RETRIES=2 AF_BUDGET_REVIEW=3 AF_REVIEW_ROUNDS=2
    af_worst_case 1 1"
  [ "$output" = "23.00" ]
}

# The README states both of these figures outright, and its accuracy is a
# safety property here: the confirmation screen calls the number a cap, not
# an estimate.
@test "the README's worst-case figures are the ones af_worst_case computes" {
  run bash -c "$SRC af_worst_case 1 1"
  [ "$output" = "46.00" ]
  run bash -c "$SRC AF_REVIEW_ROUNDS=0; af_worst_case 1 1"
  [ "$output" = "25.00" ]
}

@test "worst-case spend drops back when the review stage is disabled" {
  run bash -c "$SRC AF_BUDGET_AUDIT=2 AF_BUDGET_COMBINE=1 AF_BUDGET_VERIFY=2 AF_BUDGET_FIX=4 AF_BUDGET_CIFIX=1 AF_CI_RETRIES=2 AF_REVIEW_ROUNDS=0
    af_worst_case 1 1"
  [ "$output" = "13.00" ]
}

@test "budget exhaustion in the review step names AF_BUDGET_REVIEW" {
  run bash -c "$SRC af_budget_var review"
  [ "$output" = "AF_BUDGET_REVIEW" ]
}

# The re-fix step reuses the fix step's cap, so its exhaustion message must
# name AF_BUDGET_FIX - the variable that actually raises it.
@test "budget exhaustion in the re-fix step names AF_BUDGET_FIX" {
  run bash -c "$SRC af_budget_var refix"
  [ "$output" = "AF_BUDGET_FIX" ]
}

@test "the review step appears in the live display's step list" {
  run bash -c "$SRC af_init_display; printf '%s\n' \"\${AF_STEPS[@]}\""
  [[ "$output" == *"review"* ]]
  # Between fix and pr, not appended to the end.
  [[ "$output" == *$'fix\nreview\npr'* ]]
}

@test "the PR provenance table names the review model" {
  stub_claude_side_effect review "$REVIEW_OK"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  run pr_body iter-01
  [[ "$output" == *"| review |"* ]]
}
