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

@test "lists sibling git repos and excludes non-repos" {
  make_repo alpha >/dev/null
  make_repo beta >/dev/null
  mkdir -p "$AF_TMP/ws/notarepo"
  run bash -c "source '$AF_SCRIPT'; af_list_repos '$AF_TMP/ws'"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha
beta" ]
}

@test "excludes the agentfixer repo itself" {
  make_repo alpha >/dev/null
  make_repo agentfixer >/dev/null
  run bash -c "source '$AF_SCRIPT'; af_list_repos '$AF_TMP/ws'"
  [ "$output" = "alpha" ]
}
