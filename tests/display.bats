setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1; AF_RUN_DIR='$AF_TMP/run'; mkdir -p \"\$AF_RUN_DIR\";"
}

@test "spend survives a subshell" {
  stub_claude probe '{}'
  run bash -c "$SRC
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o.json' '$AF_TMP/o.log' hi ) &
    wait
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o2.json' '$AF_TMP/o2.log' hi ) &
    wait
    af_total_spend"
  [ "$status" -eq 0 ]
  [ "$output" = "0.02" ]
}

@test "spend accumulates correctly under real concurrency" {
  # Unlike "spend survives a subshell" above, nothing here waits between
  # launches: all five af_run_agent calls are genuinely in flight together,
  # appending to spend.txt with no serialization imposed by the test.
  stub_claude probe '{}'
  run bash -c "$SRC
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o1.json' '$AF_TMP/o1.log' hi ) &
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o2.json' '$AF_TMP/o2.log' hi ) &
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o3.json' '$AF_TMP/o3.log' hi ) &
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o4.json' '$AF_TMP/o4.log' hi ) &
    ( af_run_agent probe opus 1 ro '{}' '$AF_TMP/o5.json' '$AF_TMP/o5.log' hi ) &
    wait"
  [ "$status" -eq 0 ]
  # Five distinct lines: no interleaved/corrupted appends.
  [ "$(wc -l < "$AF_TMP/run/spend.txt")" -eq 5 ]
  run bash -c "$SRC af_total_spend"
  [ "$output" = "0.05" ]
}

# C5: the `:?` guard belongs only on the write path (af_run_agent). On the
# read path it was a landmine for af_render_tty, which calls af_total_spend
# to draw the "spent:" line and can run before af_setup_run has ever set
# AF_RUN_DIR (e.g. an interactive flow that renders a status before a repo
# is chosen). Prove the read path tolerates AF_RUN_DIR entirely unset.
@test "spend is tolerant of AF_RUN_DIR never having been set (read path)" {
  run bash -c "source '$AF_SCRIPT'; AF_PLAIN=1; af_total_spend"
  [ "$status" -eq 0 ]
  [ "$output" = "0.00" ]
}

@test "spend is zero before any agent runs" {
  run bash -c "$SRC af_total_spend"
  [ "$output" = "0.00" ]
}

@test "plain mode emits one timestamped line per status change" {
  run bash -c "$SRC af_status audit active 'starting'; af_status audit done '7 findings'"
  [[ "$output" == *"audit"* ]]
  [[ "$output" == *"7 findings"* ]]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "plain mode emits no ANSI escapes" {
  run bash -c "$SRC af_status audit active 'x'"
  [[ "$output" != *$'\e['* ]]
}

@test "blurb renders severity, location and text" {
  run bash -c "$SRC
    af_set_blurb '[{\"id\":\"F-01-1\",\"severity\":\"HIGH\",\"file\":\"src/db/query.ts\",\"line\":88,\"blurb\":\"sqli in where clause\"}]'
    af_status fix active '1 finding'"
  [[ "$output" == *"HIGH"* ]]
  [[ "$output" == *"src/db/query.ts:88"* ]]
  [[ "$output" == *"sqli in where clause"* ]]
}

@test "blurb lines are truncated to the terminal width" {
  long="$(printf 'x%.0s' $(seq 1 200))"
  run bash -c "$SRC COLUMNS=60
    af_set_blurb '[{\"id\":\"F-01-1\",\"severity\":\"LOW\",\"file\":\"a.ts\",\"line\":1,\"blurb\":\"$long\"}]'
    af_status fix active 'x'"
  while read -r line; do [ "${#line}" -le 60 ]; done <<< "$output"
}

# Regression: af_render_tty rewinds with \033[%dA using AF_LINES, counted as
# LOGICAL lines. A line longer than the terminal wraps into extra PHYSICAL
# rows the rewind never accounts for, so stale rows (e.g. old headers) are
# left on screen. If every rendered line is truncated to the terminal width,
# logical lines and physical rows are the same number by construction. This
# must fail against a pre-fix af_render_tty, whose header/separator/note
# lines are not width-bounded.
@test "render_tty: physical row count matches AF_LINES at a narrow width" {
  run bash -c "
    source '$AF_SCRIPT'
    COLUMNS=24
    AF_REPO_LABEL='a-very-long-repository-name-that-is-long'
    AF_ITER_LABEL='iteration 1/1 with a long label'
    AF_STATE[audit]=active
    AF_NOTE[audit]='this is a long status note that will definitely overflow twenty four columns'
    af_render_tty > '$AF_TMP/rendered.txt'
    printf 'LINES=%s\n' \"\$AF_LINES\"
  "
  [ "$status" -eq 0 ]
  local w=24 lines_reported physical=0 n rows
  lines_reported="$(printf '%s' "$output" | grep -o 'LINES=[0-9]*' | cut -d= -f2)"
  while IFS= read -r line || [ -n "$line" ]; do
    n="$(printf '%s' "$line" | wc -m)"
    rows=$(( (n + w - 1) / w ))
    [ "$rows" -eq 0 ] && rows=1
    physical=$((physical + rows))
  done < "$AF_TMP/rendered.txt"
  [ "$physical" -eq "$lines_reported" ]
}

# Same narrow width, but proves it directly: no rendered line is long enough
# to wrap at all.
@test "render_tty: no rendered line exceeds the terminal width" {
  run bash -c "
    source '$AF_SCRIPT'
    COLUMNS=24
    AF_REPO_LABEL='a-very-long-repository-name-that-is-long'
    AF_ITER_LABEL='iteration 1/1 with a long label'
    AF_STATE[audit]=active
    AF_NOTE[audit]='this is a long status note that will definitely overflow twenty four columns'
    af_render_tty
  "
  [ "$status" -eq 0 ]
  while IFS= read -r line || [ -n "$line" ]; do
    n="$(printf '%s' "$line" | wc -m)"
    [ "$n" -le 24 ]
  done <<< "$output"
}

@test "spinner waits for the command and propagates its exit code" {
  run bash -c "$SRC AF_SPIN_POLL=0; af_with_spinner fix bash -c 'exit 4'"
  [ "$status" -eq 4 ]
}

@test "spinner returns 0 for a successful command" {
  run bash -c "$SRC AF_SPIN_POLL=0; af_with_spinner fix true"
  [ "$status" -eq 0 ]
}

@test "plain mode is forced when stdout is not a tty" {
  run bash -c "source '$AF_SCRIPT'; af_init_display; echo PLAIN=\$AF_PLAIN"
  [[ "$output" == *"PLAIN=1"* ]]
}
