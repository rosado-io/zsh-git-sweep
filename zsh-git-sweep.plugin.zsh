# zsh-git-sweep
# Oh My Zsh plugin to clean up orphaned local branches and their worktrees.

function gitsweep() {
  # Ensure we're inside a Git repository.
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "🚨 Not a Git repository."
    return 1
  fi

  echo "🧹 Starting git sweep..."

  # 1. Fetch and prune stale remote-tracking references.
  echo "🌐 Fetching and pruning remote tracking branches..."
  if ! git fetch -p; then
    echo "❌ Failed to fetch from remote."
    return 1
  fi

  # 2. Identify local branches whose upstream is marked as [gone].
  local branch track
  local -a gone_branches

  while IFS=$'\t' read -r branch track; do
    if [[ "$track" == "[gone]" ]]; then
      gone_branches+=("$branch")
    fi
  done < <(git for-each-ref --format='%(refname:short)%09%(upstream:track)' refs/heads)

  # 8. Edge case: nothing to clean.
  if (( ${#gone_branches} == 0 )); then
    echo "✨ All clean! No orphaned branches found."
    return 0
  fi

  echo "🗑️  Found ${#gone_branches} orphaned branch(es): ${(j:, :)gone_branches}"

  # 3. Iterate through orphaned branches.
  local b worktree_path
  for b in "$gone_branches[@]"; do
    echo "🔍 Checking branch: $b"

    # 4. Check if the branch has an active Git worktree.
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

    # 5. Remove the worktree if one exists.
    if [[ -n "$worktree_path" ]]; then
      echo "   📦 Removing worktree at $worktree_path"
      if ! git worktree remove -f "$worktree_path"; then
        echo "   ⚠️  Could not remove worktree at $worktree_path — skipping branch."
        continue
      fi
    fi

    # 6. Safely delete the local branch.
    echo "   🗑️  Deleting branch: $b"
    if ! git branch -d "$b"; then
      echo "   ⚠️  Could not delete branch: $b (it may be unmerged)."
    fi
  done

  # 7. General worktree cleanup.
  echo "🧼 Running git worktree prune..."
  git worktree prune

  echo "✅ Git sweep complete!"
}

# Optional alias.
alias gsweep='gitsweep'
