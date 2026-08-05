This policy covers the GitKittie apps — **GitKittie Folder**, **GitKittie Kanban** and **GitKittie Bud**. All are local-first macOS utilities. They are designed so that your data never passes through GitKittie servers, because there are none.

## No cloud service

GitKittie does not run a cloud sync service. The apps read only the folders and repositories you explicitly select, and push changes directly to the git remotes you configure (such as GitHub).

## No GitKittie account

There is no GitKittie account. No email, no password, no user profile. The apps are local macOS utilities that talk directly to your git host.

## No data collection or telemetry

The apps do not collect, transmit, or store any personal data on GitKittie servers, and do not phone home with telemetry, analytics, or usage data. File contents move directly from your Mac to your own repositories.

## Local data

Configuration (folder paths, repository URLs, sync intervals, board settings) is stored locally on your Mac. Access tokens are stored in the macOS Keychain, not in a plain config file.

## AI features are opt-in and use your own key

GitKittie Bud can draft a commit message for you. This feature is off until you add an API key for an AI provider of your choice, and it is the one case where content leaves your Mac for somewhere other than your git host: to produce a suggestion, the relevant diff and commit context are sent directly from the app to that provider, using your key. There is no GitKittie relay or intermediary, and your key is stored in the macOS Keychain. What the provider does with that request is governed by their privacy policy. If you never configure a key, no AI request is ever made.

## Git host data

Your selected folder or board contents are transmitted directly from your Mac to the repositories you configure so the apps can create and push commits. Those files are stored under your own account with your git host and are subject to that host's privacy policy — for GitHub, GitHub's privacy policy applies.

## Contact

Questions about privacy? Email [me@sil.mt](mailto:me@sil.mt) or open an issue on [GitHub](https://github.com/silvandiepen/gitkittie).
