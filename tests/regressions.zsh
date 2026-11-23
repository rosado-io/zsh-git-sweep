# Sourced by gitsweep.zsh; fixtures and assertions are shared with that suite.

function test_protection_across_commands() {
  local sweep root output branch
  local -a extra
  for sweep in gitsweep gitsweep-remote-merged gitsweep-remote-all gitsweep-all; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    (
      cd "$root/repo"
      for branch in release/v1 release/v2 staging keep-me; do
        git branch "$branch" main
        git push origin "$branch" >/dev/null 2>&1
      done
      git config --add gitsweep.protect 'release/*'
      git config --add gitsweep.protect staging
      git worktree add "$root/protected worktree" release/v1 >/dev/null 2>&1
      print dirty > "$root/protected worktree/untracked.txt"
      extra=()
      [[ "$sweep" == gitsweep || "$sweep" == gitsweep-all ]] && extra+=(--force)
      output=$($sweep --protect keep-me --protect 'spare/*' --dry-run "${extra[@]}" 2>&1)
      [[ "$output" != *'Would delete branch: release/'* && "$output" != *'Would delete remote branch: origin/release/'* ]] \
        || fail "$sweep preview must honor protection"
      $sweep --protect keep-me --protect 'spare/*' "${extra[@]}" >/dev/null 2>&1
    )
    for branch in release/v1 release/v2 staging keep-me; do
      assert_branch_exists "$root/repo" "$branch"
      assert_remote_branch_exists "$root" "$branch"
    done
    [[ -f "$root/protected worktree/untracked.txt" ]] || fail "protected worktree lost data"
    if [[ "$sweep" == gitsweep || "$sweep" == gitsweep-all ]]; then
      assert_branch_missing "$root/repo" feature
    fi
    if [[ "$sweep" != gitsweep ]]; then
      assert_remote_branch_missing "$root" feature
    fi
    pass "$sweep combines repeated CLI and configured protection, including force and preview"
  done
}

function test_invalid_protection_fails_before_fetch() {
  local root sweep pattern result
  root=$(make_temp_dir)
  setup_repo "$root"
  delete_remote_feature "$root"
  (
    cd "$root/repo"
    for sweep in gitsweep gitsweep-remote-merged gitsweep-remote-all gitsweep-all; do
      for pattern in '' '['; do
        result=0
        $sweep --protect "$pattern" >/dev/null 2>&1 || result=$?
        (( result == 2 )) || fail "invalid CLI protection must exit 2"
      done
      result=0
      $sweep --protect >/dev/null 2>&1 || result=$?
      (( result == 2 )) || fail "missing protection must exit 2"
      git config gitsweep.protect '['
      result=0
      $sweep >/dev/null 2>&1 || result=$?
      (( result == 2 )) || fail "invalid configured protection must exit 2"
      git config --unset gitsweep.protect
    done
    git show-ref --verify --quiet refs/remotes/origin/feature \
      || fail "invalid protection must stop before fetch prunes refs"
  )
  assert_branch_exists "$root/repo" feature
  pass "invalid and missing protection fail before any fetch or deletion"
}

function test_protection_does_not_leak_between_calls() {
  local root
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    gitsweep --no-fetch --protect feature >/dev/null 2>&1
    assert_branch_exists "$root/repo" feature
    gitsweep --no-fetch >/dev/null 2>&1
  )
  assert_branch_missing "$root/repo" feature
  pass "CLI protection lasts only for the current invocation"
}

function test_remote_concurrent_update_is_preserved() {
  local root sweep result output
  for sweep in gitsweep-remote-merged gitsweep-remote-all gitsweep-all; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    (
      cd "$root/seed"
      git checkout feature >/dev/null 2>&1
      git commit --allow-empty -m 'new work after merge' >/dev/null
    )
    (
      cd "$root/repo"
      # Advance the actual remote AND tracking ref between the scan and push.
      # A lease based on the current tracking ref would incorrectly allow deletion.
      function git() {
        if [[ "$1" == push ]]; then
          command git -C "$root/seed" push origin feature >/dev/null 2>&1
          command git fetch origin >/dev/null 2>&1
        fi
        command git "$@"
      }
      result=0
      output=$($sweep --no-fetch 2>&1) || result=$?
      (( result != 0 )) || fail "$sweep must report a concurrent remote update"
      [[ "$output" == *'stale info'* ]] || fail "expected explicit lease rejection"
    )
    assert_remote_branch_exists "$root" feature
    [[ "$(git --git-dir="$root/remote.git" rev-parse refs/heads/feature)" == "$(git -C "$root/seed" rev-parse refs/heads/feature)" ]] \
      || fail "new remote work must be preserved"
    pass "$sweep preserves concurrent remote commits even after a background fetch"
  done
}

function test_remote_stale_tracking_ref_is_preserved() {
  local root result
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/seed"
    git checkout feature >/dev/null 2>&1
    git commit --allow-empty -m 'unfetched work' >/dev/null
    git push origin feature >/dev/null 2>&1
  )
  (
    cd "$root/repo"
    result=0
    gitsweep-remote-merged --no-fetch >/dev/null 2>&1 || result=$?
    (( result != 0 )) || fail "stale tracking refs must not permit deletion"
  )
  assert_remote_branch_exists "$root" feature
  pass "no-fetch cannot delete remote work missing from the local scan"
}

function test_remote_rejected_deletion_returns_failure() {
  local root sweep result
  for sweep in gitsweep-remote-merged gitsweep-remote-all; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    printf '#!/bin/sh\nexit 1\n' > "$root/remote.git/hooks/pre-receive"
    chmod +x "$root/remote.git/hooks/pre-receive"
    (
      cd "$root/repo"
      result=0
      $sweep >/dev/null 2>&1 || result=$?
      (( result != 0 )) || fail "$sweep must report rejected deletion"
    )
    assert_remote_branch_exists "$root" feature
    pass "$sweep returns failure when the server rejects deletion"
  done
}

function test_remote_branch_and_tag_same_name() {
  local root
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    git tag feature refs/heads/feature
    git push origin refs/tags/feature >/dev/null 2>&1
    gitsweep-remote-merged >/dev/null 2>&1
  )
  assert_remote_branch_missing "$root" feature
  git --git-dir="$root/remote.git" show-ref --verify --quiet refs/tags/feature \
    || fail "remote sweep must preserve tags with the same name"
  pass "remote deletion disambiguates branch names from tags"
}

function test_remote_rejects_non_branch_base() {
  local root sweep base result
  root=$(make_temp_dir)
  setup_repo "$root"
  git -C "$root/repo" tag release-tag main
  (
    cd "$root/repo"
    for sweep in gitsweep-remote-merged gitsweep-remote-all gitsweep-all; do
      for base in refs/tags/release-tag "$(git rev-parse main)"; do
        result=0
        $sweep --no-fetch --base "$base" >/dev/null 2>&1 || result=$?
        (( result != 0 )) || fail "remote sweep must require a named base branch"
      done
    done
  )
  assert_remote_branch_exists "$root" main
  assert_remote_branch_exists "$root" feature
  pass "remote sweeps reject tags and commit IDs as primary branches"
}

function test_local_base_with_slash_is_protected() {
  local root
  root=$(make_temp_dir)
  setup_repo "$root"
  (
    cd "$root/repo"
    git branch release/current main
    git branch disposable main
    gitsweep --no-fetch --base release/current >/dev/null 2>&1
  )
  assert_branch_exists "$root/repo" release/current
  assert_branch_missing "$root/repo" disposable
  pass "local base branch containing a slash stays protected"
}

function test_nested_remote_and_base_names() {
  local root
  root=$(make_temp_dir)
  setup_repo "$root"
  (
    cd "$root/repo"
    git branch release/current main
    git push origin release/current >/dev/null 2>&1
    git remote rename origin team/upstream
    gitsweep --no-fetch --base team/upstream/release/current >/dev/null 2>&1
    assert_branch_exists "$root/repo" release/current
    git switch release/current >/dev/null 2>&1
    gitsweep-all --no-fetch --remote team/upstream --base refs/heads/release/current \
      --protect main --force >/dev/null 2>&1
  )
  assert_branch_exists "$root/repo" release/current
  assert_remote_branch_exists "$root" release/current
  assert_remote_branch_exists "$root" main
  assert_remote_branch_missing "$root" feature
  pass "nested remote and base names preserve the selected primary branch"
}

function test_current_branch_with_tag_collision() {
  local root output
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    git switch feature >/dev/null 2>&1
    git tag feature
    output=$(gitsweep --no-fetch --force --dry-run 2>&1)
    [[ "$output" != *'Would delete branch: feature'* ]] \
      || fail "current branch must be skipped even when a tag shares its name"
  )
  assert_branch_exists "$root/repo" feature
  pass "current branch protection is unaffected by an identically named tag"
}

function test_worktree_special_paths() {
  local root wt
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  wt="$root/"$'work tree-é-"quoted"-\\slash\tline\nbreak'
  (
    cd "$root/repo"
    git worktree add "$wt" feature >/dev/null 2>&1
    gitsweep --no-fetch --dry-run >/dev/null 2>&1
    [[ -d "$wt" ]] || fail "preview must keep special-path worktree"
    gitsweep --no-fetch >/dev/null 2>&1
  )
  [[ ! -d "$wt" ]] || fail "special-path worktree should be removed"
  assert_branch_missing "$root/repo" feature
  pass "worktree parsing handles spaces, Unicode, quotes, backslashes, tabs and newlines"
}

function test_locked_worktree_is_preserved_in_preview_and_force() {
  local root output
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    git worktree add "$root/locked" feature >/dev/null 2>&1
    git worktree lock --reason 'keep this work' "$root/locked"
    output=$(gitsweep --no-fetch --dry-run --force 2>&1)
    [[ "$output" == *'Worktree is locked; skipping branch.'* && "$output" != *'Would delete branch: feature'* ]] \
      || fail "preview must report locked worktree as skipped"
    gitsweep --no-fetch --force >/dev/null 2>&1
  )
  assert_branch_exists "$root/repo" feature
  [[ -d "$root/locked" ]] || fail "locked worktree must survive force"
  pass "locked worktrees are preserved and accurately previewed, even with force"
}

function test_hidden_untracked_files_are_preserved() {
  local root output
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    git worktree add "$root/dirty" feature >/dev/null 2>&1
    git config status.showUntrackedFiles no
    print unsaved > "$root/dirty/untracked.txt"
    output=$(gitsweep --no-fetch --dry-run 2>&1)
    [[ "$output" == *'Worktree has local changes; skipping branch.'* ]] \
      || fail "preview must see untracked files regardless of Git config"
    gitsweep --no-fetch >/dev/null 2>&1
  )
  [[ -f "$root/dirty/untracked.txt" ]] || fail "untracked files must survive"
  assert_branch_exists "$root/repo" feature
  pass "untracked-file Git settings cannot hide dirty worktrees from the preview"
}

function test_failed_status_is_not_clean() {
  local root output
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    git worktree add "$root/unreadable" feature >/dev/null 2>&1
    function git() {
      [[ "$1" == -C && "${3:-}" == status ]] && return 1
      command git "$@"
    }
    output=$(gitsweep --no-fetch --dry-run 2>&1)
    [[ "$output" == *'Could not inspect worktree; skipping branch.'* && "$output" != *'Would delete branch: feature'* ]] \
      || fail "failed status must not be treated as a clean worktree"
    gitsweep --no-fetch >/dev/null 2>&1
    gitsweep --no-fetch --force >/dev/null 2>&1
  )
  assert_branch_exists "$root/repo" feature
  [[ -d "$root/unreadable" ]] || fail "uninspectable worktree must survive"
  pass "failed worktree inspection preserves the branch and worktree even with force"
}

test_protection_across_commands
test_invalid_protection_fails_before_fetch
test_protection_does_not_leak_between_calls
test_remote_concurrent_update_is_preserved
test_remote_stale_tracking_ref_is_preserved
test_remote_rejected_deletion_returns_failure
test_remote_branch_and_tag_same_name
test_remote_rejects_non_branch_base
test_local_base_with_slash_is_protected
test_nested_remote_and_base_names
test_current_branch_with_tag_collision
test_worktree_special_paths
test_locked_worktree_is_preserved_in_preview_and_force
test_hidden_untracked_files_are_preserved
test_failed_status_is_not_clean

function test_local_pr_refs() (
  local sweep=$1 root ref output result
  root=$(make_temp_dir)
  setup_repo "$root"
  cd "$root/repo"
  git update-ref refs/remotes/pr/43 feature
  git branch -D feature >/dev/null
  delete_remote_feature "$root"
  git update-ref refs/remotes/pr/42 main
  git update-ref refs/remotes/pr/45 main
  git update-ref refs/remotes/pr/note main
  git symbolic-ref refs/remotes/pr/44 refs/heads/main
  git config gitsweep.protect pr/45

  output=$($sweep --dry-run)
  [[ "$output" == *'refs/remotes/pr/42'* ]] || fail "$sweep preview omitted the eligible PR ref"
  git show-ref --verify --quiet refs/remotes/pr/42 || fail "preview deleted the PR ref"

  result=0
  $sweep >/dev/null || result=$?
  if [[ "$sweep" == gitsweep-all ]]; then
    (( result == 1 )) || fail "full sweep should report the unmerged PR tip left behind"
  else
    (( result == 0 )) || fail "local sweep failed"
  fi
  if git show-ref --verify --quiet refs/remotes/pr/42; then fail "$sweep kept a merged PR ref"; fi
  git show-ref --verify --quiet refs/remotes/pr/43 || fail "$sweep deleted an unmerged PR tip"

  git config --add remote.origin.fetch '+refs/heads/review/*:refs/remotes/pr/7*'
  git update-ref refs/remotes/pr/70 main
  $sweep --force --no-fetch >/dev/null
  if git show-ref --verify --quiet refs/remotes/pr/43; then fail "$sweep did not force-remove unmerged ref"; fi
  for ref in pr/44 pr/45 pr/note pr/70 origin/main; do
    git show-ref --verify --quiet "refs/remotes/$ref" || fail "$sweep removed $ref"
  done
  git remote add pr "$root/remote.git"
  git update-ref refs/remotes/pr/46 main
  $sweep --no-fetch >/dev/null
  git show-ref --verify --quiet refs/remotes/pr/46 || fail "$sweep removed a real remote's ref"
  assert_remote_branch_exists "$root" main
  pass "$sweep cleans eligible local PR refs by default"
)

test_local_pr_refs gitsweep
test_local_pr_refs gitsweep-all
