---
id: TASKS-16
section: "§ 16"
title: "The calendar scrolls through weeks; a change with nothing stored can only be removed (GITKITTIE-111/113)"
date: 2026-11-27
status: accepted
---

# § 16. The calendar scrolls through weeks; a change with nothing stored can only be removed (GITKITTIE-111/113)

**Decision.**

- **Calendar.** The Mac calendar is one column of weeks, five to a screen, from a year before to a
  year after today (further when a task is due further out), opening on this month
  (`BoardCalendar` in GitKanbanKit). The title names the month two weeks below the top row; the
  arrows and Today jump by month. It was one month sized to the window: with 300 tasks the
  scroll range was 0 pt, so scrolling did nothing. The 1st of a month shows the month's name and
  months alternate in shade; "N more" opens the day's tasks. The scroll position is only handed
  to the header, so scrolling redraws the title, not the weeks.
- **Unsendable changes.** A refused write whose content is not on this device (made while the
  disk was full) can never be sent. It shows Remove (no confirmation: nothing to lose) instead of
  Retry, Show and Discard, and Retry All skips it (`AppModel.unsendableSyncIDs`).

**Status.** Accepted.
