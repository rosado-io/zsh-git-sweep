# zsh-git-sweep
# Oh My Zsh plugin to clean up merged, gone, and stale branches with worktrees.

function _zsh_git_sweep_usage() {
  cat <<'EOF'
Usage: gitsweep [options]

Options:
  -b, --base <ref>       Compare merged branches against this base ref.
  -f, --force            Remove unmerged/stale candidates too.
  -n, --dry-run          Show what would be removed without changing anything.
  -i, --interactive      Select candidates in a terminal before cleanup.
      --protect <glob>  Keep matching branch names (repeatable; also Git config).
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
  -i, --interactive      Select candidates in a terminal before cleanup.
      --protect <glob>  Keep matching branch names (repeatable; also Git config).
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
  -i, --interactive      Select candidates in a terminal before cleanup.
      --protect <glob>  Keep matching branch names (repeatable; also Git config).
      --no-fetch         Skip git fetch -p <remote> before scanning.
  -h, --help             Show this help message.
EOF
}

function _zsh_git_sweep_all_usage() {
  cat <<'EOF'
Usage: gitsweep-all [options]

Delete every local and remote branch except primary and protected branches.
Run it while the primary branch is checked out.

Options:
  -r, --remote <name>    Delete branches from this remote.
  -b, --base <ref>       Keep this base ref as the primary branch.
  -f, --force            Also remove unmerged local branches and dirty worktrees.
  -n, --dry-run          Show what would be removed without changing anything.
  -i, --interactive      Select candidates in a terminal before cleanup.
      --protect <glob>  Keep matching branch names (repeatable; also Git config).
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
  local full_ref
  full_ref=$(git rev-parse --symbolic-full-name --verify --end-of-options "$ref") || return 1
  case "$full_ref" in
    refs/heads/*) print -r -- "${full_ref#refs/heads/}" ;;
    refs/remotes/*)
      if [[ -n "$remote" ]]; then
        [[ "$full_ref" == "refs/remotes/$remote/"* ]] || return 1
        print -r -- "${full_ref#refs/remotes/$remote/}"
      else
        # Remote names can themselves contain slashes. Use the longest matching
        # configured namespace so release/v1 is never mistaken for v1.
        local candidate matched_remote=""
        while IFS= read -r candidate; do
          if [[ "$full_ref" == "refs/remotes/$candidate/"* ]] &&
              (( ${#candidate} > ${#matched_remote} )); then
            matched_remote=$candidate
          fi
        done < <(git remote)
        [[ -n "$matched_remote" ]] || return 1
        print -r -- "${full_ref#refs/remotes/$matched_remote/}"
      fi
      ;;
    *) return 1 ;;
  esac
}

# The calling command owns protect_patterns (zsh's dynamic local scope).
# CLI and Git configuration are additive; --force never overrides protection.
function _zsh_git_sweep_load_protection() {
  local configured pattern result=0
  configured=$(git config --null --get-all gitsweep.protect) || result=$?
  if (( result > 1 )); then
    echo "❌ Could not read gitsweep.protect configuration."
    return 2
  fi
  if (( result == 0 )); then
    while IFS= read -r -d '' pattern; do
      protect_patterns+=("$pattern")
    done < <(printf '%s' "$configured")
  fi
  for pattern in "${protect_patterns[@]}"; do
    result=0
    ( [[ "" == ${~pattern} ]] ) 2>/dev/null || result=$?
    if [[ -z "$pattern" ]] || (( result > 1 )); then
      print -r -- "🚨 Invalid protection pattern: $pattern"
      return 2
    fi
  done
  if (( ${#protect_patterns} > 0 )); then
    print -r -- "🛡️  Protected patterns: ${(j:, :)protect_patterns}"
  fi
  return 0
}

function _zsh_git_sweep_matches_protection() {
  local branch=$1 pattern
  for pattern in "${protect_patterns[@]}"; do
    [[ "$branch" == ${~pattern} ]] && return 0
  done
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

# Prints branch names and scanned object IDs, skipping symbolic and protected refs.
function _zsh_git_sweep_remote_branches() {
  local remote=$1
  local primary_branch=$2
  local merged_base=${3:-}
  local -a filters
  [[ -n "$merged_base" ]] && filters+=("--merged=$merged_base")

  local ref oid symref branch
  while IFS=$'\t' read -r ref oid symref; do
    [[ -z "$ref" ]] && continue
    [[ -n "$symref" ]] && continue

    branch=${ref#refs/remotes/${remote}/}
    [[ "$branch" == "HEAD" ]] && continue
    [[ "$branch" == "$primary_branch" ]] && continue
    _zsh_git_sweep_matches_protection "$branch" && continue

    printf '%s\t%s\n' "$branch" "$oid"
  done < <(git for-each-ref "${filters[@]}" --format='%(refname)%09%(objectname)%09%(symref)' "refs/remotes/$remote/")
}

function _zsh_git_sweep_delete_remote_branch() {
  local remote=$1 branch=$2 expected_oid=$3
  # An explicit lease also protects against background fetches after the scan.
  git push --force-with-lease="refs/heads/$branch:$expected_oid" -- "$remote" ":refs/heads/$branch"
}

# Inspects the branch's worktree without mutation. The caller owns worktree_path.
function _zsh_git_sweep_inspect_worktree() {
  local branch=$1 force=$2 force_hint=$3
  worktree_path=""
  local record record_path="" record_branch="" locked=0
  local worktree_listing
  if ! worktree_listing=$(git worktree list --porcelain -z); then
    echo "   ⚠️  Could not list worktrees (Git 2.36+ required); skipping branch."
    return 1
  fi
  while IFS= read -r -d '' record; do
    case "$record" in
      'worktree '*) record_path=${record#worktree } ;;
      'branch '*) record_branch=${record#branch refs/heads/} ;;
      locked|locked\ *) locked=1 ;;
      '')
        if [[ "$record_branch" == "$branch" ]]; then
          worktree_path=$record_path
          break
        fi
        record_path="" record_branch="" locked=0
        ;;
    esac
  done < <(printf '%s' "$worktree_listing")

  if [[ -n "$worktree_path" ]]; then
    if (( locked )); then
      echo "   ⚠️  Worktree is locked; skipping branch."
      return 1
    fi
    local worktree_status
    if ! worktree_status=$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree_path" status --porcelain --untracked-files=all --ignore-submodules=none); then
      echo "   ⚠️  Could not inspect worktree; skipping branch."
      return 1
    fi
    if (( ! force )) && [[ -n "$worktree_status" ]]; then
      echo "   ⚠️  Worktree has local changes; skipping branch."
      echo "      Use $force_hint to remove it anyway."
      return 1
    fi
  fi
  return 0
}

# Removes a local branch and its worktree; returns nonzero when it is left in place.
function _zsh_git_sweep_remove_local_branch() {
  local branch=$1 force=$2 dry_run=$3 force_hint=$4
  local worktree_path=""
  _zsh_git_sweep_inspect_worktree "$branch" "$force" "$force_hint" || return 1

  if [[ -n "$worktree_path" ]]; then
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

# The command owns local_choices, remote_choices, selected_local, selected_remote,
# interactive_oids and interactive_paths. Selection is collected before deletion.
function _zsh_git_sweep_choose() {
  local base_ref=$1 force=$2 dry_run=$3 remote=$4
  local IFS=$' \t\n'
  local -a labels kinds branches indexes
  local -A seen
  local branch oid worktree_path="" label item answer token count number valid

  for branch in "${local_choices[@]}"; do
    if ! oid=$(git rev-parse --verify --quiet "refs/heads/$branch"); then
      print -r -- "   Skipping missing local branch: ${(q)branch}"
      continue
    fi
    if (( ! force )) && ! git merge-base --is-ancestor "$oid" "$base_ref"; then
      print -r -- "   Skipping local branch ${(q)branch}: not merged into $base_ref."
      continue
    fi
    print -r -- "🔍 Inspecting local branch: ${(q)branch}"
    _zsh_git_sweep_inspect_worktree "$branch" "$force" "--force" || continue
    label="local ${(q)branch}"
    if [[ -n "$worktree_path" ]]; then
      label+=" + worktree ${(q)worktree_path}"
    fi
    if (( force )); then
      label+=" [FORCE: unmerged commits and local changes may be lost]"
    else
      label+=" [merged into $base_ref]"
    fi
    labels+=("$label") kinds+=(local) branches+=("$branch")
    interactive_oids[$branch]=$oid
    interactive_paths[$branch]=$worktree_path
  done
  for branch in "${remote_choices[@]}"; do
    labels+=("remote ${(q)remote}/${(q)branch} [delete from remote]")
    kinds+=(remote) branches+=("$branch")
  done

  count=${#labels}
  if (( count == 0 )); then
    echo "✨ No eligible candidates to select."
    return 0
  fi
  echo "Choose what to clean (local entries include their worktree):"
  for (( item=1; item<=count; item++ )); do
    print -r -- "  $item) ${labels[$item]}"
  done

  while true; do
    print -n -- "Selection (numbers separated by spaces or commas, all; Enter/q cancels): "
    if ! IFS= read -r answer; then
      echo "\nCancelled; no selected branches or worktrees were deleted."
      return 130
    fi
    [[ -z "${answer//[[:space:]]/}" || "$answer" == [qQ] ]] && return 0
    indexes=() seen=() valid=1
    if [[ "$answer" == all ]]; then
      for (( item=1; item<=count; item++ )); do indexes+=("$item"); done
    else
      for token in ${=answer//,/ }; do
        # Validate before arithmetic: no expressions, overflows or option input.
        if [[ "$token" != <-> || "$token" != [1-9]* ]] || (( ${#token} > ${#count} )); then
          valid=0
          break
        fi
        number=$(( 10#$token ))
        if (( number > count )); then
          valid=0
          break
        fi
        if (( ! ${+seen[$number]} )); then
          indexes+=("$number")
          seen[$number]=1
        fi
      done
    fi
    if (( valid && ${#indexes} > 0 )); then break; fi
    echo "Invalid selection. Enter listed numbers, all, or q."
  done

  echo "Selected for cleanup:"
  for item in "${indexes[@]}"; do print -r -- "  ${labels[$item]}"; done
  if (( ! dry_run )); then
    print -n -- "Delete these ${#indexes} selected entries? Type yes to continue [no]: "
    if ! IFS= read -r answer; then
      echo "\nCancelled; no selected branches or worktrees were deleted."
      return 130
    fi
    [[ "$answer" == yes ]] || return 0
  fi
  for item in "${indexes[@]}"; do
    if [[ "${kinds[$item]}" == local ]]; then
      selected_local+=("${branches[$item]}")
    else
      selected_remote+=("${branches[$item]}")
    fi
  done
  return 0
}

# User input can take arbitrarily long. Check the approved branch/worktree again
# even with --force; an interactive selection never approves a different tip/path.
function _zsh_git_sweep_revalidate_local() {
  local branch=$1 base_ref=$2 force=$3 oid current worktree_path=""
  oid=$(git rev-parse --verify --quiet "refs/heads/$branch") || return 1
  current=$(git symbolic-ref --quiet HEAD 2>/dev/null)
  if [[ "$current" == "refs/heads/$branch" || "$oid" != "${interactive_oids[$branch]}" ]]; then
    print -r -- "   ⚠️  Local branch changed since selection; skipping: ${(q)branch}"
    return 1
  fi
  if (( ! force )) && ! git merge-base --is-ancestor "$oid" "$base_ref"; then
    print -r -- "   ⚠️  Branch is no longer merged; skipping: ${(q)branch}"
    return 1
  fi
  _zsh_git_sweep_inspect_worktree "$branch" "$force" "--force" || return 1
  if [[ "$worktree_path" != "${interactive_paths[$branch]}" ]]; then
    print -r -- "   ⚠️  Worktree changed since selection; skipping: ${(q)branch}"
    return 1
  fi
  return 0
}

function _zsh_git_sweep_remote_sweep() {
  emulate -L zsh

  local mode=$1
  local usage_func=$2
  shift 2

  local -a protect_patterns local_choices remote_choices selected_local selected_remote
  local -A interactive_oids interactive_paths
  local base_ref=""
  local interactive=0
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
      --protect)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
          echo "🚨 Missing value for --protect"
          return 2
        fi
        protect_patterns+=("$2")
        shift
        ;;
      -i|--interactive)
        interactive=1
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

  if (( interactive )) && [[ ! -t 0 || ! -t 1 ]]; then
    echo "🚨 --interactive requires terminal input and output."
    return 2
  fi

  _zsh_git_sweep_load_protection || return $?

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

  if ! git rev-parse --verify --quiet --end-of-options "$base_ref^{commit}" >/dev/null; then
    echo "❌ Base ref not found: $base_ref"
    return 1
  fi

  local base_branch
  if ! base_branch=$(_zsh_git_sweep_branch_name_from_ref "$base_ref" "$remote") ||
      ! git show-ref --verify --quiet "refs/remotes/$remote/$base_branch"; then
    echo "❌ Base must identify a branch on $remote: $base_ref"
    return 1
  fi

  echo "🧭 Using remote: $remote"
  echo "🧭 Using primary/base ref: $base_ref"

  local -a candidates
  local -A candidate_reasons candidate_oids
  local branch reason oid merged_base=""
  [[ "$mode" == "merged" ]] && merged_base=$base_ref
  while IFS=$'\t' read -r branch oid; do
    [[ -z "$branch" ]] && continue

    if [[ "$mode" == "merged" ]]; then
      reason="merged into $base_ref"
    else
      reason="not primary branch"
    fi

    candidates+=("$branch")
    candidate_reasons[$branch]=$reason
    candidate_oids[$branch]=$oid
  done < <(_zsh_git_sweep_remote_branches "$remote" "$base_branch" "$merged_base")

  if (( ${#candidates} == 0 )); then
    echo "✨ All clean! No remote branch candidates found."
    return 0
  fi

  echo "🗑️  Found ${#candidates} remote branch(es) to delete: ${(j:, :)candidates}"

  if (( interactive )); then
    remote_choices=("${candidates[@]}")
    _zsh_git_sweep_choose "$base_ref" 0 "$dry_run" "$remote" || return $?
    if (( ${#selected_remote} == 0 )); then
      echo "Cancelled; no selected branches or worktrees were deleted."
      return 0
    fi
    candidates=("${selected_remote[@]}")
    _zsh_git_sweep_load_protection || return $?
  fi

  local deleted_count=0 failed_count=0
  for branch in "${candidates[@]}"; do
    echo "🔍 Checking remote branch: $remote/$branch (${candidate_reasons[$branch]})"
    if (( interactive )) && _zsh_git_sweep_matches_protection "$branch"; then
      echo "   ⚠️  Branch is now protected; skipping."
      failed_count=$(( failed_count + 1 ))
      continue
    fi

    if (( dry_run )); then
      echo "   🗑️  Would delete remote branch: $remote/$branch"
      continue
    fi

    echo "   🗑️  Deleting remote branch: $remote/$branch"
    if _zsh_git_sweep_delete_remote_branch "$remote" "$branch" "${candidate_oids[$branch]}"; then
      deleted_count=$(( deleted_count + 1 ))
    else
      echo "   ⚠️  Could not delete remote branch: $remote/$branch (changed or rejected)."
      failed_count=$(( failed_count + 1 ))
    fi
  done

  if (( dry_run )); then
    if (( failed_count > 0 )); then
      echo "❌ Selected dry run incomplete; some selected branches are now protected."
      return 1
    fi
    echo "✅ Dry run complete!"
    return 0
  fi

  if (( deleted_count > 0 && ! interactive )); then
    echo "🌐 Pruning deleted remote-tracking refs from $remote..."
    if ! git fetch -p "$remote"; then
      echo "⚠️  Deleted remote branches, but could not prune local remote-tracking refs."
    fi
  fi

  if (( failed_count > 0 )); then
    echo "❌ Remote git sweep incomplete. $failed_count branch(es) left behind."
    return 1
  fi
  echo "✅ Remote git sweep complete!"
}

function gitsweep() {
  emulate -L zsh

  local -a protect_patterns local_choices remote_choices selected_local selected_remote
  local -A interactive_oids interactive_paths
  local base_ref=""
  local interactive=0
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
      --protect)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
          echo "🚨 Missing value for --protect"
          return 2
        fi
        protect_patterns+=("$2")
        shift
        ;;
      -i|--interactive)
        interactive=1
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

  if (( interactive )) && [[ ! -t 0 || ! -t 1 ]]; then
    echo "🚨 --interactive requires terminal input and output."
    return 2
  fi

  _zsh_git_sweep_load_protection || return $?

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

  if ! git rev-parse --verify --quiet --end-of-options "$base_ref^{commit}" >/dev/null; then
    echo "❌ Base ref not found: $base_ref"
    return 1
  fi

  echo "🧭 Using base ref: $base_ref"

  local branch upstream track
  local current_branch
  current_branch=$(git symbolic-ref --quiet HEAD 2>/dev/null)
  current_branch=${current_branch#refs/heads/}

  local base_branch
  base_branch=$(_zsh_git_sweep_branch_name_from_ref "$base_ref") || base_branch=""

  local -a protected_branches
  protected_branches=(main master trunk develop dev "$base_branch")

  local -A candidate_reasons merged_candidates stale_candidates
  local -a candidates

  local reason
  while IFS=$'\t' read -r branch upstream track; do
    [[ "$branch" == "$current_branch" ]] && continue
    _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue
    _zsh_git_sweep_matches_protection "$branch" && continue

    if [[ "$track" == "[gone]" ]] || (( dry_run && ${+dry_run_pruned_refs[$upstream]} )); then
      reason="upstream gone"
      if (( ! ${+candidate_reasons[$branch]} )); then
        candidates+=("$branch")
        candidate_reasons[$branch]=$reason
      else
        candidate_reasons[$branch]="${candidate_reasons[$branch]}, $reason"
      fi
    fi
  done < <(git for-each-ref --format='%(refname:lstrip=2)%09%(upstream:short)%09%(upstream:track)' refs/heads)

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    [[ "$branch" == "$current_branch" ]] && continue
    _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue
    _zsh_git_sweep_matches_protection "$branch" && continue

    reason="merged into $base_ref"
    merged_candidates[$branch]=1
    if (( ! ${+candidate_reasons[$branch]} )); then
      candidates+=("$branch")
      candidate_reasons[$branch]=$reason
    else
      candidate_reasons[$branch]="${candidate_reasons[$branch]}, $reason"
    fi
  done < <(git for-each-ref --merged="$base_ref" --format='%(refname:lstrip=2)' refs/heads)

  if [[ -n "$stale_days" ]]; then
    local now stale_seconds commit_ts
    now=$(date +%s)
    stale_seconds=$(( stale_days * 86400 ))

    while IFS=$'\t' read -r branch commit_ts; do
      [[ -z "$branch" ]] && continue
      [[ "$branch" == "$current_branch" ]] && continue
      _zsh_git_sweep_is_protected_branch "$branch" "${protected_branches[@]}" && continue
      _zsh_git_sweep_matches_protection "$branch" && continue

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
    done < <(git for-each-ref --format='%(refname:lstrip=2)%09%(committerdate:unix)' refs/heads)
  fi

  if (( ${#candidates} == 0 )); then
    echo "✨ All clean! No sweep candidates found."
    return 0
  fi

  echo "🗑️  Found ${#candidates} branch(es) to inspect: ${(j:, :)candidates}"

  if (( interactive )); then
    local_choices=("${candidates[@]}")
    _zsh_git_sweep_choose "$base_ref" "$force" "$dry_run" "" || return $?
    if (( ${#selected_local} == 0 )); then
      echo "Cancelled; no selected branches or worktrees were deleted."
      return 0
    fi
    candidates=("${selected_local[@]}")
    _zsh_git_sweep_load_protection || return $?
  fi

  local interactive_failed=0
  local b
  for b in "${candidates[@]}"; do
    echo "🔍 Checking branch: $b (${candidate_reasons[$b]})"

    if (( interactive )); then
      if _zsh_git_sweep_matches_protection "$b" ||
          ! _zsh_git_sweep_revalidate_local "$b" "$base_ref" "$force"; then
        echo "   ⚠️  Selected branch is no longer eligible; skipping."
        interactive_failed=1
        continue
      fi
    fi

    if [[ "$b" == "$current_branch" ]]; then
      echo "   ⚠️  Skipping current branch."
      continue
    fi

    if _zsh_git_sweep_is_protected_branch "$b" "${protected_branches[@]}"; then
      echo "   ⚠️  Skipping protected branch."
      continue
    fi

    if (( ! force && ! interactive )) && (( ! ${+merged_candidates[$b]} )); then
      echo "   ⚠️  Branch is not merged into $base_ref; skipping."
      if (( ${+stale_candidates[$b]} )); then
        echo "      Review it, then use gitsweep --force --stale-days $stale_days to remove it."
      else
        echo "      Use gitsweep --force to remove it anyway."
      fi
      continue
    fi

    if ! _zsh_git_sweep_remove_local_branch "$b" "$force" "$dry_run" "gitsweep --force"; then
      interactive_failed=1
    fi
  done

  if (( interactive )); then
    if (( interactive_failed )); then
      echo "❌ Selected cleanup incomplete; some selected branches were preserved."
      return 1
    fi
    if (( dry_run )); then
      echo "✅ Selected dry run complete!"
    else
      echo "✅ Selected cleanup complete! Unselected branches and worktrees were kept."
    fi
    return 0
  fi

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

  local -a protect_patterns local_choices remote_choices selected_local selected_remote
  local -A interactive_oids interactive_paths
  local base_ref=""
  local interactive=0
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
      --protect)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
          echo "🚨 Missing value for --protect"
          return 2
        fi
        protect_patterns+=("$2")
        shift
        ;;
      -i|--interactive)
        interactive=1
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

  if (( interactive )) && [[ ! -t 0 || ! -t 1 ]]; then
    echo "🚨 --interactive requires terminal input and output."
    return 2
  fi

  _zsh_git_sweep_load_protection || return $?

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

  if ! git rev-parse --verify --quiet --end-of-options "$base_ref^{commit}" >/dev/null; then
    echo "❌ Base ref not found: $base_ref"
    return 1
  fi

  local base_branch
  if ! base_branch=$(_zsh_git_sweep_branch_name_from_ref "$base_ref" "$remote") ||
      ! git show-ref --verify --quiet "refs/remotes/$remote/$base_branch"; then
    echo "❌ Base must identify a branch on $remote: $base_ref"
    return 1
  fi

  echo "🧭 Using remote: $remote"
  echo "🧭 Using primary/base ref: $base_ref"

  # Everything except the primary branch is deleted, so require it to be checked out.
  local current_branch
  current_branch=$(git symbolic-ref --quiet HEAD 2>/dev/null)
  current_branch=${current_branch#refs/heads/}
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
  local -A candidate_oids
  local branch oid
  while IFS=$'\t' read -r branch oid; do
    [[ -z "$branch" ]] && continue
    remote_candidates+=("$branch")
    candidate_oids[$branch]=$oid
  done < <(_zsh_git_sweep_remote_branches "$remote" "$base_branch")

  while IFS= read -r branch; do
    [[ -z "$branch" || "$branch" == "$base_branch" ]] && continue
    _zsh_git_sweep_matches_protection "$branch" && continue
    local_candidates+=("$branch")
  done < <(git for-each-ref --format='%(refname:lstrip=2)' refs/heads)

  if (( ${#remote_candidates} == 0 && ${#local_candidates} == 0 )); then
    echo "✨ All clean! Only $base_branch and protected branches remain locally and on $remote."
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

  if (( interactive )); then
    local_choices=("${local_candidates[@]}")
    remote_choices=("${remote_candidates[@]}")
    _zsh_git_sweep_choose "$base_ref" "$force" "$dry_run" "$remote" || return $?
    if (( ${#selected_local} == 0 && ${#selected_remote} == 0 )); then
      echo "Cancelled; no selected branches or worktrees were deleted."
      return 0
    fi
    local_candidates=("${selected_local[@]}")
    remote_candidates=("${selected_remote[@]}")
    _zsh_git_sweep_load_protection || return $?
    current_branch=$(git symbolic-ref --quiet HEAD 2>/dev/null)
    if [[ "$current_branch" != "refs/heads/$base_branch" ]]; then
      echo "🚨 Primary branch is no longer checked out; cancelling selected cleanup."
      return 1
    fi
  fi

  local remote_deleted_count=0
  for branch in "${remote_candidates[@]}"; do
    echo "🔍 Checking remote branch: $remote/$branch (not primary branch)"
    if (( interactive )) && _zsh_git_sweep_matches_protection "$branch"; then
      echo "   ⚠️  Branch is now protected; skipping."
      left_behind+=("$remote/$branch")
      continue
    fi

    if (( dry_run )); then
      echo "   🗑️  Would delete remote branch: $remote/$branch"
      continue
    fi

    echo "   🗑️  Deleting remote branch: $remote/$branch"
    if _zsh_git_sweep_delete_remote_branch "$remote" "$branch" "${candidate_oids[$branch]}"; then
      remote_deleted_count=$(( remote_deleted_count + 1 ))
    else
      echo "   ⚠️  Could not delete remote branch: $remote/$branch."
      left_behind+=("$remote/$branch")
    fi
  done

  if (( remote_deleted_count > 0 && ! interactive )); then
    echo "🌐 Pruning deleted remote-tracking refs from $remote..."
    if ! git fetch -p "$remote"; then
      echo "⚠️  Deleted remote branches, but could not prune local remote-tracking refs."
    fi
  fi

  for branch in "${local_candidates[@]}"; do
    echo "🔍 Checking branch: $branch (not primary branch)"
    if (( interactive )); then
      if _zsh_git_sweep_matches_protection "$branch" ||
          ! _zsh_git_sweep_revalidate_local "$branch" "$base_ref" "$force"; then
        echo "   ⚠️  Selected branch is no longer eligible; skipping."
        left_behind+=("$branch")
        continue
      fi
    fi

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

  if (( interactive )); then
    if (( ${#left_behind} > 0 )); then
      echo "❌ Selected cleanup incomplete. Branches left behind: ${(j:, :)left_behind}"
      return 1
    fi
    if (( dry_run )); then
      echo "✅ Selected dry run complete!"
    else
      echo "✅ Selected cleanup complete! Unselected branches and worktrees were kept."
    fi
    return 0
  fi

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

  echo "✅ Full git sweep complete! Only $base_branch and protected branches remain locally and on $remote."
}

# Optional alias.
alias gsweep='gitsweep'
alias gsweep-rm='gitsweep-remote-merged'
alias gsweep-ra='gitsweep-remote-all'
alias gsweep-a='gitsweep-all'
