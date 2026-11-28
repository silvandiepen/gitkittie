---
id: MAIL-050
title: "One Mail core for macOS and iOS"
date: 2026-11-24
status: proposed
---

# MAIL-050: One Mail core for macOS and iOS

**Decision.** One Mail core for macOS and iOS: GitKittieMailKit and GitKittieMailProviders build and pass their tests on the iOS Simulator as well as macOS, and CI runs both on an iPhone simulator. Platform code sits behind `#if os` only where the APIs differ (the reader's menus and data detectors, the extraction strategy, an AppKit-only test), never as a second implementation. Package tests run unhosted on iOS, so the reader's WebKit tests run in a test-only host app (`swift/GitKittieMailKit/TestHost`), and the one test that needs a keychain entitlement skips there and runs in the iOS app's hosted tests (GKM-027)

**Why.** The iPhone app (GKM-027) builds on the same store, sync, outbox and reader the Mac uses, so a fix lands once; CI stops a macOS-only API from slipping back in. GKM-025

**Links.** GKM-027, GKM-025
