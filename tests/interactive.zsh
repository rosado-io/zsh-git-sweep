# Sourced by gitsweep.zsh. Exercise the real terminal UI with zsh's bundled PTY.
zmodload zsh/zpty || fail "zsh/zpty is required for interactive integration tests"
typeset PTY_LOG="" PTY_CHUNK=""

function start_sweep_terminal() {
  local repo=$1
  shift
  local -a child=(zsh -f "$TEST_DIR/interactive-session.zsh" "$PLUGIN_PATH" "$repo" "$@")
  PTY_LOG=""
  zpty -b sweep "${(@q)child}"
}

function expect_sweep_output() {
  local expected=$1 chunk="" output="" deadline=$(( SECONDS + 20 ))
  while (( SECONDS < deadline )); do
    if zpty -r sweep chunk; then
      output+=$chunk
      PTY_LOG+=$chunk
      if [[ "$output" == *"$expected"* ]]; then
        PTY_CHUNK=$output
        return 0
      fi
    else
      sleep 0.02
    fi
  done
  print -ru2 -- "$PTY_LOG"
  fail "terminal did not produce: $expected"
}

function finish_sweep_terminal() {
  expect_sweep_output "SESSION-RESULT:$1"
  zpty -d sweep
}

function test_interactive_requires_terminal_before_fetch() {
  local root sweep result
  root=$(make_temp_dir)
  setup_repo "$root"
  delete_remote_feature "$root"
  (
    cd "$root/repo"
    for sweep in gitsweep gitsweep-remote-merged gitsweep-remote-all gitsweep-all; do
      result=0
      $sweep --interactive </dev/null >/dev/null 2>&1 || result=$?
      (( result == 2 )) || fail "interactive commands must reject nonterminal input"
      git show-ref --verify --quiet refs/remotes/origin/feature \
        || fail "terminal rejection must happen before fetch/prune"
    done
  )
  assert_branch_exists "$root/repo" feature
  pass "all interactive commands reject nonterminal input before mutation"
}

function test_interactive_selects_local_worktree_pair() {
  local root
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  (
    cd "$root/repo"
    git branch other main
    git branch release/keep main
    git config gitsweep.protect 'release/*'
    git worktree add "$root/wt feature" feature >/dev/null 2>&1
    git worktree add "$root/wt-other" other >/dev/null 2>&1
  )
  start_sweep_terminal "$root/repo" gitsweep -i --no-fetch
  expect_sweep_output 'Selection ('
  [[ "$PTY_LOG" == *'1) local feature + worktree'* && "$PTY_LOG" == *'2) local other + worktree'* ]] \
    || fail "menu must describe both branch/worktree pairs"
  [[ "$PTY_LOG" != *') local release/keep'* && "$PTY_LOG" != *') local main'* ]] \
    || fail "protected branches must not be selectable"
  zpty -w sweep '1,1'
  expect_sweep_output 'Type yes to continue [no]: '
  [[ "$PTY_CHUNK" == *'Delete these 1 selected entries?'* ]] || fail "selection must deduplicate indexes"
  assert_branch_exists "$root/repo" feature
  [[ -d "$root/wt feature" ]] || fail "worktree must survive until final confirmation"
  zpty -w sweep yes
  finish_sweep_terminal 0
  assert_branch_missing "$root/repo" feature
  assert_branch_exists "$root/repo" other
  assert_branch_exists "$root/repo" release/keep
  [[ ! -d "$root/wt feature" && -d "$root/wt-other" ]] || fail "only selected worktree should be removed"
  assert_remote_branch_exists "$root" feature
  pass "interactive local sweep deletes only the selected branch/worktree pair after confirmation"
}

function test_interactive_cancellation_and_validation() {
  local root sweep
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  for sweep in gitsweep gitsweep-remote-merged gitsweep-remote-all gitsweep-all; do
    start_sweep_terminal "$root/repo" "$sweep" -i --no-fetch
    expect_sweep_output 'Selection ('
    zpty -w sweep '1 999999999999999999999999999999'
    expect_sweep_output 'Invalid selection.'
    zpty -w sweep '1+0'
    expect_sweep_output 'Invalid selection.'
    zpty -w -n sweep $'\n'
    finish_sweep_terminal 0
    assert_branch_exists "$root/repo" feature
    assert_remote_branch_exists "$root" feature
    pass "$sweep rejects invalid selections and cancels without deleting anything"
  done
  start_sweep_terminal "$root/repo" gitsweep-all -i --no-fetch
  expect_sweep_output 'Selection ('
  zpty -w sweep all
  expect_sweep_output 'Type yes to continue [no]: '
  zpty -w -n sweep $'\n'
  finish_sweep_terminal 0
  assert_branch_exists "$root/repo" feature
  assert_remote_branch_exists "$root" feature
  pass "empty final confirmation cancels the entire combined sweep"
}

function test_interactive_eof() {
  local root phase
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  for phase in selection confirmation; do
    start_sweep_terminal "$root/repo" gitsweep-all -i --no-fetch
    expect_sweep_output 'Selection ('
    if [[ "$phase" == confirmation ]]; then
      zpty -w sweep all
      expect_sweep_output 'Type yes to continue [no]: '
    fi
    zpty -w -n sweep $'\004'
    finish_sweep_terminal 130
    assert_branch_exists "$root/repo" feature
    assert_remote_branch_exists "$root" feature
  done
  pass "EOF at either prompt cancels without any deletion"
}

function test_interactive_interrupt() {
  local root phase deadline
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  for phase in selection confirmation; do
    start_sweep_terminal "$root/repo" gitsweep-all -i --no-fetch
    expect_sweep_output 'Selection ('
    if [[ "$phase" == confirmation ]]; then
      zpty -w sweep all
      expect_sweep_output 'Type yes to continue [no]: '
    fi
    zpty -w -n sweep $'\003'
    deadline=$(( SECONDS + 15 ))
    while zpty -t sweep && (( SECONDS < deadline )); do sleep 0.02; done
    if zpty -t sweep; then fail "Ctrl-C must stop the interactive session"; fi
    zpty -d sweep
    assert_branch_exists "$root/repo" feature
    assert_remote_branch_exists "$root" feature
  done
  pass "Ctrl-C at either prompt stops without any deletion"
}

function test_interactive_unmerged_requires_force() {
  local root
  root=$(make_temp_dir)
  setup_repo "$root"
  delete_remote_feature "$root"
  git -C "$root/repo" fetch -p origin >/dev/null 2>&1
  start_sweep_terminal "$root/repo" gitsweep -i --no-fetch
  finish_sweep_terminal 0
  [[ "$PTY_LOG" == *'not merged into'* && "$PTY_LOG" != *'Selection ('* ]] \
    || fail "unmerged candidates must not be offered without force"
  assert_branch_exists "$root/repo" feature
  start_sweep_terminal "$root/repo" gitsweep -i --no-fetch --force
  expect_sweep_output 'Selection ('
  [[ "$PTY_LOG" == *'FORCE:'* ]] || fail "force selection must warn about lost commits"
  zpty -w sweep 1
  expect_sweep_output 'Type yes to continue [no]: '
  zpty -w sweep yes
  finish_sweep_terminal 0
  assert_branch_missing "$root/repo" feature
  pass "interactive cleanup requires explicit force and confirmation for unmerged branches"
}

function test_interactive_dry_run() {
  local root before after
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  git -C "$root/repo" worktree add "$root/wt-feature" feature >/dev/null 2>&1
  before=$(git -C "$root/repo" for-each-ref --format='%(refname) %(objectname)')
  start_sweep_terminal "$root/repo" gitsweep-all -i --dry-run
  expect_sweep_output 'Selection ('
  zpty -w sweep all
  finish_sweep_terminal 0
  [[ "$PTY_LOG" == *'Would delete branch: feature'* && "$PTY_LOG" == *'Would delete remote branch: origin/feature'* ]] \
    || fail "interactive dry run must preview both selected scopes"
  [[ "$PTY_LOG" != *'Type yes to continue'* ]] || fail "dry run must not ask to delete"
  after=$(git -C "$root/repo" for-each-ref --format='%(refname) %(objectname)')
  [[ "$before" == "$after" && -d "$root/wt-feature" ]] || fail "dry run mutated refs or worktree"
  assert_remote_branch_exists "$root" feature
  pass "interactive dry run previews the selection without changing refs or worktrees"
}

function test_interactive_all_selects_scopes_independently() {
  local root selection
  for selection in 1 2; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    git -C "$root/repo" worktree add "$root/wt-feature" feature >/dev/null 2>&1
    start_sweep_terminal "$root/repo" gitsweep-all -i --no-fetch
    expect_sweep_output 'Selection ('
    [[ "$PTY_LOG" == *'1) local feature'* && "$PTY_LOG" == *'2) remote origin/feature'* ]] \
      || fail "local and remote copies must be separate choices"
    zpty -w sweep "$selection"
    expect_sweep_output 'Type yes to continue [no]: '
    zpty -w sweep yes
    finish_sweep_terminal 0
    if [[ "$selection" == 1 ]]; then
      assert_branch_missing "$root/repo" feature
      assert_remote_branch_exists "$root" feature
      [[ ! -d "$root/wt-feature" ]] || fail "selected local worktree should be removed"
    else
      assert_branch_exists "$root/repo" feature
      assert_remote_branch_missing "$root" feature
      [[ -d "$root/wt-feature" ]] || fail "unselected local worktree must be kept"
    fi
  done
  pass "full interactive sweep selects local and remote copies independently"
}

function test_interactive_safety_and_force() {
  local root mode
  for mode in safe force; do
    root=$(make_temp_dir)
    setup_repo "$root"
    (
      cd "$root/repo"
      git branch dirty main
      git branch locked main
      git branch release/keep main
      git config gitsweep.protect 'release/*'
      git worktree add "$root/wt-dirty" dirty >/dev/null 2>&1
      git worktree add "$root/wt-locked" locked >/dev/null 2>&1
      git worktree lock "$root/wt-locked"
      print unsaved > "$root/wt-dirty/untracked.txt"
    )
    local -a extra=()
    [[ "$mode" == force ]] && extra+=(--force)
    start_sweep_terminal "$root/repo" gitsweep-all -i --no-fetch --protect feature "${extra[@]}"
    if [[ "$mode" == safe ]]; then
      finish_sweep_terminal 0
      [[ "$PTY_LOG" == *'No eligible candidates'* ]] || fail "unsafe candidates must not be selectable"
    else
      expect_sweep_output 'Selection ('
      [[ "$PTY_LOG" == *'1) local dirty + worktree'* && "$PTY_LOG" == *'FORCE:'* ]] \
        || fail "force menu must describe destructive local selection"
      [[ "$PTY_LOG" != *') local locked'* && "$PTY_LOG" != *') local release/keep'* && "$PTY_LOG" != *') remote origin/feature'* ]] \
        || fail "force must preserve locks and CLI/configured protection"
      zpty -w sweep all
      expect_sweep_output 'Type yes to continue [no]: '
      zpty -w sweep yes
      finish_sweep_terminal 0
      assert_branch_missing "$root/repo" dirty
      [[ ! -d "$root/wt-dirty" ]] || fail "explicit force selection should remove dirty worktree"
    fi
    assert_branch_exists "$root/repo" feature
    assert_branch_exists "$root/repo" release/keep
    assert_branch_exists "$root/repo" locked
    assert_remote_branch_exists "$root" feature
  done
  pass "interactive force is explicit and never overrides locks or branch protection"
}

function test_interactive_rechecks_local_state() {
  local root change
  for change in commit worktree dirty lock protect current base; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    if [[ "$change" != current && "$change" != worktree ]]; then
      git -C "$root/repo" worktree add "$root/wt-feature" feature >/dev/null 2>&1
    fi
    local -a extra=()
    [[ "$change" == commit || "$change" == worktree ]] && extra+=(--force)
    start_sweep_terminal "$root/repo" gitsweep -i --no-fetch "${extra[@]}"
    expect_sweep_output 'Selection ('
    zpty -w sweep 1
    expect_sweep_output 'Type yes to continue [no]: '
    case "$change" in
      commit) git -C "$root/wt-feature" commit --allow-empty -m 'new work while choosing' >/dev/null ;;
      worktree) git -C "$root/repo" worktree add "$root/wt-feature" feature >/dev/null 2>&1 ;;
      dirty) print unsaved > "$root/wt-feature/untracked.txt" ;;
      lock) git -C "$root/repo" worktree lock "$root/wt-feature" ;;
      protect) git -C "$root/repo" config gitsweep.protect feature ;;
      current) git -C "$root/repo" switch feature >/dev/null 2>&1 ;;
      base) git -C "$root/repo" update-ref refs/remotes/origin/main "$(git -C "$root/repo" rev-parse 'main^')" ;;
    esac
    zpty -w sweep yes
    finish_sweep_terminal 1
    assert_branch_exists "$root/repo" feature
    pass "interactive sweep preserves local branch after $change changes during selection"
  done
}

function test_interactive_remote_lease() {
  local root sweep
  for sweep in gitsweep-remote-merged gitsweep-remote-all; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    start_sweep_terminal "$root/repo" "$sweep" -i --no-fetch
    expect_sweep_output 'Selection ('
    zpty -w sweep 1
    expect_sweep_output 'Type yes to continue [no]: '
    (
      cd "$root/seed"
      git switch feature >/dev/null 2>&1
      git commit --allow-empty -m 'new remote work while choosing' >/dev/null
      git push origin feature >/dev/null 2>&1
    )
    git -C "$root/repo" fetch origin >/dev/null 2>&1
    zpty -w sweep yes
    finish_sweep_terminal 1
    assert_remote_branch_exists "$root" feature
    pass "$sweep retains its original remote lease throughout interactive selection"
  done
}

function test_interactive_full_rechecks_primary_and_protection() {
  local root change
  for change in primary protection; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    start_sweep_terminal "$root/repo" gitsweep-all -i --no-fetch
    expect_sweep_output 'Selection ('
    zpty -w sweep all
    expect_sweep_output 'Type yes to continue [no]: '
    if [[ "$change" == primary ]]; then
      git -C "$root/repo" switch feature >/dev/null 2>&1
    else
      git -C "$root/repo" config gitsweep.protect feature
    fi
    zpty -w sweep yes
    finish_sweep_terminal 1
    assert_branch_exists "$root/repo" feature
    assert_remote_branch_exists "$root" feature
    pass "combined interactive sweep honors $change changes before any deletion"
  done
}

function test_interactive_remote_reloads_protection() {
  local root mode
  for mode in delete preview; do
    root=$(make_temp_dir)
    setup_repo "$root"
    merge_feature_to_main "$root/repo"
    local -a extra=()
    [[ "$mode" == preview ]] && extra+=(--dry-run)
    start_sweep_terminal "$root/repo" gitsweep-remote-merged -i --no-fetch "${extra[@]}"
    expect_sweep_output 'Selection ('
    git -C "$root/repo" config gitsweep.protect feature
    zpty -w sweep 1
    if [[ "$mode" == delete ]]; then
      expect_sweep_output 'Type yes to continue [no]: '
      zpty -w sweep yes
    fi
    finish_sweep_terminal 1
    assert_remote_branch_exists "$root" feature
    [[ "$PTY_LOG" != *'Would delete remote branch: origin/feature'* ]] \
      || fail "newly protected remote branch must not be previewed for deletion"
  done
  pass "remote selection reloads protection before deletion or preview"
}

function test_interactive_keeps_unselected_worktree_metadata() {
  local root listing
  root=$(make_temp_dir)
  setup_repo "$root"
  merge_feature_to_main "$root/repo"
  git -C "$root/repo" worktree add --detach "$root/stale" main >/dev/null 2>&1
  rm -rf -- "$root/stale"
  start_sweep_terminal "$root/repo" gitsweep -i --no-fetch
  expect_sweep_output 'Selection ('
  zpty -w sweep 1
  expect_sweep_output 'Type yes to continue [no]: '
  zpty -w sweep yes
  finish_sweep_terminal 0
  assert_branch_missing "$root/repo" feature
  listing=$(git -C "$root/repo" worktree list --porcelain)
  [[ "$listing" == *"$root/stale"* ]] || fail "interactive cleanup must not prune unrelated worktree records"
  pass "interactive cleanup preserves unselected stale worktree metadata"
}

test_interactive_requires_terminal_before_fetch
test_interactive_selects_local_worktree_pair
test_interactive_cancellation_and_validation
test_interactive_eof
test_interactive_interrupt
test_interactive_unmerged_requires_force
test_interactive_dry_run
test_interactive_all_selects_scopes_independently
test_interactive_safety_and_force
test_interactive_rechecks_local_state
test_interactive_remote_lease
test_interactive_full_rechecks_primary_and_protection
test_interactive_remote_reloads_protection
test_interactive_keeps_unselected_worktree_metadata
