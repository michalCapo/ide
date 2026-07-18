# Build `lazyrepo` as a Separate Command

## Summary

Create `lazyrepo`, a repository-wide Neovim TUI. Keep `lazydiff` as the focused diff command and shared diff engine. Reuse the portable Neovim payload, adding a launcher and Lua modules. Retain upstream `lazygit` during rollout.

## Interface and keybindings

The dashboard has three columns:

- Left: uncommitted file tree.
- Middle: stacked local-branch, remote-branch, and stash panels.
- Right: commits for the selected branch.

Below 100 terminal columns, the dashboard collapses to the active panel while
retaining panel navigation through `h`/`l` and `Tab`/`Shift-Tab`.

Global keys: `h/l` switch panels, `j/k` move, `R` refresh, `p/P` pull/push, `?` help, and `q` quit.

Files:

- `Enter` toggles folders or opens a file in full-screen lazydiff, then refreshes.
- `Space` stages or unstages the selected file/folder.
- `a` stages all when unstaged changes exist, otherwise unstages all.
- `d` implements Lazygit-compatible discard behavior and confirmation for tracked files, staged additions, untracked selections, renames, conflicts, and newly empty selected directories.
- `c` commits staged changes with the existing multiline prompt and history.
- `s` stashes a prompted scope (everything including untracked, tracked, staged, or unstaged) with an optional message.

Commits:

- Branch selection immediately loads its reachable graph.
- `Enter` drills into a collapsible commit file tree; files open lazydiff against the first parent.
- `Esc` returns to history.
- Root commits compare to the empty tree; merge commits compare to their first parent.

Branches:

- `Space` checks out a local branch or creates/checks out a tracking branch from a remote.
- `M` merges the selected branch; `r` rebases the current branch onto it.
- Local deletion offers local-only or local plus tracked remote (default both), with extra force confirmation for unmerged branches.
- Remote deletion offers remote-only or remote plus its tracking local branch.
- Never delete the checked-out branch.
- Pull uses configured strategy. Push uses the upstream, or prompts for a remote and performs same-name `push -u`.

Stashes:

- `Enter` drills into the stash tree, including tracked and untracked-parent files; files open lazydiff.
- `Space` applies, `g` pops, and `d` confirms then drops.
- Every operation refreshes all panels.

## Implementation

- Extract reusable rendering and Git-process helpers from `views/lazydiff.lua` and support worktree, commit, and stash sources without changing `lazydiff FILE` behavior or keys.
- Add `views.lazyrepo` with explicit focus, selection, tree-collapse, drill-down, loading, and operation state.
- Run fetch/pull/push/merge/rebase/stash jobs asynchronously and disable conflicting actions while busy.
- Add the `lazyrepo` launcher and build/install/release integration. Support `lazyrepo` and `lazyrepo --help`, operating on the repository containing the current directory.
- Preserve selections by stable path/ref/OID, falling back to the nearest surviving item.
- Show actionable Git stderr and refresh after both success and failure.

### Conflict workflow

- Detect merge, rebase, cherry-pick, and revert metadata.
- Mark conflicted files.
- Parse two-way and diff3 conflict blocks.
- Resolve hunks as ours, theirs, or both with actual ref labels.
- Resolve files as ours, theirs, both, or external edit.
- Auto-stage after the final marker is resolved.
- Support continue, rebase skip, and abort.
- If markers are malformed or manually removed, disable hunk resolution while retaining file-level/edit actions.

## Verification

- Unit-test porcelain/ref/graph/stash/conflict parsing, unusual paths, renames, trees, and collapse state.
- Use temporary repositories for staging, discard semantics, commit/stash inspection, stash operations, root/merge diffs, remotes, pull/push, branch deletion, merge/rebase, and conflict lifecycle.
- Add headless Neovim tests for focus, keymaps, selection preservation, drill-down, busy/error state, and narrow terminals.
- Build and smoke-test `nvim`, `lazydiff`, `lazyrepo`, and retained `lazygit` across x86_64 and arm64 packaging paths.

## Assumptions

- Git CLI is the only backend.
- Commit history includes merged commits (no `--first-parent`).
- Stash v1 supports create, inspect, apply, pop, and drop, but not rename or branch-from-stash.
- Existing `lazygit` remains packaged until `lazyrepo` is independently verified.
