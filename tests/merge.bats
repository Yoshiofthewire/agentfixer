setup() {
  load helpers
  setup_stub_env
  # AF_SLUG is normally set by af_preflight; these tests call af_setup_run
  # directly (as ci.bats/pr.bats do), so it must be set explicitly for A1
  # (--repo on every gh call) to be exercised for real.
  SRC="source '$AF_SCRIPT'; AF_POLL=0; AF_SLUG='test/alpha';"
  REPO="$(make_repo alpha)"
  add_bare_remote alpha "$REPO"
  PREP="af_setup_run '$REPO' alpha main >/dev/null
    echo x > \"\$AF_WORKTREE/a.ts\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix"
}

@test "merges when required checks exist and pass" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--squash' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- '--match-head-commit' "$AF_STUB_DIR/gh/calls.log"
}

@test "G3: refuses to merge when there are no required checks" {
  stub_gh "$(gh_key pr checks)" '[]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "G3: refuses to merge on a failing check" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"fail","name":"t"}]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

# I7 - a gh failure is not evidence that the checks passed, and it is not
# evidence that there are none either. Refuse the merge and say what happened.
@test "G3: refuses to merge when the check state cannot be read" {
  stub_gh_fail "$(gh_key pr checks)" 1 "HTTP 503: Service unavailable (api.github.com)"
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"503"* ]]
  [[ "$output" != *"has no required checks"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "G1 re-runs against the commit range before merging" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    mkdir -p \"\$AF_WORKTREE/.github/workflows\"
    echo evil > \"\$AF_WORKTREE/.github/workflows/ci.yml\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "passes the current head sha to --match-head-commit" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP
    sha=\$(git -C \"\$AF_WORKTREE\" rev-parse HEAD)
    af_step_merge 7
    echo SHA=\$sha"
  sha="$(echo "$output" | sed -n 's/^SHA=//p')"
  grep -q -- "--match-head-commit $sha" "$AF_STUB_DIR/gh/calls.log"
}

@test "a refused merge exits 3" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  printf '1' > "$AF_STUB_DIR/gh/$(gh_key pr merge).exit"
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 3 ]
}

# A2 - per-call, not log-wide: no recorded gh call (pr checks or pr merge) may
# be missing --repo. A log-wide grep -q would pass even if one call site
# forgot the flag; this inverted form does not.
@test "every gh call carries --repo" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 0 ]
  run grep -vq -- '--repo test/alpha' "$AF_STUB_DIR/gh/calls.log"
  [ "$status" -eq 1 ]
}

# I6 - the pre-merge G1 took its input from `$(af_range_paths ...)`, whose
# exit status was discarded. A failing `git diff --name-status -z` (here: a
# base sha that is not in the object store) yielded an empty path list, which
# reads exactly like "this range touches no workflow" - so the gate passed and
# the merge went ahead. Failing closed is the only acceptable direction.
@test "af_range_paths fails instead of reporting an empty range" {
  mkdir -p "$AF_TMP/notarepo"
  run bash -c "$SRC AF_WORKTREE='$AF_TMP/notarepo'; af_range_paths HEAD~1..HEAD"
  [ "$status" -ne 0 ]
}

@test "G1 fails closed when the merge range cannot be read" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP
    AF_BASE_SHA=0000000000000000000000000000000000000001
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

# A3 - the pre-merge G1 re-check reads a committed range with `git diff
# --name-only`, not the working tree. Unlike `git status --porcelain`, plain
# `git diff --name-only` does NOT quote a path for a bare space (verified
# empirically) - it only quotes when the path contains a character git's
# quote_path() treats as unsafe (a literal double quote, backslash, or a
# non-ASCII byte under the default core.quotepath). So the reproduction
# needs a name that trips actual quoting, not just any space. This name has
# both a space and an embedded double quote - quoted without -z as
# `".github/workflows/ci \"sneaky\".yml"`, which no longer starts with
# `.github` and slips past the gate's regex.

@test "G1 over the commit range catches a quoted workflow filename (space + quote char)" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    mkdir -p \"\$AF_WORKTREE/.github/workflows\"
    printf evil > \"\$AF_WORKTREE/.github/workflows/ci \\\"sneaky\\\".yml\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

# A bare ".github" symlink/gitlink has no character git ever quotes, so this
# case passes identically with or without -z - it is a regression test that
# the bare-entry widening (^\.github($|/), fixed for the working-tree path
# in task 8) still applies through this new call site, not evidence of a
# -z-specific bypass.
@test "G1 over the commit range catches a bare .github symlink" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    ln -s evil_target \"\$AF_WORKTREE/.github\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

@test "G1 over the commit range does not trip on a .githubfoo prefix" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    mkdir -p \"\$AF_WORKTREE/.githubfoo\"
    echo x > \"\$AF_WORKTREE/.githubfoo/x\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm fix
    af_step_merge 7"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 7' "$AF_STUB_DIR/gh/calls.log"
}

# Finding 1 (post-review) - `git diff --name-only -z` emits only the
# resulting path for a rename; the old path is silently dropped. A commit
# in the merge range that renames a required workflow OUT of
# .github/workflows/ (disabling it) produces a path list with no
# .github-prefixed entry at all, and the gate never trips. af_changed_paths
# already handles this for the working-tree path (R/C emits both old and
# new paths, from `git status --porcelain -z`); af_range_paths needs the
# same rename-awareness for the committed-range path, from
# `git diff --name-status -z`.

@test "G1 over the commit range catches a rename OUT of .github/workflows" {
  mkdir -p "$REPO/.github/workflows"
  echo ci > "$REPO/.github/workflows/ci.yml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "add workflow"
  git -C "$REPO" push -q origin main
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    git -C \"\$AF_WORKTREE\" mv .github/workflows/ci.yml ci_moved.yml
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

# The mirror case: a rename INTO .github/workflows already carries the new
# (in-scope) path through --name-only, since that is always the resulting
# path shown for a rename - so this one is not a bypass under either
# implementation. Kept as a regression guard: if the rename-aware collector
# below ever stopped emitting the new path, this would catch it.
@test "G1 over the commit range catches a rename INTO .github/workflows" {
  echo x > "$REPO/plain.yml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "add plain"
  git -C "$REPO" push -q origin main
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    mkdir -p \"\$AF_WORKTREE/.github/workflows\"
    git -C \"\$AF_WORKTREE\" mv plain.yml .github/workflows/plain.yml
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

# G1 at the merge gate is not G1 anywhere else. Everywhere earlier the content
# is still local, and quarantining it is the whole point. Here CI has already
# gone green against a pushed branch that has an open, non-draft, unlabelled,
# MERGEABLE pull request on it - so refusing the merge and stopping leaves a
# human one click from landing the tampering agentfixer just detected.
# Nothing new is published by converting that PR to a draft and labelling it.
@test "G1 at the merge gate converts the open PR to a draft and labels it" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC
    af_setup_run '$REPO' alpha main >/dev/null
    mkdir -p \"\$AF_WORKTREE/.github/workflows\"
    echo evil > \"\$AF_WORKTREE/.github/workflows/ci.yml\"
    git -C \"\$AF_WORKTREE\" add -A
    git -C \"\$AF_WORKTREE\" -c user.email=t@t -c user.name=t commit -qm sneak
    af_step_merge 7"
  [ "$status" -eq 3 ]
  [[ "$output" == *"G1"* ]]
  grep -q 'pr ready 7 --repo test/alpha --undo' "$AF_STUB_DIR/gh/calls.log"
  grep -q -- 'pr edit 7 --repo test/alpha --add-label needs-human' "$AF_STUB_DIR/gh/calls.log"
  # The label has to exist before it can be applied.
  grep -q 'label create needs-human' "$AF_STUB_DIR/gh/calls.log"
  refute_grep 'pr merge' "$AF_STUB_DIR/gh/calls.log"
}

# The inverse, so the draft conversion cannot creep onto the clean path: a
# merge that passes G1 must leave the PR exactly as it found it.
@test "a merge that passes G1 never touches the PR's draft state or labels" {
  stub_gh "$(gh_key pr checks)" '[{"bucket":"pass","name":"t"}]'
  run bash -c "$SRC $PREP; af_step_merge 7"
  [ "$status" -eq 0 ]
  refute_grep 'pr ready' "$AF_STUB_DIR/gh/calls.log"
  refute_grep -- '--add-label needs-human' "$AF_STUB_DIR/gh/calls.log"
}
