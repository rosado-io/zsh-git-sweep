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

function create_remote_branch() {
  local root=$1
  local branch=$2

  (
    cd "$root/seed"
    git checkout main >/dev/null 2>&1
    git checkout -b "$branch" >/dev/null 2>&1
    git commit --allow-empty -m "$branch" >/dev/null
    git push -u origin "$branch" >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
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

function assert_remote_branch_exists() {
  local root=$1
  local branch=$2

  git --git-dir="$root/remote.git" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "expected remote branch '$branch' to exist"
}

function assert_remote_branch_missing() {
  local root=$1
  local branch=$2

  ! git --git-dir="$root/remote.git" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "expected remote branch '$branch' to be deleted"
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

function test_remote_merged_dry_run_preserves_remote_branch() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"
  merge_feature_to_main "$root/repo"

  local output
  (
    cd "$root/repo"
    output=$(gitsweep-remote-merged --dry-run 2>&1)
    [[ "$output" == *"Dry run mode: no remote branches or Git refs will be changed."* ]] \
      || fail "expected remote dry run output to say no remote refs will be changed"
    [[ "$output" == *"Would delete remote branch: origin/feature"* ]] \
      || fail "expected remote dry run to detect merged remote branch"
  )

  assert_remote_branch_exists "$root" main
  assert_remote_branch_exists "$root" feature
  pass "remote merged dry run preserves remote branches"
}

function test_remote_merged_deletes_only_merged_remote_branch() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"
  create_remote_branch "$root" wip
  merge_feature_to_main "$root/repo"

  (
    cd "$root/repo"
    gitsweep-remote-merged >/dev/null 2>&1
  )

  assert_remote_branch_exists "$root" main
  assert_remote_branch_exists "$root" wip
  assert_remote_branch_missing "$root" feature
  pass "remote merged deletes only merged remote branches"
}

function test_remote_all_dry_run_preserves_remote_branches() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  local output
  (
    cd "$root/repo"
    output=$(gitsweep-remote-all --dry-run 2>&1)
    [[ "$output" == *"Would delete remote branch: origin/feature"* ]] \
      || fail "expected remote all dry run to preview feature deletion"
    [[ "$output" != *"origin/origin"* ]] \
      || fail "expected remote all dry run to skip origin HEAD symbolic ref"
  )

  assert_remote_branch_exists "$root" main
  assert_remote_branch_exists "$root" feature
  pass "remote all dry run preserves remote branches"
}

function test_remote_all_deletes_everything_except_primary() {
  local root
  root=$(make_temp_dir)
  local nested_branch="topic/sweep.demo-123"

  setup_repo "$root"
  create_remote_branch "$root" wip
  create_remote_branch "$root" "$nested_branch"

  (
    cd "$root/repo"
    gitsweep-remote-all >/dev/null 2>&1
  )

  assert_remote_branch_exists "$root" main
  assert_remote_branch_missing "$root" feature
  assert_remote_branch_missing "$root" wip
  assert_remote_branch_missing "$root" "$nested_branch"
  pass "remote all deletes everything except primary"
}

function test_remote_aliases_are_registered() {
  [[ "$(alias gsweep-rm)" == "gsweep-rm=gitsweep-remote-merged" ]] \
    || fail "expected gsweep-rm alias to point to gitsweep-remote-merged"
  [[ "$(alias gsweep-ra)" == "gsweep-ra=gitsweep-remote-all" ]] \
    || fail "expected gsweep-ra alias to point to gitsweep-remote-all"
  pass "remote aliases are registered"
}

function test_all_dry_run_preserves_local_and_remote_branches() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"
  merge_feature_to_main "$root/repo"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
  )

  local output
  (
    cd "$root/repo"
    output=$(gitsweep-all --dry-run 2>&1)
    [[ "$output" == *"Dry run mode: no branches, worktrees, remote branches, or Git refs will be changed."* ]] \
      || fail "expected full dry run output to say nothing will be changed"
    [[ "$output" == *"Would delete remote branch: origin/feature"* ]] \
      || fail "expected full dry run to preview remote branch deletion"
    [[ "$output" == *"Would remove worktree at"* ]] \
      || fail "expected full dry run to preview worktree removal"
    [[ "$output" == *"Would delete branch: feature"* ]] \
      || fail "expected full dry run to preview local branch deletion"
  )

  [[ -d "$root/wt-feature" ]] || fail "expected full dry run to preserve worktree"
  assert_branch_exists "$root/repo" feature
  assert_remote_branch_exists "$root" main
  assert_remote_branch_exists "$root" feature
  git -C "$root/repo" show-ref --verify --quiet refs/remotes/origin/feature \
    || fail "expected full dry run to preserve remote-tracking ref"
  pass "full sweep dry run preserves local and remote branches"
}

function test_all_refuses_to_run_off_primary_branch() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  local output
  (
    cd "$root/repo"
    git checkout feature >/dev/null 2>&1

    local exit_code=0
    output=$(gitsweep-all 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "expected full sweep to fail off the primary branch"
    [[ "$output" == *"Switch first with: git switch main"* ]] \
      || fail "expected full sweep to tell the user to switch to the primary branch"
  )

  assert_branch_exists "$root/repo" feature
  assert_remote_branch_exists "$root" feature
  pass "full sweep refuses to run off the primary branch"
}

function test_all_deletes_every_non_primary_branch() {
  local root
  root=$(make_temp_dir)
  local nested_branch="topic/sweep.demo-123"

  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  create_remote_branch "$root" wip
  create_remote_branch "$root" "$nested_branch"

  (
    cd "$root/repo"
    git worktree add "$root/wt-feature" feature >/dev/null 2>&1
    git branch local-only main
    gitsweep-all >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-feature" ]] || fail "expected full sweep to remove worktree"
  assert_branch_exists "$root/repo" main
  assert_branch_missing "$root/repo" feature
  assert_branch_missing "$root/repo" local-only
  assert_remote_branch_exists "$root" main
  assert_remote_branch_missing "$root" feature
  assert_remote_branch_missing "$root" wip
  assert_remote_branch_missing "$root" "$nested_branch"
  [[ -z "$(git -C "$root/repo" for-each-ref --format='%(refname)' refs/remotes/origin | grep -v -e '/HEAD$' -e '/main$')" ]] \
    || fail "expected full sweep to prune remote-tracking refs"
  pass "full sweep deletes every non-primary local and remote branch"
}

function test_all_requires_force_for_unmerged_and_dirty_work() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"

  (
    cd "$root/repo"
    git branch done main
    git worktree add "$root/wt-done" done >/dev/null 2>&1
    print -- "dirty" > "$root/wt-done/dirty.txt"
  )

  local output
  (
    cd "$root/repo"

    local exit_code=0
    output=$(gitsweep-all 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "expected full sweep to fail when branches are left behind"
    [[ "$output" == *"Branch is not merged into origin/main; skipping."* ]] \
      || fail "expected full sweep to skip unmerged branch without force"
    [[ "$output" == *"Worktree has local changes; skipping branch."* ]] \
      || fail "expected full sweep to skip dirty worktree without force"
    [[ "$output" == *"left behind: done, feature"* ]] \
      || fail "expected full sweep to report branches left behind"
  )

  [[ -d "$root/wt-done" ]] || fail "expected dirty worktree to be preserved without force"
  assert_branch_exists "$root/repo" feature
  assert_branch_exists "$root/repo" done
  assert_remote_branch_missing "$root" feature

  (
    cd "$root/repo"
    gitsweep-all --force >/dev/null 2>&1
  )

  [[ ! -d "$root/wt-done" ]] || fail "expected force to remove dirty worktree"
  assert_branch_missing "$root/repo" feature
  assert_branch_missing "$root/repo" done
  assert_branch_exists "$root/repo" main
  pass "full sweep requires force for unmerged branches and dirty worktrees"
}

function test_all_reports_partial_remote_failure() {
  local root
  root=$(make_temp_dir)

  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  create_remote_branch "$root" locked
  create_remote_branch "$root" wip

  cat > "$root/remote.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read old new ref; do
  if [ "$ref" = "refs/heads/locked" ]; then
    echo "locked branch cannot be changed" >&2
    exit 1
  fi
done
EOF
  chmod +x "$root/remote.git/hooks/pre-receive"

  local output
  (
    cd "$root/repo"

    local exit_code=0
    output=$(gitsweep-all 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "expected full sweep to fail on partial remote failure"
    [[ "$output" == *"left behind: origin/locked"* ]] \
      || fail "expected full sweep to report the remote branch left behind"
  )

  assert_remote_branch_exists "$root" main
  assert_remote_branch_exists "$root" locked
  assert_remote_branch_missing "$root" feature
  assert_remote_branch_missing "$root" wip
  assert_branch_missing "$root/repo" feature
  pass "full sweep reports partial remote failure"
}

function test_all_alias_is_registered() {
  [[ "$(alias gsweep-a)" == "gsweep-a=gitsweep-all" ]] \
    || fail "expected gsweep-a alias to point to gitsweep-all"
  pass "full sweep alias is registered"
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
test_remote_merged_dry_run_preserves_remote_branch
test_remote_merged_deletes_only_merged_remote_branch
test_remote_all_dry_run_preserves_remote_branches
test_remote_all_deletes_everything_except_primary
test_remote_aliases_are_registered
test_all_dry_run_preserves_local_and_remote_branches
test_all_refuses_to_run_off_primary_branch
test_all_deletes_every_non_primary_branch
test_all_requires_force_for_unmerged_and_dirty_work
test_all_reports_partial_remote_failure
test_all_alias_is_registered
