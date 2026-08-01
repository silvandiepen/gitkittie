# GitBud — Phase 1

Phase 1 proves the product shape before deep destructive editing ships.

## Included

- Native macOS SwiftUI shell.
- Local repository open.
- GitPont remote connect and app-managed clone.
- Commit graph with branch/ref decorations.
- Working tree state.
- Commit inspector.
- File diff view.
- File browser with file history.
- Read-only rewrite preview model for selected commit ranges.

## Deferred

- Applying rewrite operations.
- Force-with-lease push of rewritten history.
- Full-history purge.
- iOS/iPadOS app target.
- Broad Tower-style feature parity such as submodules and advanced remote management.

## Acceptance criteria

- Opening a real local repo shows the current branch, HEAD, dirty state, and recent history.
- Connecting through GitPont can list remote repos and clone a selected repo into app-managed
  storage.
- Selecting a commit shows changed files and diffs.
- Selecting a file shows commits that changed it.
- Selecting a commit range creates a non-mutating rewrite preview.
- No GitBud account or backend configuration exists anywhere in the app.
