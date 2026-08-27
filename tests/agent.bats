setup() {
  load helpers
  setup_stub_env
  # AF_RUN_DIR set here (not left to default to ".") so af_run_agent's
  # spend.txt lands in the disposable AF_TMP dir, not the repo working tree.
  SRC="source '$AF_SCRIPT'; AF_RUN_DIR='$AF_TMP';"
}

@test "extracts structured_output to the outfile" {
  stub_claude probe '{"findings":[]}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$AF_TMP/o.json")" = '{"findings":[]}' ]
}

# Regression: --disallowed-tools is variadic in the real CLI - it greedily
# consumes every following non-flag argument. A prompt appended to argv after
# it (the original bug: "claude ... --disallowed-tools '...' '$prompt'") is
# swallowed as another tool name, so claude sees no prompt at all and exits 1
# with "Input must be provided either through stdin or as a prompt argument".
# This must fail against a pre-fix af_run_agent that puts the prompt in argv.
@test "the prompt reaches the agent, not swallowed by variadic --disallowed-tools" {
  stub_claude probe '{"findings":[]}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'distinctive-prompt-marker-42'"
  [ "$status" -eq 0 ]
  grep -q 'distinctive-prompt-marker-42' "$AF_STUB_DIR/claude/probe.args"
}

@test "read-only mode disallows write tools" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--disallowed-tools' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- 'Edit Write' "$AF_STUB_DIR/claude/probe.args"
  refute_grep -- 'bypassPermissions' "$AF_STUB_DIR/claude/probe.args"
}

# AF_SANDBOX=0 here: these tests check argv construction, not sandboxing
# (that's tests/sandbox.bats). Without it, the default AF_SANDBOX=1 would
# route this through real bwrap, whose /tmp masking hides the PATH-stubbed
# claude binary these tests depend on.
@test "write mode uses bypassPermissions" {
  stub_claude probe '{}'
  bash -c "$SRC AF_SANDBOX=0; af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- 'bypassPermissions' "$AF_STUB_DIR/claude/probe.args"
}

@test "write mode still disallows WebFetch and WebSearch" {
  stub_claude probe '{}'
  bash -c "$SRC AF_SANDBOX=0; af_run_agent probe opus 1 rw '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--disallowed-tools' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- 'WebFetch WebSearch' "$AF_STUB_DIR/claude/probe.args"
}

@test "passes model and budget through" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe sonnet 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  grep -q -- '--model sonnet' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- '--max-budget-usd 3' "$AF_STUB_DIR/claude/probe.args"
}

# On Claude subscription billing, --max-budget-usd caps a notional dollar
# figure, not real spend, so it must be possible to drop the cap entirely
# rather than just raise it. Omitting the flag (not passing some huge number)
# is the honest form: a huge cap still aborts eventually.
@test "--no-budget / AF_NO_BUDGET=1 omits --max-budget-usd entirely" {
  stub_claude probe '{}'
  bash -c "$SRC AF_NO_BUDGET=1; af_run_agent probe sonnet 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  refute_grep -- '--max-budget-usd' "$AF_STUB_DIR/claude/probe.args"
  grep -q -- '--model sonnet' "$AF_STUB_DIR/claude/probe.args"
}

@test "AF_BUDGET=off is equivalent to --no-budget" {
  stub_claude probe '{}'
  # AF_BUDGET must be set BEFORE sourcing: agentfixer.sh reads it once, at
  # top level, to derive AF_NO_BUDGET - setting it after $SRC's `source`
  # would be too late.
  bash -c "AF_BUDGET=off; source '$AF_SCRIPT'; AF_RUN_DIR='$AF_TMP'
    af_run_agent probe sonnet 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  refute_grep -- '--max-budget-usd' "$AF_STUB_DIR/claude/probe.args"
}

@test "without --no-budget the cap is still passed (default unchanged)" {
  stub_claude probe '{}'
  bash -c "$SRC af_run_agent probe sonnet 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
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

# Budget exhaustion is not a schema failure: the real `claude` binary marks
# it with subtype "error_max_budget_usd" in the envelope (verified against
# claude 2.1.246 by actually exhausting a --max-budget-usd cap - see the
# fix report), and exits 1. That envelope shape, not the exit code and not
# stderr text, is what agentfixer must key off: stderr carries no message
# at all unless background subagents were actually running at the moment of
# the halt, so it is not a reliable discriminator.
@test "budget exhausted: names the step, the cap, the spend, and the env var to raise" {
  stub_claude_raw verify '{"is_error":true,"subtype":"error_max_budget_usd","total_cost_usd":3.033536,"structured_output":null}'
  printf '1' > "$AF_STUB_DIR/claude/verify.exit"
  run bash -c "$SRC af_run_agent verify opus 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 5 ]
  [[ "$output" == *"verify"* ]]
  [[ "$output" == *"3.03"* ]]
  [[ "$output" == *'$3'* ]]
  [[ "$output" == *"AF_BUDGET_VERIFY"* ]]
}

@test "budget exhausted: step names without a dedicated var derive AF_BUDGET_<STEP>" {
  stub_claude_raw probe '{"is_error":true,"subtype":"error_max_budget_usd","total_cost_usd":1.5,"structured_output":null}'
  printf '1' > "$AF_STUB_DIR/claude/probe.exit"
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 5 ]
  [[ "$output" == *"AF_BUDGET_PROBE"* ]]
}

@test "budget exhausted: audit-sec and audit-hostile both name AF_BUDGET_AUDIT" {
  stub_claude_raw audit-sec '{"is_error":true,"subtype":"error_max_budget_usd","total_cost_usd":3.01,"structured_output":null}'
  printf '1' > "$AF_STUB_DIR/claude/audit-sec.exit"
  run bash -c "$SRC af_run_agent audit-sec opus 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 5 ]
  [[ "$output" == *"AF_BUDGET_AUDIT"* ]]
}

@test "budget exhausted: a genuine schema failure still exits 4, not 5" {
  stub_claude_raw probe '{"is_error":true,"subtype":"error_during_execution","structured_output":null}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 4 ]
}

@test "accumulates spend" {
  stub_claude probe '{}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'; echo SPEND=\$(af_total_spend)"
  [[ "$output" == *"SPEND=0.01"* ]]
}

# An upstream API failure is not malformed output, for the same reason
# budget exhaustion is not: agentfixer's contract was never violated, the
# call simply could not complete. Both live runs that stopped short of the
# review cap died here - `claude` returned a 429 session limit - and were
# reported as "agent reported failure", exit 4, which sends whoever reads
# the cron log hunting a schema bug that does not exist.
#
# The envelope below is the shape the real CLI produced on those runs
# (claude 2.1.246, trimmed): is_error true, subtype "success" of all things,
# terminal_reason "api_error", the status in api_error_status and the cause
# in .result.
@test "an upstream API error exits 6, not 4" {
  stub_claude_raw review '{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your session limit · resets 2:40am (America/New_York)","total_cost_usd":4.56,"structured_output":null}'
  printf '1' > "$AF_STUB_DIR/claude/review.exit"
  run bash -c "$SRC af_run_agent review opus 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 6 ]
}

@test "an upstream API error names the status and the upstream's own reason" {
  stub_claude_raw review '{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your session limit · resets 2:40am (America/New_York)","total_cost_usd":4.56,"structured_output":null}'
  run bash -c "$SRC af_run_agent review opus 3 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [[ "$output" == *"429"* ]]
  [[ "$output" == *"session limit"* ]]
  [[ "$output" == *"review"* ]]
  refute_grep 'agent reported failure' <<<"$output"
}

# A 5xx is the same class of event and must not be reported differently.
@test "an upstream 500 is classified the same way as a rate limit" {
  stub_claude_raw probe '{"is_error":true,"subtype":"success","api_error_status":500,"result":"Internal server error","structured_output":null}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 6 ]
  [[ "$output" == *"500"* ]]
}

# The successful envelope carries api_error_status: null, and a null must
# not read as an error - every ordinary step would fail if it did.
@test "a successful call with a null api_error_status is not an upstream error" {
  stub_claude probe '{"ok":true}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 0 ]
}
