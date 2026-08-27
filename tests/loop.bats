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

  # The review stage is part of the default pipeline, so these end-to-end
  # tests have to answer for it. It approves everything, and answers for
  # exactly the ids in ITS OWN prompt (the block of review.args after the
  # last argv line), so a test with two findings is handled too.
  # tests/review.bats is where the loop itself is exercised.
  read -r -d '' REVIEW_OK <<'S' || true
ids=$(awk '/^--print/{b=""} {b = b $0 "\n"} END{printf "%s", b}' \
      "$AF_STUB_DIR/claude/review.args" \
      | grep -oE 'F-[0-9]{2}-[0-9]+' | sort -u)
printf '%s\n' "$ids" \
  | jq -R -s '{reviews: (split("\n") | map(select(length > 0)
      | {id: ., approved: true, reason: "ok"}))}' \
  > "$AF_STUB_DIR/claude/review.json"
S
  stub_claude_side_effect review "$REVIEW_OK"
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

# I8 - spec 5.5 and 10 both specify agentfixer/<run>-iter<NN>, and 10 files it
# under Idempotency. One branch per run only works because GitHub deletes the
# ref on merge.
@test "each iteration gets its own branch" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  grep -qE -- '--head agentfixer/[0-9]{8}-[0-9]{6}-iter01 ' "$AF_STUB_DIR/gh/calls.log"
  grep -qE -- '--head agentfixer/[0-9]{8}-[0-9]{6}-iter02 ' "$AF_STUB_DIR/gh/calls.log"
}

# The failure this actually prevents: with branch deletion restricted (or
# --delete-branch a no-op), iteration 2's non-force push of the one run-scoped
# branch name is rejected as non-fast-forward and the run dies with its
# commits stranded. Overriding the merge side effect removes the simulated
# remote-branch deletion the other tests in this file rely on.
@test "a later iteration lands even when the merged branch is not deleted" {
  stub_gh_side_effect "$(gh_key pr merge)" ':'
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'pr create' "$AF_STUB_DIR/gh/calls.log")" -eq 2 ]
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref --format='%(refname:short)' 'refs/heads/agentfixer/*'"
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
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
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
  [ "$(grep -c 'Run the /security-audit skill' "$AF_STUB_DIR/claude/audit-sec.args")" -eq 2 ]
}

# E2 - an iteration that commits nothing used to `continue` without cleaning
# the worktree, and `checkout -B <branch> <sha>` preserves local modifications
# when the target commit is already HEAD and never touches untracked files. So
# iteration 1's scratch was still lying there when iteration 2 ran `git add -A`,
# and got committed, PR'd and auto-merged under a different finding's
# provenance - while the log said "iteration 1: nothing committed, no PR".
@test "an iteration that commits nothing leaves nothing for the next one" {
  stub_gh_side_effect "$(gh_key pr merge)" ':'
  stub_claude_side_effect fix '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/fix.args" | tail -1)
case "$p" in
  F-01-*) echo stray > stray.txt
          s=skipped ;;
  *)      echo patched > a.ts
          s=fixed ;;
esac
printf "{\"results\":[{\"id\":\"%s\",\"status\":\"%s\",\"files_changed\":[],\"note\":\"n\"}]}" "$p" "$s" > "$AF_STUB_DIR/claude/fix.json"
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'pr create' "$AF_STUB_DIR/gh/calls.log")" -eq 1 ]
  br="$(git -C "$AF_TMP/remotes/alpha.git" for-each-ref \
    --format='%(refname:short)' 'refs/heads/agentfixer/*')"
  [[ "$br" == *iter02 ]]
  run git -C "$AF_TMP/remotes/alpha.git" ls-tree -r --name-only "$br"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.ts"* ]]
  [[ "$output" != *"stray.txt"* ]]
}

# I4 - every finding coming back "skipped" leaves HEAD where it was. The run
# used to walk straight into af_step_pr and push a zero-commit branch, which
# `gh pr create` rejects; under set -e that ended the whole run with exit 1.
# Nothing should be pushed, no PR opened, and the next iteration should still
# get its turn - `continue`, not `break`.
@test "an iteration where every fix is skipped opens no PR and continues" {
  stub_claude_side_effect fix '
p=$(grep -oE "F-[0-9]{2}-[0-9]+" "$AF_STUB_DIR/claude/fix.args" | tail -1)
printf "{\"results\":[{\"id\":\"%s\",\"status\":\"skipped\",\"files_changed\":[],\"note\":\"cannot repro\"}]}" "$p" > "$AF_STUB_DIR/claude/fix.json"
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 2"
  [ "$status" -eq 0 ]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
  [ "$(grep -c 'Run the /security-audit skill' "$AF_STUB_DIR/claude/audit-sec.args")" -eq 2 ]
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  [[ "$output" != *"agentfixer/"* ]]
}

# I4 - the fix line used to print the *confirmed* count, so an iteration that
# confirmed 2 and fixed 1 displayed "2 fixed".
@test "the fix step reports the number fixed, not the number confirmed" {
  stub_claude_side_effect combine '
p=$(grep -oE "F-[0-9]{2}-" "$AF_STUB_DIR/claude/combine.args" | tail -1)
printf "{\"findings\":[{\"id\":\"%s1\",\"severity\":\"HIGH\",\"file\":\"a.ts\",\"line\":1,\"title\":\"t\",\"blurb\":\"b\",\"detail\":\"d\",\"evidence\":\"e\"},{\"id\":\"%s2\",\"severity\":\"LOW\",\"file\":\"b.ts\",\"line\":2,\"title\":\"u\",\"blurb\":\"b\",\"detail\":\"d\",\"evidence\":\"e\"}]}" "$p" "$p" > "$AF_STUB_DIR/claude/combine.json"
'
  stub_claude_side_effect verify '
p=$(grep -oE "F-[0-9]{2}-" "$AF_STUB_DIR/claude/verify.args" | tail -1)
printf "{\"verdicts\":[{\"id\":\"%s1\",\"confirmed\":true,\"reason\":\"real\"},{\"id\":\"%s2\",\"confirmed\":true,\"reason\":\"real\"}]}" "$p" "$p" > "$AF_STUB_DIR/claude/verify.json"
'
  stub_claude_side_effect fix '
p=$(grep -oE "F-[0-9]{2}-" "$AF_STUB_DIR/claude/fix.args" | tail -1)
printf "{\"results\":[{\"id\":\"%s1\",\"status\":\"fixed\",\"files_changed\":[\"a.ts\"]},{\"id\":\"%s2\",\"status\":\"skipped\",\"files_changed\":[],\"note\":\"n\"}]}" "$p" "$p" > "$AF_STUB_DIR/claude/fix.json"
echo patched > a.ts
'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 confirmed"* ]]
  [[ "$output" == *"1 fixed"* ]]
  [[ "$output" != *"2 fixed"* ]]
}

@test "dry-run stops after verify and never branches or pushes" {
  run bash -c "$SRC AF_DRY_RUN=1; af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_STUB_DIR/claude/fix.args" ]
  refute_grep 'pr create' "$AF_STUB_DIR/gh/calls.log"
  run bash -c "git -C '$AF_TMP/remotes/alpha.git' for-each-ref refs/heads/"
  [[ "$output" != *"agentfixer/"* ]]
}

@test "preflight failure exits 1 before any agent runs" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}

@test "CI exhaustion halts before the second iteration" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  stub_gh "$(gh_key run list)" '4242'
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

# C6: --repo/--iterations/--workspace/--base as the final argument, with no
# value following, used to hit `shift 2` with only one positional param left.
# `shift` returns nonzero when asked to shift more than $#, and under set -e
# that aborts the whole script right there - exit 1, but with no message at
# all, unlike every other error path in af_main which goes through af_die.
# C1 - unlike pr/merge/ci.bats, nothing here hand-sets AF_SLUG: af_run_repo must
# get it from af_preflight. Every gh call must name the repo it means - either
# `--repo test/alpha`, or an `api repos/test/alpha/...` path. `gh auth status`
# is the one call that legitimately names no repo. Inverted grep, so a single
# call missing the flag fails; a log-wide `grep -q` would not.
@test "every gh call in a full run names the target repo" {
  run bash -c "$SRC af_run_repo '$REPO' alpha 1"
  [ "$status" -eq 0 ]
  run grep -vE -- '(--repo test/alpha|^auth status$|^api repos/test/alpha/)' \
    "$AF_STUB_DIR/gh/calls.log"
  [ "$status" -eq 1 ]
}

@test "an option requiring a value as the final argument fails with a message" {
  local opt
  for opt in --repo --iterations --workspace --base; do
    run "$AF_SCRIPT" "$opt"
    [ "$status" -eq 1 ]
    [ -n "$output" ]
    [[ "$output" == *"requires a value"* ]]
  done
}
