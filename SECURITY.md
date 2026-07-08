# Security Policy

`zsh-git-sweep` is a local shell plugin that can delete local Git branches,
worktrees, and explicitly selected remote Git branches when invoked by the user.
The main safety goal is to avoid surprising or implicit destructive behavior.

## Supported Versions

The latest commit on the `main` branch is supported until tagged releases are
introduced.

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
