---
id: MAIL-086
title: "Clicking or tapping a notification opens its conversation on both platforms, through..."
date: 2026-11-25
status: proposed
---

# MAIL-086: Clicking or tapping a notification opens its conversation on both platforms, through...

**Decision.** Clicking or tapping a notification opens its conversation on both platforms, through one `UNUserNotificationCenterDelegate` (`MailNotificationResponder`, in the shared model) set before launch finishes: the list keeps its view when it already shows the conversation, otherwise it goes to the message's home view with the search cleared; the notified message is expanded and marked read, as if chosen; on iPhone the reader is pushed. A notification that launches the app waits for the store to open. A message no longer stored says so. A summary of several only brings the app forward. Notifications still show only while the app is not in front (no `willPresent`)

**Why.** The notification already carries the local message id (MAIL-041), never content, so opening it needs nothing new in the payload. The delegate's methods are nonisolated and only the id crosses to the main actor, which keeps Swift 6's isolation checks out of the system's callback queue. GKM-037

**Links.** MAIL-041, GKM-037
