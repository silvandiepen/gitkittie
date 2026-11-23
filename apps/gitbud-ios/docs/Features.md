# GitKittie Bud (iOS/iPadOS) — Features

GitKittie Bud for iPhone and iPad reads git history and turns parts of it into pull
requests, through GitPont only — no git on the device, no clone. Same language, same diff
views and the same line merge as GitKittie Bud on the Mac (shared in `swift/GitKittieKit`).

## Implemented

- **Connect:** GitHub sign-in (device code, the family's OAuth app), or a token for GitHub,
  GitLab.com or self-hosted GitLab. The token is kept in the Keychain. No GitKittie Bud account.
- **Demo:** an offline repository served through the same GitPont contract, with history,
  branches, pull requests, and real branch/commit/pull request creation in memory.
- **Repositories:** the account's repositories, newest activity first, with search.
- **History:** a branch's commits, newest first, paged; branch menu in the toolbar; merges marked.
- **A commit:** the whole message, author, date, copyable id, merge parents, every file with
  its lines added and removed, a link to the host's page.
- **A file's changes, three ways:** Unified, Side by Side, and Full File (the file at the commit,
  read from the host, with the changes in place).
- **Choose changed lines** — tap a line, or a hunk's header for all of it — across all files of a
  commit, kept when switching views.
- **Undo in a pull request / Bring to a branch:** the chosen lines are undone (or made again) on a
  new branch cut from the branch you pick, committed in one commit, and a pull request opens.
  Each file is a three-way merge read from the host, so edits made on that branch since are kept,
  even on the next line; nothing is made when the chosen lines themselves changed since, and a file
  that would not change is left out. Nothing is written to the target branch itself.
- **Pull requests:** open, closed or all, with state, draft, author and branches; the description
  in a sheet, and a link to the host.
- **Magic, on this device:** "Draft with Apple Intelligence" writes the pull request's title and
  description from the chosen lines with Apple's on-device model — no key, nothing leaves the
  device, and the person edits the result. Hidden where the model is not available.
- iPhone and iPad from one split view: three columns on iPad, a stack on iPhone.

## Planned

- Files at a ref (browse the tree; GitPont already lists directories and reads files).
- Bitbucket and Forgejo/Gitea connections (GitPont supports their history and pull requests).
- Pull request review: changed files and comments, once GitPont can read them (GITKITTIE-063).
- Commit rules applied to the pull request's commit message (GITKITTIE-064).

## Future

- Remote-assisted history rewriting only if GitPont exposes safe provider-direct capabilities.

## Non-goals

- Shell git, SSH agent support, or a full local clone.
- Force pushes, or writing to the target branch directly.
- GitKittie Bud accounts, a hosted backend, or GitKittie Bud-owned sync infrastructure.
