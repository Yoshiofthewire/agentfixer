setup() {
  load helpers
  setup_stub_env
  SRC="source '$AF_SCRIPT';"
  REPO="$(make_repo alpha)"
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  ITER="$AF_TMP/iter-01"
  mkdir -p "$ITER"
  cat > "$ITER/findings.json" <<'J'
{"findings":[{"id":"F-01-1","severity":"HIGH","file":"a.ts","line":1,"title":"t1","blurb":"sqli in where clause","detail":"d","evidence":"e"}]}
J
  cat > "$ITER/verified.json" <<'J'
{"verdicts":[{"id":"F-01-1","confirmed":true,"reason":"real"}]}
J
  # E1 payload, run in the agent's cwd (the worktree): a gitdir the agent
  # controls at ./evil, a pre-commit hook that drops a marker, and the
  # pointer file that redirects host-side git into it. `git init x && mv
  # x/.git evil` rather than `git init --bare`: a bare gitdir is
  # core.bare=true and git refuses to commit through it, and leaving a
  # nested .git in place makes `git add -A` fail on that directory before
  # the gate is ever reached. Marker file, never a destructive payload.
  PLANT='git init -q -b x evilwt
mv evilwt/.git evil
rmdir evilwt
printf "#!/bin/sh\ntouch %s/PWNED\n" "$AF_TMP" > evil/hooks/pre-commit
chmod +x evil/hooks/pre-commit
printf "gitdir: %s/evil\n" "$PWD" > .git'
}

@test "G1 rejects a .github path" {
  run bash -c "$SRC af_gate_workflows '.github/workflows/ci.yml
src/a.ts'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 accepts ordinary paths" {
  run bash -c "$SRC af_gate_workflows 'src/a.ts
README.md'"
  [ "$status" -eq 0 ]
}

@test "G1 accepts an empty path list" {
  run bash -c "$SRC af_gate_workflows ''"
  [ "$status" -eq 0 ]
}

@test "fix runs with write access and produces fixed.json" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 0 ]
  grep -q 'bypassPermissions' "$AF_STUB_DIR/claude/fix.args"
}

@test "G2: fix dropping a finding exits 4" {
  stub_claude fix '{"results":[]}'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 4 ]
}

@test "G1 trips when the fix agent edits a workflow" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":[".github/workflows/ci.yml"]}]}'
  stub_claude_side_effect fix 'mkdir -p .github/workflows && echo evil > .github/workflows/ci.yml'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "makes exactly one commit with the trailer" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'echo patched > a.ts'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'
    af_commit_fixes '$ITER' 1
    git -C \"\$AF_WORKTREE\" log --format=%s%n%b \"\$AF_BASE_SHA\"..HEAD
    echo COUNT=\$(git -C \"\$AF_WORKTREE\" rev-list --count \"\$AF_BASE_SHA\"..HEAD)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=1"* ]]
  [[ "$output" == *"Co-Authored-By: Claude Opus 5 (1M context)"* ]]
  [[ "$output" == *"HIGH a.ts:1"* ]]
}

@test "G1 catches a .github path with a space in the name" {
  # An entirely-untracked .github/ directory collapses to a single "?? .github/"
  # line in porcelain output regardless of parser, which would match the
  # gate's prefix check for the wrong reason. Stage the file so git reports
  # the individual path - this is what actually exercises the awk/quoting bug.
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'mkdir -p ".github/workflows"
echo evil > ".github/workflows/ci config.yml"
git add -A'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 catches a rename into a spaced path under .github" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'mkdir -p ".github/workflows"
mv README.md ".github/workflows/renamed backdoor.yml"
git add -A'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 catches a .github path containing a newline" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'mkdir -p ".github/workflows"
f=$(printf "%b" ".github/workflows/evil\nbackdoor.yml")
echo evil > "$f"
git add -A'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

# I4 - every finding coming back "skipped" is schema-valid and passes G2, but
# leaves HEAD where it was. Reporting that as success sent af_run_repo on to
# af_step_pr, which pushed a zero-commit branch for `gh pr create` to reject -
# aborting the run under set -e with exit 1, the code the README documents as
# "nothing was spent", after a full audit+combine+verify+fix had been paid for.
# A distinct non-zero status is what lets the caller skip the PR instead.
@test "af_commit_fixes reports nothing-committed as a non-zero status" {
  cat > "$ITER/fixed.json" <<'J'
{"results":[{"id":"F-01-1","status":"skipped","files_changed":[],"note":"cannot repro"}]}
J
  bash -c "$SRC af_confirmed '$ITER' > '$ITER/confirmed.json'"
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    af_commit_fixes '$ITER' 1 || echo RC=\$?
    echo COUNT=\$(git -C \"\$AF_WORKTREE\" rev-list --count \"\$AF_BASE_SHA\"..HEAD)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" == *"COUNT=0"* ]]
}

# I6 - G1's input came from `$(af_changed_paths)`, whose exit status was
# discarded. A failing `git status --porcelain -z` produced an empty string,
# and an empty path list is indistinguishable from a clean tree: the most
# important gate in the tool failed OPEN. The producer must report the
# failure, and the gate must treat it as fatal.
@test "af_changed_paths fails instead of reporting a clean tree" {
  mkdir -p "$AF_TMP/notarepo"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/notarepo'; af_changed_paths"
  [ "$status" -ne 0 ]
}

# Breaking the gitdir, not the worktree path: host-side git no longer
# discovers the repository from $AF_WORKTREE (see E1), so a good gitdir
# pointed at a non-repo directory now reads as a perfectly legible "every
# file was deleted" rather than as a failure. An unreadable gitdir - removed,
# corrupt, permissions - is what a failing `git status` looks like now.
@test "G1 fails closed when the working tree cannot be read" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  mkdir -p "$AF_TMP/notarepo"
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    AF_WORKTREE_GITDIR='$AF_TMP/notarepo'
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 does not match a .githubfoo prefix" {
  run bash -c "$SRC af_gate_workflows '.githubfoo/x'"
  [ "$status" -eq 0 ]
}

@test "G1 catches a symlink named exactly .github" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'ln -s evil_target .github
git add -A'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

@test "G1 catches a gitlink at exactly .github" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix 'git update-index --add --cacheinfo 160000,0000000000000000000000000000000000000001,.github'
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
}

# E1 - $AF_WORKTREE/.git is a plain pointer file ("gitdir: <path>") sitting
# inside the sandbox's read-write bind, so a write-mode agent can repoint it
# at a gitdir it controls. Everything after the agent - the gate's own
# `git status`, then `git add`/`commit`/`push` - runs unsandboxed as the
# user, with $HOME, ~/.ssh and ~/.config/gh reachable. Three independent
# layers, one per test: pin the gitdir, disable hooks, detect the tamper.

# Layer 1. Repointing .git used to change what G1 sees: the attacker's
# gitdir is a fresh repo in which README.md reads as untracked and the real
# modifications are invisible.
@test "E1: host-side git ignores a repointed .git pointer file" {
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    cd \"\$AF_WORKTREE\"
    $PLANT
    af_changed_paths"
  [ "$status" -eq 0 ]
  [[ "$output" == *"evil/"* ]]
  [[ "$output" != *"README.md"* ]]
}

# Layer 2. The target repository's own hooks must never fire on the host.
# Hooks live in the common gitdir, which a linked worktree shares.
@test "E1: the host-side commit does not run the target repo's hooks" {
  cat > "$ITER/fixed.json" <<'J'
{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}
J
  bash -c "$SRC af_confirmed '$ITER' > '$ITER/confirmed.json'"
  printf '#!/bin/sh\ntouch %s/PWNED\n' "$AF_TMP" > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    echo patched > \"\$AF_WORKTREE/a.ts\"
    af_commit_fixes '$ITER' 1"
  [ "$status" -eq 0 ]
  [ ! -f "$AF_TMP/PWNED" ]
}

# Layer 3. A rewritten pointer file is a hostile agent, not a bug: name it
# and stop the run.
@test "E1: .git tampering is detected and exits 3" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix "echo patched > a.ts
$PLANT"
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"tampered"* ]]
}

# The whole escape, end to end: plant the gitdir and the hook, then let the
# run walk into the unsandboxed commit. The hook must not execute and the
# run must abort.
@test "E1: a planted gitdir cannot execute a hook on the host" {
  stub_claude fix '{"results":[{"id":"F-01-1","status":"fixed","files_changed":["a.ts"]}]}'
  stub_claude_side_effect fix "echo patched > a.ts
$PLANT"
  run bash -c "$SRC AF_SANDBOX=0
    af_setup_run '$REPO' alpha main >/dev/null
    af_step_fix '$ITER'
    af_commit_fixes '$ITER' 1"
  [ ! -f "$AF_TMP/PWNED" ]
  [ "$status" -ne 0 ]
}
