# Contributing

Thanks for considering a contribution to `zsh-git-sweep`.

This project is intentionally small: it should stay easy to audit, easy to
install, and conservative by default because it deletes local Git state.

## Development Setup

Clone the repository:

```zsh
git clone https://github.com/rosado-io/zsh-git-sweep.git
cd zsh-git-sweep
```

Run the test suite:

```zsh
zsh tests/gitsweep.zsh
```

The tests create temporary Git repositories and worktrees, then remove them when
the script exits.

## Pull Request Guidelines

- Keep changes focused.
- Preserve safe default behavior.
- Add or update tests when behavior changes.
- Update `README.md` when commands, options, or safety guarantees change.
- Prefer clear shell code over clever shell code.

## Safety Expectations

By default, `gitsweep` should not delete dirty worktrees, the current branch,
protected base branches, or unmerged branch work unless the user explicitly
passes `--force`.

Changes that expand deletion behavior should be reviewed carefully and covered
by tests.

