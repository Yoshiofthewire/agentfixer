setup() {
  load helpers
  setup_stub_env
}

@test "reports its version" {
  run "$AF_SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == agentfixer* ]]
}

@test "unknown flag exits 1" {
  run "$AF_SCRIPT" --nope
  [ "$status" -eq 1 ]
}

@test "can be sourced without executing" {
  run bash -c "source '$AF_SCRIPT'; echo SOURCED_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == "SOURCED_OK" ]]
}
