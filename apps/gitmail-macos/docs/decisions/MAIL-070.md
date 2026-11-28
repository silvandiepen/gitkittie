---
id: MAIL-070
title: "The iPhone and iPad app is one universal app with the Mac app's bundle id..."
date: 2026-11-25
status: proposed
---

# MAIL-070: The iPhone and iPad app is one universal app with the Mac app's bundle id...

**Decision.** The iPhone and iPad app is one universal app with the Mac app's bundle id (`app.hakobs.gitmail`, one App Store record, as Tasks), display name Mail, iOS 18 (GitKittieMailProviders' floor), a three-column `NavigationSplitView` that collapses to a stack on iPhone, opening in Focused. UI tests start the app with a fresh folder, its own Keychain service and the test server's CA only in Debug builds (`UITestLaunch`); Release has no such switch

**Why.** Universal purchase and shared Keychain group; one layout for both idioms; a test hook that can trust another CA must not ship. GKM-027

**Links.** GKM-027
