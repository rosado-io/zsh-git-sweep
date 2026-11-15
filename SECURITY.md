# Security Policy

`zsh-git-sweep` is a local shell plugin that can delete local Git branches,
worktrees, and explicitly selected remote Git branches when invoked by the user.
The main safety goal is to avoid surprising or implicit destructive behavior.

## Supported Versions

The latest tagged release (currently `v0.3.0`) and the latest commit on `main`
are supported. Upgrade older releases to receive security and safety fixes.

## Reporting a Vulnerability

Please report security issues privately when possible through GitHub's security
advisory flow. If private reporting is not available, open a GitHub issue with a
minimal description and avoid including sensitive repository paths, tokens, or
private branch names.

Useful reports include:

- commands run
- expected behavior
- actual behavior
- whether `--force` was used
- whether a remote cleanup command was used
- Git and zsh versions

## Safety-Sensitive Behavior

Please treat these as security-sensitive areas:

- deleting unmerged branches
- deleting remote branches with `git push --delete`
- removing dirty worktrees
- parsing branch names and worktree paths
- handling protected branch names
- dry-run behavior that must not mutate Git refs or worktrees
- preserving branches updated remotely between scanning and deletion
- respecting configured protection even in force mode
- treating failed worktree inspection as unsafe to delete

The plugin has no third-party runtime package dependencies; Git and zsh are
provided by the host. Keep those installations patched through your operating
system or package manager. CI actions are pinned to full commit hashes and
tracked by Dependabot.
