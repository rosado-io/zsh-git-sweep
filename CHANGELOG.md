# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for tagged releases.

## [Unreleased]

### Added

- Safe cleanup for merged local branches checked out in Git worktrees.
- Detection of branches whose upstream remote-tracking branch is gone.
- Optional stale branch review with `--stale-days`.
- Conservative dry-run mode with `--dry-run`.
- Force mode for explicitly reviewed destructive cleanup.
- Local integration tests for branch and worktree cleanup behavior.

