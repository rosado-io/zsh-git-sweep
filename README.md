# zsh-git-sweep

[![Test](https://github.com/rosado-io/zsh-git-sweep/actions/workflows/test.yml/badge.svg)](https://github.com/rosado-io/zsh-git-sweep/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Oh My Zsh plugin that cleans up local Git branches, worktrees, and explicit
remote branch sweeps after pull requests, experiments, and AI-assisted work
sessions.

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
deletes the local branches, and prunes leftover worktree metadata. It also
provides separate commands for intentionally deleting remote branches.

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

Remote cleanup is intentionally a separate command family because it mutates the
remote repository with `git push <remote> --delete <branch>`:

- `gitsweep-remote-merged` deletes remote branches that are already merged into
  the selected base ref.
- `gitsweep-remote-all` deletes every branch from the selected remote except the
  primary/base branch.

For remote cleanup, the default remote is `origin` when available, otherwise the
first configured remote. The primary branch is detected from `<remote>/HEAD`,
then common branch names such as `<remote>/main` and `<remote>/master`. Use
`--remote` and `--base` to choose explicitly.

If you are running it in a repository you care about, start with:

```zsh
gitsweep --dry-run
gitsweep-remote-merged --dry-run
gitsweep-remote-all --dry-run
```

Dry-run mode is designed to preview cleanup without changing branches,
worktrees, or Git refs.

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

### Plugin Managers

With [zinit](https://github.com/zdharma-continuum/zinit):

```zsh
zinit light rosado-io/zsh-git-sweep
```

With [antidote](https://getantidote.github.io/):

```zsh
antidote bundle rosado-io/zsh-git-sweep
```

With [Antigen](https://github.com/zsh-users/antigen):

```zsh
antigen bundle rosado-io/zsh-git-sweep
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

Remote cleanup commands:

```zsh
gitsweep-remote-merged
gitsweep-remote-all
```

Short aliases:

```zsh
gsweep        # gitsweep
gsweep-rm     # gitsweep-remote-merged
gsweep-ra     # gitsweep-remote-all
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

```text
Usage: gitsweep-remote-merged [options]

Options:
  -r, --remote <name>    Delete branches from this remote.
  -b, --base <ref>       Compare merged remote branches against this base ref.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p <remote> before scanning.
  -h, --help             Show this help message.
```

```text
Usage: gitsweep-remote-all [options]

Options:
  -r, --remote <name>    Delete branches from this remote.
  -b, --base <ref>       Keep this base ref as the primary branch.
  -n, --dry-run          Show what would be removed without changing anything.
      --no-fetch         Skip git fetch -p <remote> before scanning.
  -h, --help             Show this help message.
```

### Common Workflows

Preview cleanup before touching anything:

```zsh
gitsweep --dry-run
```

Dry runs only print what would be removed. They do not delete branches,
worktrees, or Git refs.

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

Delete remote branches already merged into the primary branch:

```zsh
gsweep-rm --dry-run
gsweep-rm
```

Delete every remote branch except the primary branch:

```zsh
gsweep-ra --dry-run
gsweep-ra
```

Choose a remote or primary branch explicitly:

```zsh
gitsweep-remote-merged --remote upstream --base upstream/main
gitsweep-remote-all --remote origin --base origin/main
```

## Examples

When previewing safe branches to clean:

```text
🧹 Starting git sweep...
🔎 Dry run mode: no branches, worktrees, or Git refs will be changed.
🌐 Checking remote tracking branches (dry run)...
🧭 Using base ref: origin/main
🗑️  Found 2 branch(es) to inspect: feature-a, feature-b
🔍 Checking branch: feature-a (merged into origin/main)
   📦 Would remove worktree at /home/user/repos/feature-a
   🗑️  Would delete branch: feature-a
🔍 Checking branch: feature-b (upstream gone, merged into origin/main)
   🗑️  Would delete branch: feature-b
🧼 Would run git worktree prune
✅ Dry run complete!
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

## Comparison With Built-in Git Commands

`gitsweep` wraps a few common cleanup primitives into one conservative workflow:

| Command | What it does | What `gitsweep` adds |
| --- | --- | --- |
| `git fetch -p` | Prunes stale remote-tracking refs. | Can detect local branches whose upstream is gone, then remove the local branch when it is safe. |
| `git branch -d` | Deletes a local branch only when Git considers it merged. | Removes a linked worktree first, then deletes the local branch. |
| `git worktree prune` | Removes stale worktree administrative files. | Runs after branch/worktree cleanup so leftover metadata is tidied up. |
| `git push origin --delete <branch>` | Deletes one branch from a remote. | Can batch-delete merged remote branches, or all remote branches except the primary branch. |

## FAQ

### Does dry-run mutate refs?

No. In dry-run mode, `gitsweep` uses `git fetch --dry-run -p` to preview pruned
remote-tracking refs and only prints what it would remove.

Remote dry runs do not delete remote branches or update local remote-tracking
refs. They preview candidates from the refs currently known locally after a
non-mutating fetch check.

### What does `--force` delete?

`--force` uses `git worktree remove -f` and `git branch -D` for branches that
`gitsweep` has selected as candidates. Review `gitsweep --dry-run` output before
using it.

### What happens to dirty worktrees?

Without `--force`, dirty worktrees are skipped and their branches are preserved.
With `--force`, local worktree changes can be deleted.

### How is the base branch detected?

`gitsweep` first checks `origin/HEAD`, then common names such as `origin/main`,
`origin/master`, `main`, and `master`. Pass `--base <ref>` to choose explicitly.

### What does `gitsweep-remote-all` keep?

It keeps the primary/base branch only. By default that is detected from
`<remote>/HEAD`; pass `--base <ref>` if you want to preserve a specific branch.

## Development

Run the local test script from the repository root:

```zsh
zsh tests/gitsweep.zsh
```

The tests create temporary Git repositories and verify the safe default behavior
and explicit force behavior.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
before opening a pull request.

For security-sensitive behavior, see [SECURITY.md](SECURITY.md).

Release notes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
