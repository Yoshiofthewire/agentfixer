# Opt-in smoke test against the REAL claude CLI. Skipped unless AF_SMOKE=1.
#
# The stub models the CLI's argv parsing on the one axis we depend on, but it
# is still a model, not the binary. Nothing else in this suite ever calls the
# real `claude`, so a wrong assumption about its argv or stdin handling (like
# the one that shipped: --disallowed-tools swallowing the prompt) can pass
# every stubbed test and still fail on first real use. This test is the only
# thing that would have caught that before a live run did.
#
# Costs real money - hence opt-in, not part of `bats tests/` or CI. Run with:
#   AF_SMOKE=1 bats tests/smoke.bats
#
# Uses the cheapest model and a budget cap well under $1.

setup() {
  load helpers
  # AF_TMP set before any skip: the shared teardown() from helpers.bash runs
  # unconditionally and treats an unset AF_TMP as failure, not a no-op.
  AF_TMP="$(mktemp -d)"
  if [ "${AF_SMOKE:-0}" != "1" ]; then
    skip "set AF_SMOKE=1 to run this against the real claude CLI (costs money)"
  fi
  command -v claude >/dev/null || skip "claude not on PATH"
}

teardown() {
  [ -n "${AF_TMP:-}" ] && rm -rf "$AF_TMP"
}

@test "SMOKE: af_run_agent gets structured_output back from the real claude CLI" {
  run bash -c "
    source '$AF_SCRIPT'
    AF_RUN_DIR='$AF_TMP'
    af_run_agent smoke claude-haiku-4-5-20251001 0.20 ro \
      '{\"type\":\"object\",\"required\":[\"ok\"],\"properties\":{\"ok\":{\"type\":\"boolean\"}}}' \
      '$AF_TMP/o.json' '$AF_TMP/o.log' \
      'Reply with structured_output {\"ok\": true}. Do nothing else, do not use any tools.'
  "
  [ "$status" -eq 0 ] || { cat "$AF_TMP/o.log" >&2; false; }
  [ "$(jq -r '.ok' "$AF_TMP/o.json")" = "true" ]
}
