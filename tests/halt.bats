setup() {
  load helpers
  setup_stub_env
  # AF_SANDBOX=0 for the same reason as loop.bats: real bwrap masks /tmp,
  # where the stub `claude` lives, hiding it from rw-mode steps (fix, refix).
  # AF_CACHE is pinned so a test can read the body the run actually wrote.
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1; AF_POLL=0; AF_SPIN_POLL=0; AF_SANDBOX=0; AF_CACHE='$AF_TMP/cache';"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  stub_gh "$(gh_key auth status)" ""
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  stub_gh "$(gh_key pr create)" 'https://github.com/test/alpha/pull/9'
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
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
  stub_codex_side_effect review '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/codex/review.args" | tail -1)
printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":true,\"reason\":\"ok\"}]}" "$p" > "$AF_STUB_DIR/codex/review.json"
'

  # How the fix reviewer - `codex`, a different vendor from the fixer - fails
  # when the upstream refuses it: a non-zero exit with the refusal on stderr.
  # af_vendor_codex classifies on that text, and it is the same class of
  # event, and the same exit code, as the Claude session limit below.
  CODEX_429='stream error: unexpected status 429 Too Many Requests: you have hit your usage limit'

  # The envelope two live runs actually died on: a non-null api_error_status
  # with the upstream's own wording in .result. af_vendor_claude reads exactly
  # these two fields, so this is the whole of what a 429 looks like to it.
  SESSION_LIMIT='{"is_error":true,"subtype":"error","api_error_status":429,
   "result":"You'"'"'ve hit your session limit · resets 2:40am",
   "total_cost_usd":0.02,"permission_denials":[],"structured_output":null}'
}

# Reads the halt PR body the run wrote, wherever under AF_CACHE it landed.
halt_body() { cat "$AF_TMP"/cache/alpha/*/iter-*/halt-pr-body.md; }

# ------------------------------------------------- upstream, work committed

@test "an upstream failure after the fix commit opens a draft PR and keeps exit 6" {
  stub_codex_fail review 1 "$CODEX_429"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 6 ]
  grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  grep -qE 'pr create .*--draft' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--label needs-human' "$AF_STUB_DIR/gh/calls.log"
  # The label has to exist before it can be applied.
  grep -q 'label create needs-human' "$AF_STUB_DIR/gh/calls.log"
  # Really pushed - a draft PR over an unpushed branch would be empty.
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref --format='%(refname:short)' 'refs/heads/agentfixer/*'"
  [[ "$output" == *"agentfixer/"* ]]
}

# The body is the only place a human learns what happened, so it has to name
# the failure, the exit code, the upstream's own words, what landed, what did
# not, and that the draft is deliberate.
@test "the halt PR body states the API status, the exit code, and what was not done" {
  stub_codex_fail review 1 "$CODEX_429"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 6 ]
  run halt_body
  debug_output
  [ "$status" -eq 0 ]
  [[ "$output" == *"429"* ]]
  [[ "$output" == *"usage limit"* ]]
  [[ "$output" == *"exit 6"* ]]
  [[ "$output" == *"draft on purpose"* ]]
  [[ "$output" == *"Not reviewed"* ]]
  [[ "$output" == *"Never reached CI"* ]]
  # ...and the ordinary report is still there, under the banner rather than
  # standing alone as if it were provenance.
  [[ "$output" == *"### Fixed"* ]]
  [[ "$output" == *"[!WARNING]"* ]]
}

# ------------------------------------------------ upstream, nothing committed

@test "an upstream failure before anything is committed opens no PR" {
  stub_claude_raw verify "$SESSION_LIMIT"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 6 ]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  [[ "$output" != *"agentfixer/"* ]]
}

# --------------------------------------------------------------- budget cap

# AF_REVIEW_CLI=claude here on purpose: budget exhaustion is a
# --max-budget-usd event, and codex-cli has no such flag, so this halt cannot
# originate in the default reviewer. The rescue path under test is the same.
@test "an exhausted budget after the fix commit also opens a draft PR" {
  stub_claude_side_effect review '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/review.args" | tail -1)
printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":true,\"reason\":\"ok\"}]}" "$p" > "$AF_STUB_DIR/claude/review.json"
'
  stub_claude_raw review '{"is_error":true,"subtype":"error_max_budget_usd","api_error_status":null,"total_cost_usd":3.01,"permission_denials":[],"structured_output":null}'
  run bash -c "$SRC AF_REVIEW_CLI=claude; af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 5 ]
  grep -qE 'pr create .*--draft' "$AF_STUB_DIR/gh/calls.log"
  run halt_body
  [[ "$output" == *"exit 5"* ]]
  [[ "$output" == *"budget exhausted"* ]]
}

# ------------------------------------------------------ the rescue itself fails
#
# The session limit that killed the run may still be in force when the rescue
# tries to use it. Reporting the PR failure is right; letting it replace the
# reason the run actually died is not.
@test "a failed rescue PR is reported but does not mask the original exit code" {
  stub_codex_fail review 1 "$CODEX_429"
  stub_gh_fail "$(gh_key pr create)" 1 \
    "GraphQL: Draft pull requests are not supported in this repository."
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 6 ]
  [[ "$output" == *"usage limit"* ]]
  [[ "$output" == *"Draft pull requests are not supported"* ]]
  # And it says where the work still is, since it is not on GitHub.
  [[ "$output" == *"worktree"* ]]
}

@test "a rescue push that fails is reported, opens no PR, and keeps exit 6" {
  # The stub runs its side effect before its envelope is read, so this makes
  # the remote unreachable and the call fail on the same agent call: the
  # rescue then has committed work, a real push, and no remote to push to.
  stub_codex_side_effect review 'rm -rf "$AF_TMP/remotes/alpha.git"'
  stub_codex_fail review 1 "$CODEX_429"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 6 ]
  [[ "$output" == *"usage limit"* ]]
  [[ "$output" == *"could not push"* ]]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
}

# ------------------------------------------------------------------ G1
#
# G1 fires when an agent wrote under .github/, i.e. hostile or malfunctioning
# output. Publishing that content to a branch on the remote is the wrong
# response; halting with the work quarantined locally is the right one. This
# is the one halt path that must NOT gain a PR.
@test "a G1 tamper trip opens no PR and pushes nothing" {
  stub_claude_side_effect fix '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/fix.args" | tail -1)
printf "{\"results\":[{\"id\":\"%s\",\"status\":\"fixed\",\"files_changed\":[\"a.ts\"]}]}" "$p" > "$AF_STUB_DIR/claude/fix.json"
echo patched > a.ts
mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
  refute_grep 'pr ready' "$AF_STUB_DIR/gh/calls.log"
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  [[ "$output" != *"agentfixer/"* ]]
}

# The same exclusion, from the other direction: a G1 trip in a run that HAS
# committed work must still not publish it. The commit is real, the worktree
# is preserved, and nothing reaches the remote.
@test "a G1 trip with work already committed still opens no PR" {
  stub_claude_side_effect refix '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/refix.args" | tail -1)
printf "{\"results\":[{\"id\":\"%s\",\"status\":\"fixed\",\"files_changed\":[\"a.ts\"]}]}" "$p" > "$AF_STUB_DIR/claude/refix.json"
mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml
'
  stub_codex_side_effect review '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/codex/review.args" | tail -1)
printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":false,\"reason\":\"no\",\"objection\":\"still wrong\"}]}" "$p" > "$AF_STUB_DIR/codex/review.json"
'
  run bash -c "$SRC AF_REVIEW_ROUNDS=2; af_run_repo '$REPO' alpha 1"
  debug_output
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  [[ "$output" != *"agentfixer/"* ]]
}

# ------------------------------------------------------------ the happy path
#
# The rule has an inverse: the only non-draft PR agentfixer opens is the one
# continuing to CI and merge. If --draft ever leaked onto that call, every
# clean run would stop merging.
@test "a clean run's PR is not a draft and is never un-readied" {
  stub_gh_side_effect "$(gh_key pr merge)" '
for b in $(git -C "$AF_TMP/remotes/alpha.git" for-each-ref --format="%(refname:short)" "refs/heads/agentfixer/*"); do
  git -C "$AF_TMP/remotes/alpha.git" branch -D "$b"
done
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  grep -q 'pr create' "$AF_STUB_DIR/gh/calls.log"
  refute_grep -- '--draft' "$AF_STUB_DIR/gh/calls.log"
  refute_grep 'pr ready' "$AF_STUB_DIR/gh/calls.log"
  refute_grep -- '--add-label needs-human' "$AF_STUB_DIR/gh/calls.log"
}

# --------------------------------------------- the composed halt narrative
#
# A rate-limit halt is the one that says nothing about the code: the work is
# as good as it was a second earlier. The bash template can only list gates
# ("Not reviewed"), so a THIRD CLI writes the prose - the second cannot, it
# is the vendor that just ran out. Every fact in its prompt is read from this
# run's own JSON artifacts; the model composes sentences, it does not source
# facts, and the template's factual sections are still emitted below it.

@test "a rate-limit halt has its PR body composed by agy" {
  stub_codex_fail review 1 "$CODEX_429"
  stub_agy prbody '{"body":"### What happened\n\nCOMPOSED-MARKER-31"}'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 6 ]
  run halt_body
  debug_output
  [[ "$output" == *"COMPOSED-MARKER-31"* ]]
  [[ "$output" == *"Prose composed by"* ]]
  # The warning banner is agentfixer's and is never handed to a model.
  [[ "$output" == *"[!WARNING]"* ]]
  [[ "$output" == *"draft on purpose"* ]]
  # ...and the factual sections still come from the artifacts.
  [[ "$output" == *"### Fixed"* ]]
  [[ "$output" == *"429"* ]]
}

# The model is given facts and told it may not add any. If the prompt stopped
# carrying them it would be free to invent them, and a reader would act on it.
@test "the composer is handed the facts from the JSON artifacts, not asked for them" {
  stub_codex_fail review 1 "$CODEX_429"
  stub_agy prbody '{"body":"### What happened\n\nx"}'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 6 ]
  # The finding it fixed, by id, severity and location - from confirmed.json
  # crossed with fixed.json, not from anything the model chose.
  grep -qE 'F-[0-9]{2}-[0-9]+ \(HIGH, a\.ts:1\)' "$AF_STUB_DIR/agy/prbody.args"
  # The halt reason, verbatim from halt.txt.
  grep -q '429' "$AF_STUB_DIR/agy/prbody.args"
  # What the run never did, from af_halt_not_done.
  grep -q 'Never reached CI' "$AF_STUB_DIR/agy/prbody.args"
  # And it is told, in as many words, that it may not add to them.
  grep -qi 'Use ONLY the facts' "$AF_STUB_DIR/agy/prbody.args"
}

# A rate limit must still produce a PR. If the composer is missing or fails,
# the bash template is what remains - and the body says which of the two the
# reader is looking at, because "an agent wrote this" and "a shell script
# did" are not the same claim.
@test "a composer that fails falls back to the template and says so" {
  stub_codex_fail review 1 "$CODEX_429"
  stub_agy_fail prbody 1 "agy: not authenticated"
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 6 ]
  grep -qE 'pr create .*--draft' "$AF_STUB_DIR/gh/calls.log"
  run halt_body
  debug_output
  [[ "$output" == *"was asked to summarise this halt and could"* ]]
  [[ "$output" == *"agentfixer's own template"* ]]
  [[ "$output" == *"429"* ]]
  [[ "$output" == *"### Fixed"* ]]
}

@test "AF_PRBODY_CLI names the composer, and an unavailable one still opens the PR" {
  stub_codex_fail review 1 "$CODEX_429"
  run bash -c "AF_PRBODY_CLI=agy-not-installed; $SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 6 ]
  grep -qE 'pr create .*--draft' "$AF_STUB_DIR/gh/calls.log"
  run halt_body
  [[ "$output" == *"agy-not-installed"* ]]
  [[ "$output" == *"429"* ]]
}

# Not every halt is a rate limit, and the composer is not a general-purpose
# body writer. A budget cap is an operational number the template already
# states exactly; handing it to a model can only make it vaguer.
@test "a halt that is not a rate limit is not handed to the composer" {
  stub_claude_side_effect review '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/review.args" | tail -1)
printf "{\"reviews\":[{\"id\":\"%s\",\"approved\":true,\"reason\":\"ok\"}]}" "$p" > "$AF_STUB_DIR/claude/review.json"
'
  stub_claude_raw review '{"is_error":true,"subtype":"error_max_budget_usd","api_error_status":null,"total_cost_usd":3.01,"permission_denials":[],"structured_output":null}'
  stub_agy prbody '{"body":"### What happened\n\nCOMPOSED-MARKER-31"}'
  run bash -c "$SRC AF_REVIEW_CLI=claude; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 5 ]
  [ ! -f "$AF_STUB_DIR/agy/prbody.args" ]
  run halt_body
  [[ "$output" == *"budget exhausted"* ]]
  [[ "$output" != *"COMPOSED-MARKER-31"* ]]
}

# The composer runs while a Claude quota is exhausted. Asking a Claude model
# to write the explanation would fail for the same reason the run did.
@test "the composer is not pointed at a Claude model by default" {
  stub_codex_fail review 1 "$CODEX_429"
  stub_agy prbody '{"body":"### What happened\n\nx"}'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 6 ]
  grep -q -- '--model' "$AF_STUB_DIR/agy/prbody.args"
  refute_grep -i -- '--model *claude' "$AF_STUB_DIR/agy/prbody.args"
  refute_grep -i -- '--model *opus' "$AF_STUB_DIR/agy/prbody.args"
}
