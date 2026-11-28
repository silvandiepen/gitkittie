---
id: MAIL-076
title: "Receipts and other records (transactions at home in Transactions"
date: 2026-11-25
status: accepted
---

# MAIL-076: Receipts and other records (transactions at home in Transactions

**Decision.** Receipts and other records (transactions at home in Transactions: low urgency) are listed in **Focused until read**, then only in Transactions. Their home does not change: it is a rule of the Focused query and the counts (`MailIndex.categoryClause`, `isInFocusedWhileUnread`), so reading or marking unread moves them at once. While unread they count in Focused's unread count and the Dock badge; they do not notify by themselves (MAIL-041 notifies by home). Muted or silently archived ones stay out. The open row stays in the list while it is read and goes with the next reload

**Why.** Decided by Sil (GKM-018), replacing "only in Transactions". `StoreClassificationTests` and `ClassificationAppTests.testAReceiptStaysInFocusedUntilReadThenOnlyInTransactions`. GKM-042

**Links.** MAIL-041, GKM-018, GKM-042
