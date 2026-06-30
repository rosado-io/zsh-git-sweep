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

  if (( fetch )); then
    echo "🌐 Fetching and pruning remote tracking branches..."
    if ! git fetch -p; then
      echo "❌ Failed to fetch from remote."
      return 1
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

  local branch track
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
  while IFS=$'\t' read -r branch track; do
    [[ "$branch" == "$current_branch" ]] && continue
    _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue

    if [[ "$track" == "[gone]" ]]; then
      reason="upstream gone"
      if (( ! ${+candidate_reasons[$branch]} )); then
        candidates+=("$branch")
        candidate_reasons[$branch]=$reason
      else
        candidate_reasons[$branch]="${candidate_reasons[$branch]}, $reason"
      fi
    fi
  done < <(git for-each-ref --format='%(refname:short)%09%(upstream:track)' refs/heads)

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

  local b worktree_path
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

    worktree_path=$(git worktree list --porcelain | awk -v br="$b" '
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
        echo "      Use gitsweep --force to remove it anyway."
        continue
      fi

      if (( dry_run )); then
        echo "   📦 Would remove worktree at $worktree_path"
      else
        echo "   📦 Removing worktree at $worktree_path"
        if (( force )); then
          if ! git worktree remove -f "$worktree_path"; then
            echo "   ⚠️  Could not remove worktree at $worktree_path — skipping branch."
            continue
          fi
        else
          if ! git worktree remove "$worktree_path"; then
            echo "   ⚠️  Could not remove worktree at $worktree_path; skipping branch."
            echo "      The worktree may contain local changes."
            continue
          fi
        fi
      fi
    fi

    if (( dry_run )); then
      echo "   🗑️  Would delete branch: $b"
      continue
    fi

    # The branch was already proven merged into the base ref unless --force was used.
    # Use -D so deletion works even when the current HEAD is not the base branch.
    echo "   🗑️  Deleting branch: $b"
    if ! git branch -D -- "$b"; then
      echo "   ⚠️  Could not delete branch: $b."
    fi
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

# Optional alias.
alias gsweep='gitsweep'
