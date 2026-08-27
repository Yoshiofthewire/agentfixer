setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT'; AF_PLAIN=1;"
  make_repo alpha >/dev/null
  make_repo beta >/dev/null
  unset TMUX
}

# `VAR=val $SRC ...` (the brief's literal form, prefixing the assignment
# before the `source` command) does not work: bash only keeps a
# command-prefix assignment alive past a special builtin like `source` in
# strict POSIX mode, which this shell isn't in, and a later bare (non-export)
# assignment wouldn't reach the `fzf` child process either way. Every other
# env-var-setting test in this suite puts the assignment as its own statement
# after $SRC; AF_STUB_FZF additionally needs `export` since a stub binary,
# not a sourced function, reads it. Verified: the literal brief form silently
# leaves AF_STUB_FZF unset in the fzf subprocess.
@test "picker returns the fzf selection" {
  run bash -c "$SRC export AF_STUB_FZF='alpha'; af_pick_repos '$AF_TMP/ws'"
  [ "$output" = "alpha" ]
}

@test "an empty selection exits 1" {
  run bash -c "$SRC export AF_STUB_FZF=''; af_pick_repos '$AF_TMP/ws'"
  [ "$status" -eq 1 ]
}

# The picker is reached before af_preflight ever runs, so a missing fzf used
# to surface as bash's own "fzf: command not found" and a set -e exit 127,
# rather than this tool's own message and usage exit code. Same shape as
# af_launch_tmux's existing tmux check. Host-independent PATH, for the reason
# the "tmux is required" test below spells out.
@test "a missing fzf is reported by name" {
  mkdir -p "$AF_TMP/bin3"
  local tool
  for tool in basename sort readlink grep bash cat; do
    ln -s "$(command -v "$tool")" "$AF_TMP/bin3/$tool"
  done
  run env PATH="$AF_TMP/bin3" bash -c "$SRC af_pick_repos '$AF_TMP/ws'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fzf is required"* ]]
}

# The prompt accepted 0, which bypassed af_main's own `-ge 1` check on
# --iterations and produced a run that did nothing and exited 0.
@test "the interactive iterations prompt rejects 0" {
  run bash -c "$SRC
    af_stdin_is_tty() { return 0; }
    af_interactive() { echo DISPATCHED \"\$2\"; }
    echo 0 | af_main --workspace '$AF_TMP/ws'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least 1"* ]]
  [[ "$output" != *"DISPATCHED"* ]]
}

@test "the interactive iterations prompt accepts a count" {
  run bash -c "$SRC
    af_stdin_is_tty() { return 0; }
    af_interactive() { echo DISPATCHED \"\$2\"; }
    echo 3 | af_main --workspace '$AF_TMP/ws'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISPATCHED 3"* ]]
}

@test "confirmation states the repos, iterations and worst-case spend" {
  run bash -c "$SRC af_confirm 'alpha
beta' 3 </dev/null"
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" == *"3"* ]]
  [[ "$output" == *'$'* ]]
}

# Finding 2 (review): a bare "$" in the output cannot catch a dropped term, a
# wrong operator, or an off-by-one in the retry multiplier. Pin every budget
# knob and assert the exact computed figure. Two value sets, so the
# multiplication (n repos * i iterations) is genuinely exercised rather than
# checked against a single memorised constant that could pass by luck.
@test "worst-case spend is the exact budget-cap sum at the real defaults" {
  # 1 repo * 1 iteration * (2*3 + 1 + 3 + 6 + 3*3) = 1*1*25 = 25.00
  run bash -c "$SRC af_worst_case 1 1"
  [ "$output" = "25.00" ]
}

@test "worst-case spend scales exactly with repo count, iterations, and every budget knob" {
  # per instance: 2*2 + 1 + 2 + 4 + 2*1 = 13; total: 2 repos * 3 iters * 13 = 78.00
  run bash -c "$SRC AF_BUDGET_AUDIT=2 AF_BUDGET_COMBINE=1 AF_BUDGET_VERIFY=2 AF_BUDGET_FIX=4 AF_BUDGET_CIFIX=1 AF_CI_RETRIES=2
    af_worst_case 2 3"
  [ "$output" = "78.00" ]
}

@test "the confirmation screen shows the exact worst-case figure, not just a dollar sign" {
  run bash -c "$SRC AF_BUDGET_AUDIT=2 AF_BUDGET_COMBINE=1 AF_BUDGET_VERIFY=2 AF_BUDGET_FIX=4 AF_BUDGET_CIFIX=1 AF_CI_RETRIES=2
    af_confirm 'alpha
beta' 3 </dev/null"
  [[ "$output" == *'$78.00'* ]]
}

# --no-budget must not print a dollar worst-case as though it were an
# authorization - there's no cap to authorize against. It still warns that
# a large run consumes a lot, just not denominated in money.
@test "confirmation says uncapped, not a dollar figure, when budgets are off" {
  run bash -c "$SRC AF_NO_BUDGET=1
    af_confirm 'alpha' 1 </dev/null"
  [[ "$output" == *"uncapped"* ]]
  [[ "$output" != *'$'* ]]
}

@test "--no-budget is accepted by af_main and sets AF_NO_BUDGET" {
  run bash -c "$SRC af_main --no-budget --version; echo AF_NO_BUDGET=\$AF_NO_BUDGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AF_NO_BUDGET=1"* ]]
}

@test "af_subscription_type reports the subscription when no API key is in play" {
  stub_claude_raw unknown '{"subscriptionType":"max"}'
  run bash -c "$SRC af_subscription_type"
  [ "$output" = "max" ]
}

@test "af_subscription_type is empty when an API key is in play" {
  stub_claude_raw unknown '{"subscriptionType":"max","apiKeySource":"ANTHROPIC_API_KEY"}'
  run bash -c "$SRC af_subscription_type"
  [ "$output" = "" ]
}

# af_subscription_type is best-effort: when claude auth status reports a
# subscription (no apiKeySource), the confirmation screen should say the
# worst-case figure above is notional and point at --no-budget.
@test "confirmation notes a detected Claude subscription and points at --no-budget" {
  stub_claude_raw unknown '{"subscriptionType":"max"}'
  run bash -c "$SRC af_confirm 'alpha' 1 </dev/null"
  [[ "$output" == *"max"* ]]
  [[ "$output" == *"notional"* ]]
  [[ "$output" == *"--no-budget"* ]]
}

# An API key in play (even alongside a claude.ai session) means real API
# billing, so no subscription note should appear.
@test "confirmation has no subscription note when an API key is in play" {
  stub_claude_raw unknown '{"subscriptionType":"max","apiKeySource":"ANTHROPIC_API_KEY"}'
  run bash -c "$SRC af_confirm 'alpha' 1 </dev/null"
  [[ "$output" != *"notional"* ]]
}

@test "declining the confirmation exits 1 and runs nothing" {
  run bash -c "$SRC echo n | af_confirm 'alpha' 1"
  [ "$status" -eq 1 ]
  [ ! -f "$AF_STUB_DIR/claude/audit-sec.args" ]
}

@test "two repos create one tmux window each, named after the repo" {
  run bash -c "$SRC af_launch_tmux 2 alpha beta"
  [ "$status" -eq 0 ]
  grep -q 'new-session' "$AF_STUB_DIR/tmux.log"
  grep -q -- '-n alpha' "$AF_STUB_DIR/tmux.log"
  grep -q -- '-n beta' "$AF_STUB_DIR/tmux.log"
  grep -q -- '--iterations 2' "$AF_STUB_DIR/tmux.log"
  grep -q -- '--yes' "$AF_STUB_DIR/tmux.log"
}

# `TMUX=val $SRC ...` does not work, for the same reason the AF_STUB_FZF note
# above gives: a command-prefix assignment on `source` does not survive it.
# With the negated assertion below made effective (see refute_grep), this test
# failed - it had been taking the new-session branch all along, because TMUX
# was never actually set inside the shell that ran af_launch_tmux.
@test "inside tmux it adds windows instead of nesting a session" {
  run bash -c "$SRC export TMUX=/tmp/fake,1,0; af_launch_tmux 1 alpha beta"
  [ "$status" -eq 0 ]
  refute_grep 'new-session' "$AF_STUB_DIR/tmux.log"
  grep -q 'new-window' "$AF_STUB_DIR/tmux.log"
}

@test "a single repo runs in the foreground, not tmux" {
  run bash -c "$SRC export AF_STUB_FZF='alpha'
    af_run_repo() { echo FOREGROUND \"\$2\"; }
    af_interactive '$AF_TMP/ws' 1 1"
  [[ "$output" == *"FOREGROUND alpha"* ]]
  [ ! -f "$AF_STUB_DIR/tmux.log" ]
}

# The brief's literal version of this test strips $AF_TMP/bin from PATH and
# relies on the host having neither a real fzf nor a real tmux, so that the
# stub-less af_pick_repos still resolves *some* fzf and af_launch_tmux's
# `command -v tmux` genuinely fails. That is false on any box with fzf and
# tmux actually installed (this dev machine included: /usr/bin/fzf and
# /usr/bin/tmux both exist) - real fzf then errors for lack of a controlling
# tty before af_launch_tmux is ever reached, so the test fails for the wrong
# reason (exit 2, "inappropriate ioctl for device", no "tmux" in the output),
# and worse, on a box where only tmux is genuinely absent it would still find
# real fzf and could try to spin up other real host state. Build a minimal,
# host-independent PATH instead: our own fzf stub plus exactly the coreutils
# af_pick_repos/af_launch_tmux need, with no directory that could also
# contain a real tmux.
@test "tmux is required for a multi-repo run" {
  mkdir -p "$AF_TMP/bin2"
  cp "$AF_ROOT/tests/stubs/fzf" "$AF_TMP/bin2/fzf"
  chmod +x "$AF_TMP/bin2/fzf"
  local tool
  for tool in basename sort readlink grep bash cat; do
    ln -s "$(command -v "$tool")" "$AF_TMP/bin2/$tool"
  done
  run env AF_STUB_FZF="alpha
beta" PATH="$AF_TMP/bin2" AF_STUB_DIR="$AF_STUB_DIR" \
    bash -c "$SRC af_interactive '$AF_TMP/ws' 1 1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tmux"* ]]
  [ ! -f "$AF_STUB_DIR/tmux.log" ]
}

# Genuine end-to-end proof the confirmation gate is load-bearing: unlike the
# "declining ... exits 1" test above (which calls af_confirm directly and so
# can never reach af_run_repo/af_launch_tmux regardless of whether the gate
# works), this drives af_interactive with yes=0 and overrides both dispatch
# targets, so it fails if the gate is ever bypassed or the decline is
# swallowed.
@test "declining inside af_interactive dispatches to nothing" {
  run bash -c "$SRC export AF_STUB_FZF='alpha'
    af_run_repo() { echo SHOULD_NOT_RUN; }
    af_launch_tmux() { echo SHOULD_NOT_RUN; }
    echo n | af_interactive '$AF_TMP/ws' 1 0"
  [ "$status" -eq 1 ]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

# Finding 1 (review, Important - CONFIRMED EXPLOITABLE): af_launch_tmux used
# to build "$self --repo $repo --iterations $iters --yes" as one joined
# string and hand it to tmux as a single trailing argument. tmux runs a
# *single* trailing shell-command argument through `sh -c`; a repo name
# containing shell metacharacters was therefore a real injection sink. The
# stub tmux only logs argv - it can't tell a joined string from real argv
# (both log identically via "$*"), so proving this needs real tmux. Isolated
# to a private `-L` socket so nothing ever touches a real user tmux server;
# that socket's server is unconditionally killed below, whether the
# assertion passes or fails.
@test "SECURITY: a repo name with shell metacharacters cannot execute code via tmux" {
  command -v tmux >/dev/null || skip "tmux not installed"
  local real_tmux marker sock i
  real_tmux="$(type -a tmux | awk '{print $NF}' | grep -vF "$AF_TMP/bin/tmux" | head -1)"
  [ -n "$real_tmux" ] || skip "no real tmux found outside the test's own stub"
  marker="$AF_TMP/injection-marker"
  sock="af-poc-$$"
  mkdir -p "$AF_TMP/realtmux"
  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real_tmux" "$sock" \
    > "$AF_TMP/realtmux/tmux"
  chmod +x "$AF_TMP/realtmux/tmux"

  run timeout 10 env PATH="$AF_TMP/realtmux:$PATH" bash -c \
    "$SRC af_launch_tmux 1 'foo; touch $marker #'"

  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$marker" ] && break
    sleep 0.1
  done
  "$real_tmux" -L "$sock" kill-server >/dev/null 2>&1 || true

  [ ! -f "$marker" ]
}
