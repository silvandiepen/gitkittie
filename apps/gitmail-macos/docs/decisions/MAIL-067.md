---
id: MAIL-067
title: "The app model (`AppModel`, the browser, actions, accounts and sync, sending, spaces,..."
date: 2026-11-25
status: proposed
---

# MAIL-067: The app model (`AppModel`, the browser, actions, accounts and sync, sending, spaces,...

**Decision.** The app model (`AppModel`, the browser, actions, accounts and sync, sending, spaces, senders, cleanup) is one UI-free source folder, `swift/MailAppModel`, compiled by the Mac app, the iPhone and iPad app and the Mac app's tests; views stay per platform (`apps/gitmail-macos/GitMail/Views`, `apps/gitmail-ios/GitMail/Views`). Platform differences sit behind `#if os` in the few places the APIs differ (quarantine, security-scoped bookmarks, the XPC extractor) and in `DeviceWords` ("this Mac" / "this iPhone")

**Why.** One behaviour on both platforms, tested once (MAIL-050). A source folder like `swift/GitKittieUI`, not a package, because the model is app-internal and a package would make every type public for no consumer. GKM-027

**Links.** MAIL-050, GKM-027
