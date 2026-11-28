---
id: MAIL-091
title: "The iOS UI tests run `performAccessibilityAudit` for every audit type on the main..."
date: 2026-11-26
status: proposed
---

# MAIL-091: The iOS UI tests run `performAccessibilityAudit` for every audit type on the main...

**Decision.** The iOS UI tests run `performAccessibilityAudit` for every audit type on the main screens, at the default size and at Accessibility XXXL (`testMainScreensAtLargestTextSize`, which adds its account at the default size and relaunches on the same named UI-test store: at XXXL iOS's Save Password offer is taller than the screen). Skips are only in `AccessibilityAuditPolicy`, each with its reason: the system bars and search field; text behind the keyboard or under the bottom toolbar's glass; Dynamic Type "partially unsupported" on text that does scale (checked at XXXL instead); a menu Picker's value, one-line text fields and a message row's multi-line subject reported clipped while whole; reports that name no element

**Why.** The bars, keyboard, pickers and fields are the system's; everything else is ours to fix

**Links.** none
