---
id: TASKS-14
section: "§ 14"
title: "\"Update available\" from Apple's public lookup (GITKITTIE-094)"
date: 2026-11-26
status: accepted
---

# § 14. "Update available" from Apple's public lookup (GITKITTIE-094)

**Decision.** At launch and whenever the app comes forward, at most once a day, every GitKittie
app asks `https://itunes.apple.com/lookup?bundleId=<id>&country=<cc>` for its App Store version
(`AppStoreUpdates` in `swift/GitKittieKit`, its own product so Mail can link it without the git
engine). A newer version this device can install shows a quiet "Update available" card
(`swift/GitKittieUI/UpdateNotice.swift`) with **Update**, which opens `itms-apps://` (iOS) or
`macappstore://` (Mac), and **Not Now**, which hides that version only. In Tasks it sits where the
"New board" suggestion does: the bottom of the Mac sidebar, the home screen on iPhone and iPad.

- The Mac asks for the Mac record (`entity=desktopSoftware`): Tasks and Folder are universal
  purchases, and without it Apple answers with the iPhone version and the iOS minimum (17.0).
- The store country is the device locale's region; Apple's `Storefront` gives a three-letter code
  the lookup does not take.
- Only a copy the App Store installed asks: `AppTransaction` must be verified and from the
  production environment, so debug builds, TestFlight and local builds stay quiet. StoreKit is
  only asked when the bundle holds a non-empty production receipt (`AppDistribution.receipt(at:)`):
  asked without one, it fetches the receipt from the store, and on a Mac that shows "Sign in to
  your Apple Account" at launch (GITKITTIE-110, a team-signed Release build of Tasks).
- Offline or an unreadable answer is silent and is not counted as a check; an app not in the store
  (Mail, Bud today) gets no offer.

**Status.** Accepted.
