# GitBud (iOS/iPadOS) — Architecture

GitBud iOS/iPadOS is remote-only. It talks to hosted git providers through
GitPont and uses shared GitKit types only where those types do not assume local
git process access.

## Layering

```txt
SwiftUI views
  repo list · branch browser · file browser · commit inspector · diff review · Magic sheets
        │
        ▼
AppModel (@Observable, @MainActor)
  provider session, selected repo/branch/file/commit, Magic state
        │
        ├── GitPont
        │     auth · repos · branches · files · commits · PR/MR
        │
        ├── swift/GitKit
        │     shared provider-neutral models and parsing helpers only
        │
        └── AIPont
              BYOK Magic suggestions
```

## Remote-only model

iOS/iPad opens repositories through GitPont provider connections. It does not
clone repositories into a local git store for v1 and does not run rebase/split/
squash through a local git binary.

Risky edits should become new branches and PRs/MRs. Destructive force-push or
full-history purge workflows are macOS-first unless GitPont exposes safe
provider-direct rewrite capability.

## Shared behavior with macOS

- Same user-facing language for branches, commits, diffs, and Magic.
- Same AIPont prompt rules: user-approved output only.
- Same credential policy: provider tokens and AI keys stay in Keychain.
- Same preference for branch/PR workflows when an edit may affect collaborators.
