---
id: MAIL-112
title: "Increase Contrast (GKM-063)"
date: 2026-11-26
status: proposed
---

# MAIL-112: Increase Contrast (GKM-063)

**Decision.** Increase Contrast (GKM-063): every colour in the shared `Theme` (`swift/GitKittieUI`) has a light and a dark value at high contrast (`Theme.Swatch`), picked from `accessibilityContrast == .high` on iOS and from the high-contrast Aqua appearances or `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` on the Mac. On the navy at high contrast: `stroke` #6B7A99 (3.7:1 or more on every surface, from 1.2:1), the window darker (#05080F) and the card lighter (#182236), `accentText` #9DC0FF (7:1 on the navy, 6.2:1 on #3A3A3C), `accentFill` #1A4FB8 (white 7.4:1). `accent` keeps #4F8CFF on the navy; in light at high contrast it is #1F5BD1. Secondary text stays the system's `.secondary`, which already strengthens itself

**Why.** #232D42 hairlines almost vanished on #111827. `accent` is the Mac's tint, under white text in prominent buttons, and text on the navy at once: lighter fails the first, darker the second, so the lighter accent is `accentText`. `NSAppearance(named:)` hands back the plain appearance for a high-contrast name while the setting is off, and the apps pin their windows to `.darkAqua`, so the Mac also reads the setting itself. Views keep using the theme's colours; no app forks its own. Proven by `swift/GitKittieUITests/ThemeTests.swift`, run in both Mail test bundles

**Links.** GKM-063
