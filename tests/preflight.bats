setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  stub_gh "$(gh_key auth status)" ""
}

@test "extracts owner/repo from an https remote" {
  run bash -c "$SRC af_repo_slug '$REPO'"
  [ "$output" = "test/alpha" ]
}

@test "extracts owner/repo from an ssh remote" {
  git -C "$REPO" remote set-url origin "git@github.com:test/alpha.git"
  run bash -c "source '$AF_SCRIPT'; af_repo_slug '$REPO'"
  [ "$output" = "test/alpha" ]
}

# ${ref##*/} on refs/remotes/origin/release/2.0 yields "2.0", which is not a
# branch - the run would then die at "base branch origin/2.0 does not exist".
@test "a default branch name containing a slash survives" {
  git -C "$REPO" update-ref refs/remotes/origin/release/2.0 HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release/2.0
  run bash -c "$SRC af_base_branch '$REPO'"
  [ "$output" = "release/2.0" ]
}

@test "passes when the base branch is protected" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 0 ]
}

# C1 - af_preflight used to print the base branch on stdout, so af_run_repo
# consumed it as `base="$(af_preflight "$dir")"`: a subshell, in which the
# AF_SLUG assignment died. Every later `gh --repo "$AF_SLUG"` then ran with an
# empty --repo, which real gh resolves from the launch directory's git remote.
@test "preflight publishes the slug and base branch to the caller, not a subshell" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "$SRC af_preflight '$REPO'; echo SLUG=\$AF_SLUG BASE=\$AF_BASE_BRANCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SLUG=test/alpha"* ]]
  [[ "$output" == *"BASE=main"* ]]
}

@test "fails when the base branch is unprotected" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch protection"* ]]
  [[ "$output" == *"settings/branches"* ]]
}

@test "fails when there is no origin remote" {
  git -C "$REPO" remote remove origin
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin"* ]]
}

@test "fails when origin is not github" {
  git -C "$REPO" remote set-url origin "https://gitlab.com/test/alpha.git"
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
}

@test "preflight failure spends nothing" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'false'
  run bash -c "$SRC af_preflight '$REPO'"
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}

# The reviewer is a different vendor from the fixer, on purpose, and it runs
# several dollars into the pipeline - after audit, verify and fix have all
# been paid for. `command -v` here is not the capability check (af_vendor_codex
# trying and failing is, and it never substitutes a Claude reviewer); it just
# moves the commonest failure to before the spend instead of after it.
#
# A name that is not on PATH under any configuration, rather than deleting the
# stub: the real codex-cli is installed on the developer's machine and would
# otherwise be found behind it, making this test pass for free.
@test "preflight refuses to start when the fix reviewer's CLI is missing" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "AF_REVIEW_CLI=codex-not-installed; $SRC af_preflight '$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex-not-installed"* ]]
  [[ "$output" == *"AF_REVIEW_ROUNDS=0"* ]]
  # And it does not offer a Claude reviewer as the way out.
  refute_grep 'AF_REVIEW_CLI=claude' <<<"$output"
}

# ...but it must not demand a CLI the run will never call.
@test "preflight does not require the reviewer's CLI when the stage is off" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "AF_REVIEW_CLI=codex-not-installed; $SRC AF_REVIEW_ROUNDS=0
    af_preflight '$REPO'"
  [ "$status" -eq 0 ]
}

@test "preflight is satisfied by the codex stub at the real default" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 0 ]
}
