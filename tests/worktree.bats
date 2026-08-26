setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
}

@test "creates a worktree on a new branch off the base" {
  run bash -c "$SRC af_setup_run '$REPO' alpha main; echo \"\$AF_WORKTREE\"; echo \"\$AF_BRANCH\""
  [ "$status" -eq 0 ]
  wt="$(echo "$output" | sed -n 1p)"
  br="$(echo "$output" | sed -n 2p)"
  [ -f "$wt/README.md" ]
  [[ "$br" == agentfixer/* ]]
}

@test "the user's working tree is untouched" {
  echo "dirty" > "$REPO/scratch.txt"
  bash -c "$SRC af_setup_run '$REPO' alpha main"
  [ -f "$REPO/scratch.txt" ]
  run git -C "$REPO" rev-parse --abbrev-ref HEAD
  [ "$output" = "main" ]
}

@test "iteration directories are created" {
  run bash -c "$SRC af_setup_run '$REPO' alpha main >/dev/null; af_iter_dir 2"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  [[ "$output" == *"/iter-02" ]]
}

@test "cleanup removes a merged clean worktree" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main
    af_cleanup_worktree '$REPO'
    [ -d \"\$AF_WORKTREE\" ] && echo STILL_THERE || echo GONE"
  [[ "$output" == *"GONE"* ]]
}

@test "cleanup leaves an unmerged worktree in place and says where" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main
    echo change > \"\$AF_WORKTREE/new.txt\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm work
    af_cleanup_worktree '$REPO'
    [ -d \"\$AF_WORKTREE\" ] && echo STILL_THERE || echo GONE"
  [[ "$output" == *"STILL_THERE"* ]]
  [[ "$output" == *"unmerged"* ]]
}

@test "cleanup leaves a dirty worktree in place" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main
    echo dirt > \"\$AF_WORKTREE/dirty.txt\"
    af_cleanup_worktree '$REPO'
    [ -d \"\$AF_WORKTREE\" ] && echo STILL_THERE || echo GONE"
  [[ "$output" == *"STILL_THERE"* ]]
}
