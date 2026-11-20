This policy covers the GitKittie apps — **GitKittie Folder**, **GitKittie Tasks** and **GitKittie Bud**. All are local-first apps for Mac, iPhone and iPad. They are designed so that your files never pass through GitKittie servers. The one GitKittie service that exists, the optional live-updates relay described below, never receives file contents.

## No cloud service

GitKittie does not run a cloud sync service. The apps read only the folders and repositories you explicitly select, and push changes directly to the git remotes you configure, whether that is GitHub, GitLab, or any other host you point them at.

## No GitKittie account

There is no GitKittie account. No email, no password, no user profile. The apps talk directly to your git host.

## No data collection or telemetry

The apps do not collect, transmit, or store any personal data on GitKittie servers, and do not phone home with telemetry, analytics, or usage data. File contents move directly from your device to your own repositories.

## Local data

Configuration (folder paths, repository URLs, sync intervals, board settings) is stored locally on your device. Access tokens are stored in the system Keychain, not in a plain config file.

## AI features are opt-in and use your own key

GitKittie Bud can draft a commit message for you, and GitKittie Tasks can draft a task's title and description from a screenshot and your comments. These features are off until you choose how they run:

- **With your own API key** for an AI provider of your choice. This is the one case where content leaves your device for somewhere other than your git host: to produce a suggestion, the relevant content — the diff and commit context in Bud; the image, the text recognised in it and your comments in Tasks — is sent directly from the app to that provider, using your key. There is no GitKittie relay or intermediary, and your key is stored in the system Keychain. What the provider does with that request is governed by their privacy policy.
- **On the device**, in GitKittie Tasks on an iPhone or iPad with Apple Intelligence. The text in the image is recognised on the device and the draft is written by the on-device model. Nothing is sent anywhere.

If you never configure a key and never choose the on-device option, no AI request is ever made.

When you create a task from a screenshot in GitKittie Tasks, the model, iOS version, screen size, appearance and text size of your device are added to the task's text unless you switch that off. Like the rest of the task, that goes to your own repository and nowhere else.

## Live updates in GitKittie Tasks are opt-in

GitKittie Tasks can refresh an open board when someone pushes to its repository. This is off until you turn it on for a repository. When it is on, your git host calls a small relay run by GitKittie (hosted on Cloudflare) each time someone pushes, and the relay tells the open apps which files changed.

- The relay receives the repository's name, the branch, the commit id and the **paths** of the files that changed. It never receives file contents or your access token.
- For each repository with live updates on, the relay stores the repository's name, two random keys, a random id of the app install that turned it on, and the time it was created. It does not store the paths it relays.
- Cloudflare, which hosts the relay, processes the requests made to it under its own privacy policy.
- Turning live updates off removes the webhook from your repository and deletes the relay's record for it.

## Agent Access stays on your Mac

GitKittie Tasks on the Mac can let coding agents on the same Mac work with your boards. This is off until you turn it on. It listens on your Mac only, is not reachable from other machines, and involves no GitKittie server. What an agent you connect does with what it reads is up to that agent and its provider.

## Git host data

Your selected folder or board contents are transmitted directly from your Mac to the repositories you configure so the apps can create and push commits. Those files are stored under your own account with your git host — GitHub, GitLab, or whichever you configure — and are subject to that host's privacy policy.

## When you contact support

Support runs on [Arlez](https://arlez.app), a separate product by the same author. Nothing is sent unless you choose to send it. When you do submit a message, what leaves your device is what you typed, an optional email address if you want a reply, and which app and version the message came from — enough to reproduce the problem and route the answer back. It is used to answer you, and for nothing else.

## Contact

Questions about privacy? Use the support form on the [Support](/support) page — it reaches a person directly.
