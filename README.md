<div align="center">
  <img src="assets/logo.svg" alt="zsh-git-sweep logo" width="120" />
  <h1>zsh-git-sweep</h1>
  <p>Oh My Zsh plugin that safely sweeps away orphaned Git branches <em>and</em> their worktrees.</p>
</div>

## The Problem

After a busy sprint of pull requests, your local repository is often littered with branches that have already been merged or deleted on the remote. Standard cleanup with `git branch -d` or `git fetch -p` works for simple branches, but it fails when a branch is checked out in a Git worktree:

```text
error: Cannot delete branch 'feature-x' checked out at '/path/to/worktree'
```

`zsh-git-sweep` automates the full cleanup: it finds branches whose upstream is `[gone]`, removes any attached worktrees, deletes the branches, and prunes leftover worktree metadata.

## Installation

### Manual (Oh My Zsh)

1. Clone this repository into your Oh My Zsh custom plugins directory:

   ```zsh
   git clone https://github.com/YOUR_USERNAME/zsh-git-sweep.git \
     ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-git-sweep
   ```

2. Add `zsh-git-sweep` to the plugins array in your `~/.zshrc`:

   ```zsh
   plugins=(
     # ... your other plugins
     zsh-git-sweep
   )
   ```

3. Reload your shell configuration:

   ```zsh
   source ~/.zshrc
   ```

## Usage

Run the function from inside any Git repository:

```zsh
gitsweep
```

Or use the shorter alias:

```zsh
gsweep
```

### Example Output

When there are branches to clean:

```text
🧹 Starting git sweep...
🌐 Fetching and pruning remote tracking branches...
🗑️  Found 2 orphaned branch(es): feature-a, feature-b
🔍 Checking branch: feature-a
   📦 Removing worktree at /home/user/repos/feature-a
   🗑️  Deleting branch: feature-a
🔍 Checking branch: feature-b
   🗑️  Deleting branch: feature-b
🧼 Running git worktree prune...
✅ Git sweep complete!
```

When everything is already clean:

```text
🧹 Starting git sweep...
🌐 Fetching and pruning remote tracking branches...
✨ All clean! No orphaned branches found.
```

## What It Does

1. Runs `git fetch -p` to prune remote-tracking references.
2. Identifies local branches whose upstream is marked `[gone]`.
3. For each orphaned branch, finds any associated Git worktree.
4. Forcefully removes the worktree first (`git worktree remove -f`).
5. Deletes the local branch (`git branch -d`).
6. Runs `git worktree prune` for general cleanup.

## Contributing

Contributions are welcome! Please open an issue to discuss larger changes, and submit pull requests against the `main` branch. Keep changes focused, update the README if behavior changes, and ensure the plugin still works with the latest stable Oh My Zsh.

## License

[MIT](LICENSE)
