This policy covers the GitKittie apps — **GitKittie Folder**, **GitKittie Tasks**, **GitKittie Bud** and **GitKittie Mail**. All are local-first apps for Mac, iPhone and iPad. They are designed so that your files and your mail never pass through GitKittie servers. The one GitKittie service that exists, the optional live-updates relay in GitKittie Tasks described below, never receives file contents.

GitKittie Mail works with a mail account rather than a git repository, so it has [its own section](#gitkittie-mail) below. Everything under "No GitKittie account", "No data collection or telemetry" and "When you contact support" applies to it as well.

## No cloud service

GitKittie does not run a cloud sync service. The apps read only the folders and repositories you explicitly select, and push changes directly to the git remotes you configure, whether that is GitHub, GitLab, or any other host you point them at.

## No GitKittie account

There is no GitKittie account. No email, no password, no user profile. The apps talk directly to your git host.

## No data collection or telemetry

The apps do not collect, transmit, or store any personal data on GitKittie servers, and do not phone home with telemetry, analytics, or usage data. File contents move directly from your device to your own repositories.

## Checking for updates

At most once a day, each app asks Apple's public App Store lookup whether a newer version is out, sending only the app's bundle id and your store country; nothing about you or your files, and nothing to GitKittie.

## Local data

Configuration (folder paths, repository URLs, sync intervals, board settings) is stored locally on your device. Access tokens and passwords are stored in the system Keychain, not in a plain config file.

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

## GitKittie Mail

GitKittie Mail is in development and not on the App Store yet. This section describes the app as it is built today, and will be updated before it ships and whenever what it does with your data changes.

### Your mail goes between your device and your provider only

Mail connects directly to the mail provider you add — iCloud Mail, or any standard IMAP and SMTP account — over encrypted connections (TLS), and to nothing else on its own. There is no GitKittie server in between, no GitKittie account, and no copy of your mail anywhere GitKittie can read. Your provider stays in charge of your mailbox, and what it does with your mail is governed by its own privacy policy.

### Your password stays in the Keychain

The password or app-specific password for each account is stored in the system Keychain on that device only. It is never written to a file, a backup of the mail folder, an export, or a log. Server settings (host names, ports, user names) are stored in your mail folder, without the password, so the same account can be set up on another device by signing in there.

### Your mail is stored as files on your device

Each message is stored as its original `.eml` file, with a readable Markdown copy beside it, in a mail folder on your device. On the Mac that is a folder inside the app's own container unless you choose another; on iPhone and iPad it is the app's folder, which you can see in the Files app. Drafts, spaces and your attachments are files there too.

The search index, the app's cache, and its record of what it has fetched from your provider are kept separately, in the app's private storage on that device. They can be rebuilt from your mail folder and your provider.

These files are included in your device's backups (Time Machine, iCloud Backup or another backup tool) like your other files, unless you exclude them. If you choose a mail folder of your own, other apps and sync tools that can read that folder can read your mail, and the app says so when you choose it. If that folder is synced — for example in iCloud Drive, or one GitKittie Folder pushes to git — that service receives copies of your mail.

### Sorting and search happen on your device

Mail sorts messages into Focused, Transactions, Updates, Subscriptions, Promotions and Quarantine with rules that run on your device. No message, sender or address is sent to GitKittie or to an AI service to do this. Your corrections, sender rules, spaces, notification choices and remote-image choices are stored on your device.

Text in PDF attachments is read on your device so that search can find it.

### When something in a message reaches the internet

Mail never contacts anything a message points to by itself. Only these actions, each one yours, reach a server other than your provider:

- **Remote images.** They are blocked by default. If you choose to load them for a message or a sender, they are fetched from wherever the sender hosts them, which tells that server that the message was opened. Tracking pixels are never loaded, even then.
- **Links.** A link opens in your browser only when you click it and confirm its destination.
- **Unsubscribing.** When you approve an unsubscribe request, the app sends the one request the mailing list asked for, to the address it published, with no cookies; or, for lists that unsubscribe by email, it sends that email from your own account after showing it to you. The app keeps a record of the request on your device to tell you whether the mail stopped.

### Notifications

Notifications for new mail are made on your device by the app and show the sender and the subject. They do not go through any GitKittie server.

### Not built yet: sync between your devices

A later version will sync your spaces, rules and corrections between your devices through your own private iCloud database (CloudKit), and never the messages themselves. That is not in the app today: everything above stays on the device where you set it. This policy will say exactly what is synced, which parts are encrypted, and what Apple can see, before that ships.

### When you remove an account or the app

Removing an account lets you keep, export or remove its local mail, and deletes its password from the Keychain. On iPhone and iPad, deleting the app deletes its mail folder and everything else it stored. On the Mac, a mail folder you chose stays where you put it.

## Contact

Questions about privacy? Use the support form on the [Support](/support) page — it reaches a person directly.
