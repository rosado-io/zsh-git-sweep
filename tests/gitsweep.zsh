#!/usr/bin/env zsh

emulate -L zsh
set -euo pipefail

readonly TEST_DIR=${0:A:h}
readonly REPO_ROOT=${TEST_DIR:h}
readonly PLUGIN_PATH="$REPO_ROOT/zsh-git-sweep.plugin.zsh"

source "$PLUGIN_PATH"

typeset -a TEMP_DIRS

function cleanup() {
  if (( ${#TEMP_DIRS} > 0 )); then
    rm -rf "${TEMP_DIRS[@]}"
  fi
}

trap cleanup EXIT

function fail() {
  print -ru2 -- "not ok - $*"
  exit 1
}

function pass() {
  print -- "ok - $*"
}

function configure_repo() {
  git config user.email test@example.com
  git config user.name "Test User"
}

function make_temp_dir() {
  local root
  root=$(mktemp -d)
  TEMP_DIRS+=("$root")
  print -- "$root"
}

function setup_repo() {
  local root=$1

  git init --bare "$root/remote.git" >/dev/null
  git init "$root/seed" >/dev/null

  (
    cd "$root/seed"
    configure_repo

    print -- "main" > file.txt
    git add file.txt
    git commit -m "init" >/dev/null
    git branch -M main
    git remote add origin "$root/remote.git"
    git push -u origin main >/dev/null 2>&1

    git checkout -b feature >/dev/null 2>&1
    print -- "feature" > feature.txt
    git add feature.txt
    git commit -m "feature" >/dev/null
    git push -u origin feature >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
  )

  git --git-dir="$root/remote.git" symbolic-ref HEAD refs/heads/main
  git clone "$root/remote.git" "$root/repo" >/dev/null 2>&1

  (
    cd "$root/repo"
    configure_repo
    git checkout -b feature origin/feature >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
  )
}

function delete_remote_feature() {
  local root=$1

  (
    cd "$root/seed"
    git push origin --delete feature >/dev/null 2>&1
  )
}

function merge_feature_to_main() {
  local repo=$1

  (
    cd "$repo"
    git checkout main >/dev/null 2>&1
    git merge --ff-only feature >/dev/null
    git push origin main >/dev/null 2>&1
  )
}

function assert_branch_exists() {
  local repo=$1
  local branch=$2

  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "expected branch '$branch' to exist"
}

function assert_branch_missing() {
  local repo=$1
  local branch=$2

  ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "expected branch '$branch' to be deleted"
}

function test_removes_clean_merged_worktree() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
  )

  merge_feature_to_main "$root/repo"
  delete_remote_feature "$root"

  (
    cd "$root/repo"
    gitsweep >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-feature" ]] || fail "expected clean worktree to be removed"
  assert_branch_missing "$root/repo" feature
  pass "removes clean merged worktree and branch"
}

function test_removes_merged_branch_when_remote_still_exists() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
  )

  merge_feature_to_main "$root/repo"

  (
    cd "$root/repo"
    gitsweep >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-feature" ]] || fail "expected merged worktree to be removed"
  assert_branch_missing "$root/repo" feature
  pass "removes merged branch even when remote branch still exists"
}

function test_keeps_dirty_unmerged_worktree_by_default() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
    print -- "dirty" >> "$root/wt-feature/feature.txt"
  )

  delete_remote_feature "$root"

  (
    cd "$root/repo"
    gitsweep >/dev/null 2>&1
  )

  [[ -d "$root/wt-feature" ]] || fail "expected dirty worktree to be preserved"
  assert_branch_exists "$root/repo" feature
  pass "keeps dirty unmerged worktree by default"
}

function test_dry_run_does_not_remove_merged_branch_or_worktree() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
  )

  merge_feature_to_main "$root/repo"
  delete_remote_feature "$root"

  local output
  (
    cd "$root/repo"
    output=$(gitsweep --dry-run 2>&1)
    [[ "$output" == *"Dry run mode: no branches, worktrees, or Git refs will be changed."* ]] \
      || fail "expected dry run output to say no Git refs will be changed"
    [[ "$output" == *"Would delete branch: feature"* ]] \
      || fail "expected dry run to detect pruned upstream without changing refs"
  )

  [[ -d "$root/wt-feature" ]] || fail "expected dry run to preserve worktree"
  assert_branch_exists "$root/repo" feature
  git -C "$root/repo" show-ref --verify --quiet refs/remotes/origin/feature \
    || fail "expected dry run to preserve remote-tracking ref"
  pass "dry run does not remove merged branch or worktree"
}

function test_keeps_dirty_merged_worktree_by_default() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
  )

  merge_feature_to_main "$root/repo"
  print -- "dirty" >> "$root/wt-feature/feature.txt"

  (
    cd "$root/repo"
    gitsweep >/dev/null 2>&1
  )

  [[ -d "$root/wt-feature" ]] || fail "expected dirty merged worktree to be preserved"
  assert_branch_exists "$root/repo" feature
  pass "keeps dirty merged worktree by default"
}

function test_force_removes_dirty_unmerged_worktree() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
    print -- "dirty" >> "$root/wt-feature/feature.txt"
  )

  delete_remote_feature "$root"

  (
    cd "$root/repo"
    gitsweep --force >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-feature" ]] || fail "expected force to remove dirty worktree"
  assert_branch_missing "$root/repo" feature
  pass "force removes dirty unmerged worktree and branch"
}

function test_stale_unmerged_branch_requires_force() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git checkout -b old-experiment >/dev/null 2>&1
    GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" \
      GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
      git commit --allow-empty -m "old experiment" >/dev/null
    git checkout main >/dev/null 2>&1
    git worktree add "$root/wt-old-experiment" old-experiment >/dev/null 2>&1
  )

  (
    cd "$root/repo"
    gitsweep --stale-days 1 >/dev/null 2>&1
  )

  [[ -d "$root/wt-old-experiment" ]] || fail "expected stale worktree to be preserved without force"
  assert_branch_exists "$root/repo" old-experiment

  (
    cd "$root/repo"
    gitsweep --stale-days 1 --force >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-old-experiment" ]] || fail "expected force to remove stale worktree"
  assert_branch_missing "$root/repo" old-experiment
  pass "stale unmerged branch requires force"
}

function test_skips_current_branch() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git checkout feature >/dev/null 2>&1
  )

  delete_remote_feature "$root"

  (
    cd "$root/repo"
    gitsweep >/dev/null 2>&1
  )

  assert_branch_exists "$root/repo" feature
  pass "skips current branch"
}

function test_removes_branch_with_slash_and_dot() {
  local root
  root=$(make_temp_dir)
  local branch="topic/sweep.demo-123"

  setup_repo "$root"

  (
    cd "$root/repo"
    git checkout -b "$branch" main >/dev/null 2>&1
    print -- "nested" > nested.txt
    git add nested.txt
    git commit -m "nested branch" >/dev/null
    git checkout main >/dev/null 2>&1
    git merge --ff-only "$branch" >/dev/null
    git worktree add "$root/wt-nested" "$branch" >/dev/null 2>&1
  )

  (
    cd "$root/repo"
    gitsweep --base main --no-fetch >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-nested" ]] || fail "expected nested branch worktree to be removed"
  assert_branch_missing "$root/repo" "$branch"
  pass "removes branch with slash and dot"
}

test_removes_clean_merged_worktree
test_removes_merged_branch_when_remote_still_exists
test_keeps_dirty_unmerged_worktree_by_default
test_dry_run_does_not_remove_merged_branch_or_worktree
test_keeps_dirty_merged_worktree_by_default
test_force_removes_dirty_unmerged_worktree
test_stale_unmerged_branch_requires_force
test_skips_current_branch
test_removes_branch_with_slash_and_dot
