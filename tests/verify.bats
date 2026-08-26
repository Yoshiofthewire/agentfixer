setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_RUN_DIR='$AF_TMP';"
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  export AF_WORKTREE="$AF_TMP/wt"
  mkdir -p "$AF_WORKTREE"
  cat > "$ITER/findings.json" <<'J'
{"findings":[
 {"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"b1","detail":"d","evidence":"e"},
 {"id":"F-01-2","severity":"LOW","file":"b.ts","line":2,"title":"t2","blurb":"b2","detail":"d","evidence":"e"}]}
J
}

@test "writes verified.json when every id is accounted for" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"},{"id":"F-01-2","confirmed":false,"reason":"false positive"}]}'
  run bash -c "$SRC af_step_verify '$ITER'"
  [ "$status" -eq 0 ]
  [ -f "$ITER/verified.json" ]
}

@test "G2: a dropped finding exits 4" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"}]}'
  run bash -c "$SRC af_step_verify '$ITER'"
  [ "$status" -eq 4 ]
  [[ "$output" == *"G2"* ]]
}

@test "G2: an invented finding id exits 4" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"r"},{"id":"F-01-2","confirmed":true,"reason":"r"},{"id":"F-01-9","confirmed":true,"reason":"r"}]}'
  run bash -c "$SRC af_step_verify '$ITER'"
  [ "$status" -eq 4 ]
}

@test "rejected findings are excluded from the confirmed set" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"},{"id":"F-01-2","confirmed":false,"reason":"nope"}]}'
  bash -c "$SRC af_step_verify '$ITER'"
  run bash -c "$SRC af_confirmed '$ITER'"
  [ "$(echo "$output" | jq -r 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "F-01-1" ]
}

@test "verify is read-only" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"r"},{"id":"F-01-2","confirmed":true,"reason":"r"}]}'
  bash -c "$SRC af_step_verify '$ITER'"
  ! grep -q 'bypassPermissions' "$AF_STUB_DIR/claude/verify.args"
}

@test "verify prompt instructs refute-by-default" {
  stub_claude verify '{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"r"},{"id":"F-01-2","confirmed":true,"reason":"r"}]}'
  bash -c "$SRC af_step_verify '$ITER'"
  grep -qi 'refute' "$AF_STUB_DIR/claude/verify.args"
}
