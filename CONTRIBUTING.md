# Contributing

Thanks for considering a contribution to `zsh-git-sweep`.

This project is intentionally small: it should stay easy to audit, easy to
install, and conservative by default because it deletes local and remote Git
state.

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

Remote cleanup commands should keep dry-run behavior non-mutating and must never
delete the detected primary/base branch.

`gitsweep-all` must only run from the primary branch, must not delete unmerged
local branches or dirty worktrees without `--force`, and must exit nonzero when
an unprotected candidate is left behind.

All commands must honor CLI and configured protection patterns, even with
`--force`. Locked worktrees must remain untouched. Remote deletions must use the
object ID captured during candidate selection as an explicit lease, so a later
push or background fetch cannot silently change what was approved for deletion.

Use Git 2.36 or newer. Add safety regression cases in `tests/regressions.zsh`;
the main test script sources it and supplies isolated fixtures and assertions.
Do not use the project's actual remote or worktrees as deletion test fixtures.

Changes that expand deletion behavior should be reviewed carefully and covered
by tests.
