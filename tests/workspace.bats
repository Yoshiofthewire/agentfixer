setup() {
  load helpers
  setup_stub_env
}

@test "workspace is the parent of the script's own repo, through a symlink" {
  mkdir -p "$AF_TMP/ws/agentfixer"
  git -C "$AF_TMP/ws/agentfixer" init -q
  cp "$AF_SCRIPT" "$AF_TMP/ws/agentfixer/agentfixer.sh"
  ln -s "$AF_TMP/ws/agentfixer/agentfixer.sh" "$AF_TMP/ws/agentfixer.sh"
  run bash -c "source '$AF_TMP/ws/agentfixer.sh'; af_resolve_workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$AF_TMP/ws" ]
}

# A second install location: the symlink's own directory defines the
# workspace, even when that directory is not the repo's parent. Without this,
# a launcher symlink placed anywhere other than the repo's immediate parent
# silently resolves to the wrong workspace.
@test "workspace is the symlink's own directory, even when that isn't the repo's parent" {
  mkdir -p "$AF_TMP/elsewhere/agentfixer"
  git -C "$AF_TMP/elsewhere/agentfixer" init -q
  cp "$AF_SCRIPT" "$AF_TMP/elsewhere/agentfixer/agentfixer.sh"
  mkdir -p "$AF_TMP/ws"
  ln -s "$AF_TMP/elsewhere/agentfixer/agentfixer.sh" "$AF_TMP/ws/agentfixer.sh"
  run bash -c "source '$AF_TMP/ws/agentfixer.sh'; af_resolve_workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$AF_TMP/ws" ]
}

@test "lists sibling git repos and excludes non-repos" {
  make_repo alpha >/dev/null
  make_repo beta >/dev/null
  mkdir -p "$AF_TMP/ws/notarepo"
  run bash -c "source '$AF_SCRIPT'; af_list_repos '$AF_TMP/ws'"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha
beta" ]
}

# The exclusion used to be the hardcoded name "agentfixer", so the README's
# "it never lists itself as a target" was only true for one install layout,
# and any unrelated repo of that name was hidden from the picker.
@test "excludes its own repo, resolved from the script's real path" {
  make_repo alpha >/dev/null
  make_repo mytools >/dev/null
  cp "$AF_SCRIPT" "$AF_TMP/ws/mytools/agentfixer.sh"
  ln -s "$AF_TMP/ws/mytools/agentfixer.sh" "$AF_TMP/ws/agentfixer.sh"
  run bash -c "source '$AF_TMP/ws/agentfixer.sh'; af_list_repos '$AF_TMP/ws'"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha" ]
}

@test "a repo merely named agentfixer is still offered as a target" {
  make_repo alpha >/dev/null
  make_repo agentfixer >/dev/null
  make_repo mytools >/dev/null
  cp "$AF_SCRIPT" "$AF_TMP/ws/mytools/agentfixer.sh"
  run bash -c "source '$AF_TMP/ws/mytools/agentfixer.sh'; af_list_repos '$AF_TMP/ws'"
  [ "$output" = "agentfixer
alpha" ]
}
