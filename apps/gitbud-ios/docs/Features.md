# GitBud (iOS/iPadOS) — Features

GitBud for iOS and iPadOS is a remote-only companion for reviewing and improving
git history through GitPont. It shares GitBud's simple language and visual model,
but it does not perform macOS-style local history surgery in v1.

## Planned v1

- Connect provider accounts through GitPont.
- List and search remote repositories.
- Browse branches, files, and recent commits.
- Show file history for a selected file when the provider/GitPont can supply it.
- View commit details and diffs.
- Use AIPont BYOK Magic to draft commit messages, PR titles, and PR descriptions.
- Create branches and PRs/MRs for safe edits.
- Perform provider-supported file edits/deletes as normal new commits.

## Future

- Remote-assisted rewrite workflows only if GitPont exposes safe provider-direct
  capabilities for them.
- iPad-optimized visual branch graph and diff review.
- Conflict/review workflows for PRs created from GitBud macOS.

## Non-goals

- Shell git.
- SSH agent support.
- Full local clone history rewriting in v1.
- Force-push-first workflows.
- GitBud accounts, hosted GitBud backend, or GitBud-owned sync infrastructure.
