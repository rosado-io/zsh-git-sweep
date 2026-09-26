# zsh-git-sweep
# Oh My Zsh plugin to clean up merged, gone, and stale branches with worktrees.

function _zsh_git_sweep_usage() {
  cat <<'EOF'
Usage: gitsweep [options]

Options:
  -b, --base <ref>       Compare merged branches against this base ref.
  -f, --force            Remove unmerged/stale candidates too.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p before scanning.
      --stale-days <n>   Include branches older than n days as candidates.
  -h, --help             Show this help message.
EOF
}

function _zsh_git_sweep_remote_merged_usage() {
  cat <<'EOF'
Usage: gitsweep-remote-merged [options]

Options:
  -r, --remote <name>    Delete branches from this remote.
  -b, --base <ref>       Compare merged remote branches against this base ref.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p <remote> before scanning.
  -h, --help             Show this help message.
EOF
}

function _zsh_git_sweep_remote_all_usage() {
  cat <<'EOF'
Usage: gitsweep-remote-all [options]

Options:
  -r, --remote <name>    Delete branches from this remote.
  -b, --base <ref>       Keep this base ref as the primary branch.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p <remote> before scanning.
  -h, --help             Show this help message.
EOF
}

function _zsh_git_sweep_all_usage() {
  cat <<'EOF'
Usage: gitsweep-all [options]

Delete every local and remote branch except the primary branch.
Run it while the primary branch is checked out.

Options:
  -r, --remote <name>    Delete branches from this remote.
  -b, --base <ref>       Keep this base ref as the primary branch.
  -f, --force            Also remove unmerged local branches and dirty worktrees.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p <remote> before scanning.
  -h, --help             Show this help message.
EOF
}

function _zsh_git_sweep_default_base() {
  local origin_head
  origin_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)

  if [[ -n "$origin_head" ]]; then
    echo "$origin_head"
    return 0
  fi

  local ref
  for ref in origin/main origin/master origin/trunk origin/develop main master trunk develop dev; do
    if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      echo "$ref"
      return 0
    fi
  done

  if git rev-parse --verify --quiet HEAD >/dev/null; then
    echo "HEAD"
    return 0
  fi

  return 1
}

function _zsh_git_sweep_default_remote() {
  if git remote get-url origin >/dev/null 2>&1; then
    echo "origin"
    return 0
  fi

  local remote
  remote=$(git remote | sed -n '1p')
  if [[ -n "$remote" ]]; then
    echo "$remote"
    return 0
  fi

  return 1
}

function _zsh_git_sweep_default_remote_base() {
  local remote=$1
  local remote_head
  remote_head=$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)

  if [[ -n "$remote_head" ]]; then
    echo "$remote_head"
    return 0
  fi

  local branch ref
  for branch in main master trunk develop dev; do
    ref="$remote/$branch"
    if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      echo "$ref"
      return 0
    fi
  done

  return 1
}

function _zsh_git_sweep_branch_name_from_ref() {
  local ref=$1
  local remote=${2:-}
  local branch=$ref

  branch=${branch#refs/heads/}
  branch=${branch#refs/remotes/}

  if [[ -n "$remote" ]]; then
    branch=${branch#${remote}/}
  elif [[ "$branch" == */* ]]; then
    branch=${branch#*/}
  fi

  echo "$branch"
}

function _zsh_git_sweep_is_protected_branch() {
  local branch=$1
  shift

  local protected
  for protected in "$@"; do
    if [[ "$branch" == "$protected" ]]; then
      return 0
    fi
  done

  return 1
}

# Prints the branch names on a remote, skipping its HEAD symref and the primary branch.
function _zsh_git_sweep_remote_branches() {
  local remote=$1
  local primary_branch=$2

  local ref symref branch
  while IFS=$'\t' read -r ref symref; do
    [[ -z "$ref" ]] && continue
    [[ -n "$symref" ]] && continue

    branch=${ref#refs/remotes/${remote}/}
    [[ "$branch" == "HEAD" ]] && continue
    [[ "$branch" == "$primary_branch" ]] && continue

    echo "$branch"
  done < <(git for-each-ref --format='%(refname)%09%(symref)' "refs/remotes/$remote")
}

# Removes a local branch and the worktree that has it checked out, if any.
# Returns nonzero when the branch is left in place.
function _zsh_git_sweep_remove_local_branch() {
  local branch=$1
  local force=$2
  local dry_run=$3
  local force_hint=$4

  local worktree_path
  worktree_path=$(git worktree list --porcelain | awk -v br="$branch" '
    /^worktree / {
      path = $0
      sub(/^worktree /, "", path)
    }
    /^branch refs\/heads\// {
      sub(/^branch refs\/heads\//, "")
      if ($0 == br && path != "") { print path; exit }
    }
  ')

  if [[ -n "$worktree_path" ]]; then
    if (( ! force )) && [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
      echo "   ⚠️  Worktree has local changes; skipping branch."
      echo "      Use $force_hint to remove it anyway."
      return 1
    fi

    if (( dry_run )); then
      echo "   📦 Would remove worktree at $worktree_path"
    else
      echo "   📦 Removing worktree at $worktree_path"
      if (( force )); then
        if ! git worktree remove -f "$worktree_path"; then
          echo "   ⚠️  Could not remove worktree at $worktree_path — skipping branch."
          return 1
        fi
      else
        if ! git worktree remove "$worktree_path"; then
          echo "   ⚠️  Could not remove worktree at $worktree_path; skipping branch."
          echo "      The worktree may contain local changes."
          return 1
        fi
      fi
    fi
  fi

  if (( dry_run )); then
    echo "   🗑️  Would delete branch: $branch"
    return 0
  fi

  # Callers only pass branches proven merged into the base ref unless --force was used.
  # Use -D so deletion works even when the current HEAD is not the base branch.
  echo "   🗑️  Deleting branch: $branch"
  if ! git branch -D -- "$branch"; then
    echo "   ⚠️  Could not delete branch: $branch."
    return 1
  fi
}

function _zsh_git_sweep_remote_sweep() {
  emulate -L zsh

  local mode=$1
  local usage_func=$2
  shift 2

  local base_ref=""
  local dry_run=0
  local fetch=1
  local remote=""

  while (( $# > 0 )); do
    case "$1" in
      -r|--remote)
        if (( $# < 2 )); then
          echo "🚨 Missing value for $1"
          $usage_func
          return 2
        fi
        remote=$2
        shift
        ;;
      -b|--base)
        if (( $# < 2 )); then
          echo "🚨 Missing value for $1"
          $usage_func
          return 2
        fi
        base_ref=$2
        shift
        ;;
      -n|--dry-run)
        dry_run=1
        ;;
      --no-fetch)
        fetch=0
        ;;
      -h|--help)
        $usage_func
        return 0
        ;;
      *)
        echo "🚨 Unknown option: $1"
        $usage_func
        return 2
        ;;
    esac
    shift
  done

  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "🚨 Not a Git repository."
    return 1
  fi

  if [[ -z "$remote" ]]; then
    if ! remote=$(_zsh_git_sweep_default_remote); then
      echo "❌ Could not determine a remote."
      return 1
    fi
  fi

  if ! git remote get-url "$remote" >/dev/null 2>&1; then
    echo "❌ Remote not found: $remote"
    return 1
  fi

  echo "🧹 Starting remote git sweep..."
  if (( dry_run )); then
    echo "🔎 Dry run mode: no remote branches or Git refs will be changed."
  fi

  if (( fetch )); then
    if (( dry_run )); then
      echo "🌐 Checking remote branches on $remote (dry run)..."
      if ! git fetch --dry-run -p "$remote"; then
        echo "❌ Failed to fetch from remote: $remote"
        return 1
      fi
    else
      echo "🌐 Fetching and pruning $remote..."
      if ! git fetch -p "$remote"; then
        echo "❌ Failed to fetch from remote: $remote"
        return 1
      fi
    fi
  else
    echo "⏭️  Skipping fetch (--no-fetch)."
  fi

  if [[ -z "$base_ref" ]]; then
    if ! base_ref=$(_zsh_git_sweep_default_remote_base "$remote"); then
      echo "❌ Could not determine the primary branch for $remote."
      return 1
    fi
  fi

  if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
    echo "❌ Base ref not found: $base_ref"
    return 1
  fi

  local base_branch
  base_branch=$(_zsh_git_sweep_branch_name_from_ref "$base_ref" "$remote")

  echo "🧭 Using remote: $remote"
  echo "🧭 Using primary/base ref: $base_ref"

  local -a candidates
  local -A candidate_reasons
  local branch reason
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue

    if [[ "$mode" == "merged" ]]; then
      if git merge-base --is-ancestor "refs/remotes/$remote/$branch" "$base_ref"; then
        reason="merged into $base_ref"
      else
        continue
      fi
    else
      reason="not primary branch"
    fi

    candidates+=("$branch")
    candidate_reasons[$branch]=$reason
  done < <(_zsh_git_sweep_remote_branches "$remote" "$base_branch")

  if (( ${#candidates} == 0 )); then
    echo "✨ All clean! No remote branch candidates found."
    return 0
  fi

  echo "🗑️  Found ${#candidates} remote branch(es) to delete: ${(j:, :)candidates}"

  local deleted_count=0
  for branch in "${candidates[@]}"; do
    echo "🔍 Checking remote branch: $remote/$branch (${candidate_reasons[$branch]})"

    if (( dry_run )); then
      echo "   🗑️  Would delete remote branch: $remote/$branch"
      continue
    fi

    echo "   🗑️  Deleting remote branch: $remote/$branch"
    if git push "$remote" --delete "$branch"; then
      deleted_count=$(( deleted_count + 1 ))
    else
      echo "   ⚠️  Could not delete remote branch: $remote/$branch."
    fi
  done

  if (( dry_run )); then
    echo "✅ Dry run complete!"
    return 0
  fi

  if (( deleted_count > 0 )); then
    echo "🌐 Pruning deleted remote-tracking refs from $remote..."
    if ! git fetch -p "$remote"; then
      echo "⚠️  Deleted remote branches, but could not prune local remote-tracking refs."
    fi
  fi

  echo "✅ Remote git sweep complete!"
}

function gitsweep() {
  emulate -L zsh

  local base_ref=""
  local dry_run=0
  local force=0
  local fetch=1
  local stale_days=""

  while (( $# > 0 )); do
    case "$1" in
      -b|--base)
        if (( $# < 2 )); then
          echo "🚨 Missing value for $1"
          _zsh_git_sweep_usage
          return 2
        fi
        base_ref=$2
        shift
        ;;
      -f|--force)
        force=1
        ;;
      -n|--dry-run)
        dry_run=1
        ;;
      --no-fetch)
        fetch=0
        ;;
      --stale-days)
        if (( $# < 2 )); then
          echo "🚨 Missing value for $1"
          _zsh_git_sweep_usage
          return 2
        fi

        if [[ "$2" != <-> ]] || (( $2 < 1 )); then
          echo "🚨 --stale-days must be a positive integer."
          return 2
        fi

        stale_days=$2
        shift
        ;;
      -h|--help)
        _zsh_git_sweep_usage
        return 0
        ;;
      *)
        echo "🚨 Unknown option: $1"
        _zsh_git_sweep_usage
        return 2
        ;;
    esac
    shift
  done

  # Ensure we're inside a Git repository.
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "🚨 Not a Git repository."
    return 1
  fi

  echo "🧹 Starting git sweep..."
  if (( dry_run )); then
    echo "🔎 Dry run mode: no branches, worktrees, or Git refs will be changed."
  fi

  local -A dry_run_pruned_refs

  if (( fetch )); then
    if (( dry_run )); then
      echo "🌐 Checking remote tracking branches (dry run)..."

      local fetch_output
      if ! fetch_output=$(git fetch --dry-run -p 2>&1); then
        [[ -n "$fetch_output" ]] && echo "$fetch_output"
        echo "❌ Failed to fetch from remote."
        return 1
      fi

      local pruned_ref
      while IFS= read -r pruned_ref; do
        [[ -n "$pruned_ref" ]] && dry_run_pruned_refs[$pruned_ref]=1
      done < <(printf '%s\n' "$fetch_output" | awk '/\[deleted\]/ && / -> / { sub(/^.* -> /, ""); print }')
    else
      echo "🌐 Fetching and pruning remote tracking branches..."
      if ! git fetch -p; then
        echo "❌ Failed to fetch from remote."
        return 1
      fi
    fi
  else
    echo "⏭️  Skipping fetch (--no-fetch)."
  fi

  if [[ -z "$base_ref" ]]; then
    if ! base_ref=$(_zsh_git_sweep_default_base); then
      echo "❌ Could not determine a base branch."
      return 1
    fi
  fi

  if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
    echo "❌ Base ref not found: $base_ref"
    return 1
  fi

  echo "🧭 Using base ref: $base_ref"

  local branch upstream track
  local current_branch
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)

  local base_branch=$base_ref
  base_branch=${base_branch#refs/heads/}
  base_branch=${base_branch#refs/remotes/}
  if [[ "$base_branch" == */* && "$base_ref" != refs/heads/* ]]; then
    base_branch=${base_branch#*/}
  fi

  local -a protected_branches
  protected_branches=(main master trunk develop dev "$base_branch")

  local -A candidate_reasons merged_candidates stale_candidates
  local -a candidates

  local reason
  while IFS=$'\t' read -r branch upstream track; do
    [[ "$branch" == "$current_branch" ]] && continue
    _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue

    if [[ "$track" == "[gone]" ]] || (( dry_run && ${+dry_run_pruned_refs[$upstream]} )); then
      reason="upstream gone"
      if (( ! ${+candidate_reasons[$branch]} )); then
        candidates+=("$branch")
        candidate_reasons[$branch]=$reason
      else
        candidate_reasons[$branch]="${candidate_reasons[$branch]}, $reason"
      fi
    fi
  done < <(git for-each-ref --format='%(refname:short)%09%(upstream:short)%09%(upstream:track)' refs/heads)

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    [[ "$branch" == "$current_branch" ]] && continue
    _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue

    if git merge-base --is-ancestor "refs/heads/$branch" "$base_ref"; then
      reason="merged into $base_ref"
      merged_candidates[$branch]=1
      if (( ! ${+candidate_reasons[$branch]} )); then
        candidates+=("$branch")
        candidate_reasons[$branch]=$reason
      else
        candidate_reasons[$branch]="${candidate_reasons[$branch]}, $reason"
      fi
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)

  if [[ -n "$stale_days" ]]; then
    local now stale_seconds commit_ts
    now=$(date +%s)
    stale_seconds=$(( stale_days * 86400 ))

    while IFS=$'\t' read -r branch commit_ts; do
      [[ -z "$branch" ]] && continue
      [[ "$branch" == "$current_branch" ]] && continue
      _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue

      if (( now - commit_ts >= stale_seconds )); then
        reason="older than ${stale_days}d"
        stale_candidates[$branch]=1
        if (( ! ${+candidate_reasons[$branch]} )); then
          candidates+=("$branch")
          candidate_reasons[$branch]=$reason
        else
          candidate_reasons[$branch]="${candidate_reasons[$branch]}, $reason"
        fi
      fi
    done < <(git for-each-ref --format='%(refname:short)%09%(committerdate:unix)' refs/heads)
  fi

  if (( ${#candidates} == 0 )); then
    echo "✨ All clean! No sweep candidates found."
    return 0
  fi

  echo "🗑️  Found ${#candidates} branch(es) to inspect: ${(j:, :)candidates}"

  local b
  for b in "${candidates[@]}"; do
    echo "🔍 Checking branch: $b (${candidate_reasons[$b]})"

    if [[ "$b" == "$current_branch" ]]; then
      echo "   ⚠️  Skipping current branch."
      continue
    fi

    if _zsh_git_sweep_is_protected_branch "$b" "${protected_branches[@]}"; then
      echo "   ⚠️  Skipping protected branch."
      continue
    fi

    if (( ! force )) && (( ! ${+merged_candidates[$b]} )); then
      echo "   ⚠️  Branch is not merged into $base_ref; skipping."
      if (( ${+stale_candidates[$b]} )); then
        echo "      Review it, then use gitsweep --force --stale-days $stale_days to remove it."
      else
        echo "      Use gitsweep --force to remove it anyway."
      fi
      continue
    fi

    _zsh_git_sweep_remove_local_branch "$b" "$force" "$dry_run" "gitsweep --force"
  done

  if (( dry_run )); then
    echo "🧼 Would run git worktree prune"
    echo "✅ Dry run complete!"
    return 0
  fi

  echo "🧼 Running git worktree prune..."
  git worktree prune
  echo "✅ Git sweep complete!"
}

function gitsweep-remote-merged() {
  _zsh_git_sweep_remote_sweep merged _zsh_git_sweep_remote_merged_usage "$@"
}

function gitsweep-remote-all() {
  _zsh_git_sweep_remote_sweep all _zsh_git_sweep_remote_all_usage "$@"
}

function gitsweep-all() {
  emulate -L zsh

  local base_ref=""
  local dry_run=0
  local force=0
  local fetch=1
  local remote=""

  while (( $# > 0 )); do
    case "$1" in
      -r|--remote)
        if (( $# < 2 )); then
          echo "🚨 Missing value for $1"
          _zsh_git_sweep_all_usage
          return 2
        fi
        remote=$2
        shift
        ;;
      -b|--base)
        if (( $# < 2 )); then
          echo "🚨 Missing value for $1"
          _zsh_git_sweep_all_usage
          return 2
        fi
        base_ref=$2
        shift
        ;;
      -f|--force)
        force=1
        ;;
      -n|--dry-run)
        dry_run=1
        ;;
      --no-fetch)
        fetch=0
        ;;
      -h|--help)
        _zsh_git_sweep_all_usage
        return 0
        ;;
      *)
        echo "🚨 Unknown option: $1"
        _zsh_git_sweep_all_usage
        return 2
        ;;
    esac
    shift
  done

  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "🚨 Not a Git repository."
    return 1
  fi

  if [[ -z "$remote" ]]; then
    if ! remote=$(_zsh_git_sweep_default_remote); then
      echo "❌ Could not determine a remote."
      return 1
    fi
  fi

  if ! git remote get-url "$remote" >/dev/null 2>&1; then
    echo "❌ Remote not found: $remote"
    return 1
  fi

  echo "🧹 Starting full git sweep (local and remote)..."
  if (( dry_run )); then
    echo "🔎 Dry run mode: no branches, worktrees, remote branches, or Git refs will be changed."
  fi

  if (( fetch )); then
    if (( dry_run )); then
      echo "🌐 Checking remote branches on $remote (dry run)..."
      if ! git fetch --dry-run -p "$remote"; then
        echo "❌ Failed to fetch from remote: $remote"
        return 1
      fi
    else
      echo "🌐 Fetching and pruning $remote..."
      if ! git fetch -p "$remote"; then
        echo "❌ Failed to fetch from remote: $remote"
        return 1
      fi
    fi
  else
    echo "⏭️  Skipping fetch (--no-fetch)."
  fi

  if [[ -z "$base_ref" ]]; then
    if ! base_ref=$(_zsh_git_sweep_default_remote_base "$remote"); then
      echo "❌ Could not determine the primary branch for $remote."
      return 1
    fi
  fi

  if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
    echo "❌ Base ref not found: $base_ref"
    return 1
  fi

  local base_branch
  base_branch=$(_zsh_git_sweep_branch_name_from_ref "$base_ref" "$remote")

  echo "🧭 Using remote: $remote"
  echo "🧭 Using primary/base ref: $base_ref"

  # Everything except the primary branch is deleted, so require it to be checked out.
  local current_branch
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
  if [[ "$current_branch" != "$base_branch" ]]; then
    echo "🚨 gitsweep-all must run from the primary branch: $base_branch"
    if [[ -n "$current_branch" ]]; then
      echo "   You are on: $current_branch"
    else
      echo "   You are on a detached HEAD."
    fi
    echo "   Switch first with: git switch $base_branch"
    return 1
  fi

  local -a remote_candidates local_candidates left_behind
  local branch
  while IFS= read -r branch; do
    [[ -n "$branch" ]] && remote_candidates+=("$branch")
  done < <(_zsh_git_sweep_remote_branches "$remote" "$base_branch")

  while IFS= read -r branch; do
    [[ -z "$branch" || "$branch" == "$base_branch" ]] && continue
    local_candidates+=("$branch")
  done < <(git for-each-ref --format='%(refname:lstrip=2)' refs/heads)

  if (( ${#remote_candidates} == 0 && ${#local_candidates} == 0 )); then
    echo "✨ All clean! Only $base_branch remains locally and on $remote."
    return 0
  fi

  echo "🛡️  Keeping primary branch: $base_branch (local) and $remote/$base_branch"
  if (( ${#remote_candidates} > 0 )); then
    echo "🗑️  Found ${#remote_candidates} remote branch(es) on $remote to delete: ${(j:, :)remote_candidates}"
  else
    echo "🗑️  Found 0 remote branch(es) on $remote to delete."
  fi
  if (( ${#local_candidates} > 0 )); then
    echo "🗑️  Found ${#local_candidates} local branch(es) to delete: ${(j:, :)local_candidates}"
  else
    echo "🗑️  Found 0 local branch(es) to delete."
  fi
  if (( force )); then
    echo "⚠️  --force: unmerged local commits and dirty worktree changes will be deleted."
  fi

  local remote_deleted_count=0
  for branch in "${remote_candidates[@]}"; do
    echo "🔍 Checking remote branch: $remote/$branch (not primary branch)"

    if (( dry_run )); then
      echo "   🗑️  Would delete remote branch: $remote/$branch"
      continue
    fi

    echo "   🗑️  Deleting remote branch: $remote/$branch"
    if git push "$remote" --delete "$branch"; then
      remote_deleted_count=$(( remote_deleted_count + 1 ))
    else
      echo "   ⚠️  Could not delete remote branch: $remote/$branch."
      left_behind+=("$remote/$branch")
    fi
  done

  if (( remote_deleted_count > 0 )); then
    echo "🌐 Pruning deleted remote-tracking refs from $remote..."
    if ! git fetch -p "$remote"; then
      echo "⚠️  Deleted remote branches, but could not prune local remote-tracking refs."
    fi
  fi

  for branch in "${local_candidates[@]}"; do
    echo "🔍 Checking branch: $branch (not primary branch)"

    if (( ! force )) && ! git merge-base --is-ancestor "refs/heads/$branch" "$base_ref"; then
      echo "   ⚠️  Branch is not merged into $base_ref; skipping."
      echo "      Review it, then use gitsweep-all --force to remove it."
      left_behind+=("$branch")
      continue
    fi

    if ! _zsh_git_sweep_remove_local_branch "$branch" "$force" "$dry_run" "gitsweep-all --force"; then
      left_behind+=("$branch")
    fi
  done

  if (( dry_run )); then
    echo "🧼 Would run git worktree prune"
    if (( ${#left_behind} > 0 )); then
      echo "⚠️  ${#left_behind} branch(es) would be left behind: ${(j:, :)left_behind}"
    fi
    echo "✅ Dry run complete!"
    return 0
  fi

  echo "🧼 Running git worktree prune..."
  git worktree prune

  if (( ${#left_behind} > 0 )); then
    echo "❌ Full git sweep incomplete. ${#left_behind} branch(es) left behind: ${(j:, :)left_behind}"
    return 1
  fi

  echo "✅ Full git sweep complete! Only $base_branch remains locally and on $remote."
}

# Optional alias.
alias gsweep='gitsweep'
alias gsweep-rm='gitsweep-remote-merged'
alias gsweep-ra='gitsweep-remote-all'
alias gsweep-a='gitsweep-all'
