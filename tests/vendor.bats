# The vendor seam: which CLI runs a step, how each one is handed a prompt and
# a schema, how each one's result is read back, and what happens when the
# reviewer's CLI is not there. Every trap asserted here is one of the three
# CLIs behaving differently from the other two, reproduced in tests/stubs.

setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_RUN_DIR='$AF_TMP';"
}

# ------------------------------------------------------- schema translation

# codex rejects an ordinary JSON Schema outright. Measured against codex-cli
# 0.149.1 with the real AF_SCHEMA_REVIEW: HTTP 400, "'required' is required
# to be supplied and to be an array including every key in properties.
# Missing 'objection'." Both rules have to be satisfied, not just the
# additionalProperties one.
@test "af_strict_schema adds additionalProperties false to every object" {
  run bash -c "$SRC af_strict_schema \"\$AF_SCHEMA_REVIEW\""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.additionalProperties' <<<"$output")" = "false" ]
  [ "$(jq -r '.properties.reviews.items.additionalProperties' <<<"$output")" = "false" ]
}

@test "af_strict_schema makes required name every property of every object" {
  run bash -c "$SRC af_strict_schema \"\$AF_SCHEMA_REVIEW\""
  [ "$status" -eq 0 ]
  [ "$(jq -c '.properties.reviews.items.required | sort' <<<"$output")" \
    = '["approved","id","objection","reason"]' ]
}

# Making an optional field mandatory would change the contract, so the widened
# `required` is paid for with a nullable type: the field must be present, and
# null is how the model says "not applicable". jq's `//` reads null and absent
# the same way, so af_review_objections needs no change.
@test "af_strict_schema keeps an optional property optional by allowing null" {
  run bash -c "$SRC af_strict_schema \"\$AF_SCHEMA_REVIEW\""
  [ "$(jq -c '.properties.reviews.items.properties.objection.type' <<<"$output")" \
    = '["string","null"]' ]
  # A property that was already required keeps its plain type.
  [ "$(jq -r '.properties.reviews.items.properties.reason.type' <<<"$output")" \
    = 'string' ]
}

# It translates whatever it is handed, so a schema change never needs a second
# hand-maintained copy for codex.
@test "af_strict_schema translates the other pipeline schemas too" {
  run bash -c "$SRC af_strict_schema \"\$AF_SCHEMA_FINDINGS\""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.properties.findings.items.additionalProperties' <<<"$output")" = "false" ]
  [ "$(jq -c '.properties.findings.items.properties.source.type' <<<"$output")" \
    = '["string","null"]' ]
}

# ------------------------------------------------------------------- codex

@test "af_run_agent codex extracts the last message, not a structured_output" {
  stub_codex probe '{"reviews":[{"id":"F-01-1","approved":true,"reason":"ok"}]}'
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro \"\$AF_SCHEMA_REVIEW\" '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  debug_output
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reviews[0].id' "$AF_TMP/o.json")" = "F-01-1" ]
  refute_grep . "$AF_STUB_DIR/claude/probe.args"
}

# The trap: `codex exec` blocks on stdin when it is given no prompt at all,
# and parses a bare prompt whose first word is `review` as a SUBCOMMAND. The
# positional `-` removes both, and is what makes the prompt arrive.
@test "the prompt reaches codex on stdin, via the '-' positional" {
  stub_codex probe '{"ok":true}'
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'review this distinctive-marker-42' codex"
  debug_output
  [ "$status" -eq 0 ]
  grep -q 'distinctive-marker-42' "$AF_STUB_DIR/codex/probe.args"
}

# The schema handed to codex is translated at call time, so this proves both
# that --output-schema got a FILE and that the file was in the strict dialect
# - the stub reproduces the real 400 for anything else.
@test "codex is handed a strict-dialect schema file, not the raw schema string" {
  stub_codex probe '{"reviews":[]}'
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro \"\$AF_SCHEMA_REVIEW\" '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  debug_output
  [ "$status" -eq 0 ]
  grep -q -- '--output-schema' "$AF_STUB_DIR/codex/probe.args"
  [ -f "$AF_TMP/o.log.schema.json" ]
  [ "$(jq -r '.properties.reviews.items.additionalProperties' "$AF_TMP/o.log.schema.json")" = "false" ]
}

@test "codex runs read-only and does not persist a session" {
  stub_codex probe '{"ok":true}'
  bash -c "$SRC af_run_agent probe gpt-5.5 3 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  grep -q -- '--sandbox read-only' "$AF_STUB_DIR/codex/probe.args"
  grep -q -- '--ephemeral' "$AF_STUB_DIR/codex/probe.args"
}

# The whole value of the split is that a different vendor read the diff. A
# fallback would give the appearance of independence without it, so failure
# is terminal and the message has to name the remedy rather than leave the
# operator guessing which of "missing", "logged out" and "broke" it was.
@test "G4: a codex failure fails the step and never falls back to claude" {
  stub_codex_fail probe 127 "codex: command not found"
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro \"\$AF_SCHEMA_REVIEW\" '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  [ "$status" -eq 4 ]
  [[ "$output" == *"codex login"* ]]
  [[ "$output" == *"NOT"* ]]
  refute_grep . "$AF_STUB_DIR/claude/probe.args"
  [ ! -s "$AF_TMP/o.json" ]
}

@test "G4: codex returning no JSON fails the step" {
  stub_codex probe 'I could not do that.'
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro \"\$AF_SCHEMA_REVIEW\" '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  [ "$status" -eq 4 ]
}

# A codex rate limit is the same class of event as a Claude one, and has to be
# classified the same way or the halt path will not rescue the committed work.
@test "a codex rate limit exits 6, not 4" {
  stub_codex_fail probe 1 "stream error: unexpected status 429 Too Many Requests"
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro \"\$AF_SCHEMA_REVIEW\" '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  [ "$status" -eq 6 ]
  [[ "$output" == *"429"* ]]
}

# codex echoes the whole prompt back on stderr, and this step's prompt is the
# repository's diff. Classifying a rate limit from raw stderr would make any
# diff that merely mentions "429" or "rate limit" halt a perfectly good run
# with exit 6. Measured against codex-cli 0.149.1, which prints the prompt
# under a "user" heading before the model's reply.
@test "a diff that mentions 429 does not turn a successful review into a halt" {
  stub_codex probe '{"reviews":[{"id":"F-01-1","approved":true,"reason":"ok"}]}'
  printf 'user\n- retry_after: 429 rate limit exceeded\n' \
    > "$AF_STUB_DIR/codex/probe.err"
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 ro \"\$AF_SCHEMA_REVIEW\" '$AF_TMP/o.json' '$AF_TMP/o.log' 'fix the 429 rate limit handler' codex"
  debug_output
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reviews[0].approved' "$AF_TMP/o.json")" = "true" ]
}

@test "codex refuses write mode rather than running unsandboxed" {
  stub_codex probe '{"ok":true}'
  run bash -c "$SRC af_run_agent probe gpt-5.5 3 rw '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' codex"
  [ "$status" -eq 1 ]
  [[ "$output" == *"read-only"* ]]
}

# --------------------------------------------------------------------- agy

@test "af_run_agent agy extracts .structured_output from its own envelope" {
  stub_agy probe '{"body":"## What happened\n\nmarker-77"}'
  run bash -c "$SRC af_run_agent probe m 0 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' agy"
  debug_output
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.body' "$AF_TMP/o.json")" == *"marker-77"* ]]
}

# The trap: --print takes an OPTIONAL value, so `--print --output-format json`
# makes "--output-format" the prompt. The prompt has to be attached with `=`.
@test "the prompt reaches agy attached to --print, not as a following word" {
  stub_agy probe '{"body":"x"}'
  bash -c "$SRC af_run_agent probe m 0 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'distinctive-marker-99' agy"
  grep -q -- '--print=distinctive-marker-99' "$AF_STUB_DIR/agy/probe.args"
  refute_grep -- '--print --output-format' "$AF_STUB_DIR/agy/probe.args"
}

@test "G4: agy reporting a non-SUCCESS status fails the step" {
  stub_agy probe '{"body":"x"}'
  printf 'FAILURE' > "$AF_STUB_DIR/agy/probe.status"
  run bash -c "$SRC af_run_agent probe m 0 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' agy"
  [ "$status" -eq 4 ]
}

@test "G4: agy returning no structured_output fails the step" {
  printf '%s' '{"status":"SUCCESS","structured_output":null}' \
    > "$AF_STUB_DIR/agy/probe.envelope"
  run bash -c "$SRC af_run_agent probe m 0 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' agy"
  [ "$status" -eq 4 ]
}

@test "G4: agy exiting non-zero fails the step" {
  stub_agy_fail probe 1 "agy: not authenticated"
  run bash -c "$SRC af_run_agent probe m 0 ro '{\"type\":\"object\"}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' agy"
  [ "$status" -eq 4 ]
}

# ------------------------------------------------------------- the seam itself

@test "the default CLI is still claude, so no existing call site changed" {
  stub_claude probe '{"ok":true}'
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi'"
  [ "$status" -eq 0 ]
  grep -q -- '--print' "$AF_STUB_DIR/claude/probe.args"
}

@test "an unknown CLI is a usage error, not a silent claude call" {
  run bash -c "$SRC af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' 'hi' gpt9"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gpt9"* ]]
  refute_grep . "$AF_STUB_DIR/claude/probe.args"
}
