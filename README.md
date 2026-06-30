# zsh-git-sweep

Oh My Zsh plugin that cleans up local Git branches and worktrees after pull
requests, experiments, and AI-assisted work sessions.

## Why

When you use Git worktrees heavily, especially for AI coding sessions, local
repositories quickly collect old branches and worktree directories. Some were
already merged, some had their remote branch deleted, and some were simply left
behind after an experiment.

`git fetch -p` prunes stale remote-tracking refs, but it does not delete your
local branches. `git branch -d` can delete safe merged branches, but it fails
when a branch is checked out in a Git worktree:

```text
error: Cannot delete branch 'feature-x' checked out at '/path/to/worktree'
```

`zsh-git-sweep` handles that cleanup flow for you. It finds local branches that
are already merged into your base branch, branches whose upstream is marked
`[gone]`, and optionally stale branches by age. It removes safe worktrees first,
deletes the local branches, and prunes leftover worktree metadata.

## Safety

By default, `gitsweep` is intentionally conservative:

- It targets local branches that are merged, whose upstream is `[gone]`, or
  that you explicitly include with `--stale-days`.
- It skips the branch you are currently on.
- It skips protected branch names such as `main`, `master`, `trunk`, `develop`,
  and `dev`.
- It removes worktrees without `--force`, so dirty worktrees are preserved.
- It only deletes branches that are already merged into the base branch.

Use `gitsweep --force` only after reviewing the branch/worktree. Force mode runs
`git worktree remove -f` and `git branch -D`, which can delete local worktree
changes and unmerged commits.

By default, the base branch is detected from `origin/HEAD`, then common branch
names like `origin/main`, `origin/master`, `main`, and `master`. Use `--base` to
override it.

## Requirements

- zsh
- Git
- Oh My Zsh, if you want to load it as an Oh My Zsh plugin

## Installation

### Oh My Zsh

Clone this repository into your Oh My Zsh custom plugins directory:

```zsh
git clone https://github.com/rosado-io/zsh-git-sweep.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-git-sweep"
```

Add `zsh-git-sweep` to the plugins array in `~/.zshrc`:

```zsh
plugins=(
  # ... your other plugins
  zsh-git-sweep
)
```

Reload your shell:

```zsh
source ~/.zshrc
```

### Manual zsh

You can also source the plugin directly:

```zsh
source /path/to/zsh-git-sweep/zsh-git-sweep.plugin.zsh
```

## Usage

Run from inside any Git repository:

```zsh
gitsweep
```

Or use the shorter alias:

```zsh
gsweep
```

Available options:

```text
Usage: gitsweep [options]

Options:
  -b, --base <ref>       Compare merged branches against this base ref.
  -f, --force            Remove unmerged/stale candidates too.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p before scanning.
      --stale-days <n>   Include branches older than n days as candidates.
  -h, --help             Show this help message.
```

### Common Workflows

Preview cleanup before touching anything:

```zsh
gitsweep --dry-run
```

Clean branches merged into `origin/main` and safe worktrees:

```zsh
gitsweep --base origin/main
```

Review old forgotten branches:

```zsh
gitsweep --stale-days 30 --dry-run
```

Force-remove reviewed stale branches and their worktrees:

```zsh
gitsweep --stale-days 30 --force
```

## Examples

When there are safe branches to clean:

```text
🧹 Starting git sweep...
🌐 Fetching and pruning remote tracking branches...
🧭 Using base ref: origin/main
🗑️  Found 2 branch(es) to inspect: feature-a, feature-b
🔍 Checking branch: feature-a (merged into origin/main)
   📦 Removing worktree at /home/user/repos/feature-a
   🗑️  Deleting branch: feature-a
🔍 Checking branch: feature-b (upstream gone, merged into origin/main)
   🗑️  Deleting branch: feature-b
🧼 Running git worktree prune...
✅ Git sweep complete!
```

When a worktree or branch is not safe to delete:

```text
🧹 Starting git sweep...
🌐 Fetching and pruning remote tracking branches...
🧭 Using base ref: origin/main
🗑️  Found 1 branch(es) to inspect: feature-a
🔍 Checking branch: feature-a (upstream gone)
   ⚠️  Branch is not merged into origin/main; skipping.
      Use gitsweep --force to remove it anyway.
🧼 Running git worktree prune...
✅ Git sweep complete!
```

When everything is already clean:

```text
🧹 Starting git sweep...
🌐 Fetching and pruning remote tracking branches...
🧭 Using base ref: origin/main
✨ All clean! No sweep candidates found.
```

## Development

Run the local test script from the repository root:

```zsh
zsh tests/gitsweep.zsh
```

The tests create temporary Git repositories and verify the safe default behavior
and explicit force behavior.

## Contributing

Contributions are welcome. Please open an issue to discuss larger changes and
submit pull requests against the `main` branch. Keep changes focused, update the
README when behavior changes, and make sure the local tests pass.

## License

[MIT](LICENSE)
