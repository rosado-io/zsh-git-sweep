# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for tagged releases.

## [Unreleased]

## [0.5.0] - 2026-11-23

### Added

- `gsweep` and `gsweep-a` now include eligible local PR review refs in their
  default cleanup, dry runs and interactive selection.

## [0.4.0] - 2026-11-15

### Added

- `--interactive` (`-i`) on all four commands, with a numbered candidate menu,
  independent local/remote selection, branch/worktree pairs, and a final explicit
  confirmation. Empty input cancels; dry runs preview only the chosen entries.
- Terminal integration coverage using zsh's bundled `zsh/zpty` module.

### Safety

- Interactive selection honors protected branches and worktree locks, excludes
  unsafe local candidates unless `--force` is explicit, and rejects nonterminal
  input/output before fetching.
- Recheck local branch tips, worktree paths and safety conditions after user
  input, reload configured protection, and retain original remote deletion leases.
- Skip global worktree pruning and the follow-up remote fetch/prune for
  interactive cleanup; deliberately unselected candidates are kept without error.

## [0.3.0] - 2026-11-14

### Added

- Repeatable `--protect <glob>` on all four commands and persistent
  `gitsweep.protect` Git configuration. Protection is additive, preserves matching
  branches and worktrees, and is honored even with `--force`.
- Weekly Dependabot updates for GitHub Actions dependencies.
- `gitsweep-all` (alias `gsweep-a`) to delete every non-primary local and
  remote branch in one command, with a combined dry run, a primary-branch
  check, a `--force` gate for unmerged or dirty local work, and a nonzero exit
  when anything is left behind.

### Changed

- Scan merged local and remote branches with one Git ancestry query per namespace
  instead of starting `git merge-base` for each branch in those scans.
- Require Git 2.36 or newer to parse worktree paths with NUL-delimited output.
- Update `actions/checkout` from v4 to v7.0.1, pinned to its full commit SHA,
  disable persisted checkout credentials, and add a CI timeout and syntax checks.
- Remote commands now require `--base` to identify a branch on the selected
  remote; tags and raw commit IDs cannot safely identify a branch to keep.

### Fixed

- Guard remote deletions with explicit commit leases so concurrent pushes and
  stale tracking refs cannot cause unseen commits to be deleted.
- Return nonzero from remote-only sweeps when a branch deletion fails.
- Use fully qualified remote deletion refs to avoid collisions with tag names.
- Preserve local base branches whose names contain slashes.
- Parse worktree paths containing spaces, quotes, backslashes, tabs, Unicode,
  and newlines without invoking `awk` for each candidate.
- Honor worktree locks in previews, fail closed when worktree status cannot be
  read, and inspect untracked files and submodules regardless of status settings.
- Remove all temporary test repositories on exit and isolate tests from global
  and system Git configuration.

## [0.2.1] - 2026-07-08

### Fixed

- Skip remote HEAD symbolic refs during remote branch sweeps.

## [0.2.0] - 2026-07-08

### Added

- Safe cleanup for merged local branches checked out in Git worktrees.
- Detection of branches whose upstream remote-tracking branch is gone.
- Optional stale branch review with `--stale-days`.
- Conservative dry-run mode with `--dry-run`.
- Force mode for explicitly reviewed destructive cleanup.
- Remote cleanup for branches already merged into the primary branch.
- Remote cleanup for deleting all branches except the primary branch.
- Short aliases for remote cleanup commands.
- Local integration tests for branch and worktree cleanup behavior.
