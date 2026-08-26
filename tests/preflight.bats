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

@test "passes when the base branch is protected" {
  stub_gh "$(gh_key api repos/test/alpha/branches/main)" 'true'
  run bash -c "$SRC af_preflight '$REPO'"
  [ "$status" -eq 0 ]
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
