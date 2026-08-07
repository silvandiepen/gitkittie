This policy covers the GitKittie apps — **GitKittie Folder**, **GitKittie Kanban** and **GitKittie Bud**. All are local-first apps for Mac, iPhone and iPad. They are designed so that your data never passes through GitKittie servers, because there are none.

## No cloud service

GitKittie does not run a cloud sync service. The apps read only the folders and repositories you explicitly select, and push changes directly to the git remotes you configure, whether that is GitHub, GitLab, or any other host you point them at.

## No GitKittie account

There is no GitKittie account. No email, no password, no user profile. The apps talk directly to your git host.

## No data collection or telemetry

The apps do not collect, transmit, or store any personal data on GitKittie servers, and do not phone home with telemetry, analytics, or usage data. File contents move directly from your Mac to your own repositories.

## Local data

Configuration (folder paths, repository URLs, sync intervals, board settings) is stored locally on your device. Access tokens are stored in the system Keychain, not in a plain config file.

## AI features are opt-in and use your own key

GitKittie Bud can draft a commit message for you. This feature is off until you add an API key for an AI provider of your choice, and it is the one case where content leaves your Mac for somewhere other than your git host: to produce a suggestion, the relevant diff and commit context are sent directly from the app to that provider, using your key. There is no GitKittie relay or intermediary, and your key is stored in the macOS Keychain. What the provider does with that request is governed by their privacy policy. If you never configure a key, no AI request is ever made.

## Git host data

Your selected folder or board contents are transmitted directly from your Mac to the repositories you configure so the apps can create and push commits. Those files are stored under your own account with your git host — GitHub, GitLab, or whichever you configure — and are subject to that host's privacy policy.

## When you contact support

Support runs on [Arlez](https://arlez.app), a separate product by the same author. Nothing is sent unless you choose to send it. When you do submit a message, what leaves your device is what you typed, an optional email address if you want a reply, and which app and version the message came from — enough to reproduce the problem and route the answer back. It is used to answer you, and for nothing else.

## Contact

Questions about privacy? Use the support form on the [Support](/support) page — it reaches a person directly.
