setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
}

@test "extracts structured_output to the outfile" {
  stub_claude probe '{"findings":[]}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$AF_TMP/o.json")" = '{"findings":[]}' ]
}

@test "read-only mode disallows write tools" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--disallowed-tools' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- 'Edit Write' "$AF_STUB_DIR/claude/probe.args"
  ! grep -q -- 'bypassPermissions' "$AF_STUB_DIR/claude/probe.args"
}

@test "write mode uses bypassPermissions" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- 'bypassPermissions' "$AF_STUB_DIR/claude/probe.args"
}

@test "write mode still disallows WebFetch and WebSearch" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--disallowed-tools' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- 'WebFetch WebSearch' "$AF_STUB_DIR/claude/probe.args"
}

@test "passes model and budget through" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe sonnet 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--model sonnet' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- '--max-budget-usd 3' "$AF_STUB_DIR/claude/probe.args"
}

@test "G4: is_error true exits 4" {
  stub_claude_raw probe '{"is_error":true,"subtype":"error_during_execution","structured_output":null}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "G4: non-JSON output exits 4" {
  stub_claude_raw probe 'this is not json'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "G4: missing structured_output exits 4" {
  stub_claude_raw probe '{"is_error":false,"subtype":"success","structured_output":null}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "G4: nonzero exit from claude exits 4" {
  stub_claude probe '{}'
  printf '7' > "$AF_STUB_DIR/claude/probe.exit"
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "accumulates spend" {
  stub_claude probe '{}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'; echo SPEND=\$AF_SPEND"
  [[ "$output" == *"SPEND=0.01"* ]]
}
