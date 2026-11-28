---
id: MAIL-117
title: "**One device runs automatic work per account.** The account's settings name it..."
date: 2026-11-27
status: proposed
---

# MAIL-117: **One device runs automatic work per account.** The account's settings name it...

**Decision.** **One device runs automatic work per account.** The account's settings name it (`coordinator`: device id and model name); it is the device that turned active mode on, and another device takes over only by hand ("Run on this iPhone instead"), never by itself. After each sync the coordinating device runs every active policy, and archives what provider-archiving rules silenced, only when its sync is connected and has finished a pass (`watching`, `lastCompletedPass`), the replay is not offline and its journal has nothing waiting or failed (`OrganisationPause`); otherwise it waits and says why (offline, sign in, catching up, changes on the way, runs on your Mac). Mail a rule silenced while it waited is archived when it resumes; that list is kept in memory, so after a quit such mail stays sorted here and in its folder at the provider (the safe side). Every other device shows the dry runs and the history but moves nothing automatically. Until GKM-026 shares the settings, each device has its own: two devices turned on separately each run their own policies, and a move both make is sent once (the second is superseded, MAIL-035)

**Why.** Classification.md, Retention: "single coordinating device; pause destructive operations offline until reconciled". A takeover by hand mirrors GKM-026's writer lease (MAIL-121, proposed). Whether the two should be one device is asked in review GKM-031-organisation. Two devices on one GreenMail account: `OrganisationAppTests.testOnlyTheCoordinatingDeviceMovesMailATakeoverMovesThatRoleAndAStoppedDeviceWaits`. GKM-031

**Links.** GKM-026, MAIL-035, MAIL-121, GKM-031
