# GitBud — Risks and Open Questions

## Risks

- **Rewrite correctness.** Splitting commits by hunk remains the highest-risk rewrite path. It now
  has real-git coverage for HEAD and non-HEAD commits, including later-commit replay; keep adding
  focused fixtures whenever the patch engine changes.
- **Conflict UX.** Merge, rebase, revert, cherry-pick, pull-rebase, and stash-pop conflicts now
  surface through the shared conflict model with `Your change` / `REmote change` labels. Continue
  and abort recovery are covered at the AppModel level across the shared conflict modes, including
  a real merge-conflict continuation that lands as a two-parent merge commit. GitKit also has
  real-git coverage for side-choice mapping across merge, rebase, revert, cherry-pick, and
  stash-pop conflicts.
- **Purge blast radius.** Full-history purge affects branches, tags, remotes, and collaborators.
  Backup refs, preview, exact `PURGE <path>` confirmation, and separate push confirmation are in
  place; this still needs careful release documentation.
- **GitPont scope.** GitPont can handle provider auth, repository metadata, credentials, and PR/MR
  flows, but macOS full history rewriting still needs a local checkout in v1.
- **AIPont privacy.** Magic sends selected diffs to the user's chosen AI provider. The UI must make
  that clear and keep provider keys in Keychain only.
- **Mobile parity expectations.** iOS/iPadOS are remote-only. They should not be presented as full
  history-surgery clients until GitPont can support safe provider-direct workflows.

## Open questions

- Which providers should GitPont support for GitBud v1 beyond the providers already available in
  the dependency?
- Should protected branches be configured locally by GitBud, read from provider metadata, or both?
- Which modern history filtering tool should GitKit wrap for purge on macOS?
- Should app-managed remote checkouts be shared with other GitKit apps or isolated per product?
- What is the minimum Magic prompt context that produces useful messages without sending excessive
  repository data?
