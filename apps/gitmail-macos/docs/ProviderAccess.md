# Provider access: what Gmail, Microsoft and iCloud require

What each provider asks of a local-first mail client before it may connect, what that costs each year, and how long it takes. Written for GKM-008 on 2026-11-24. Every source was read on that date; prices change, so re-check them before money is committed.

## Summary

- **iCloud:** no approval, no cost. IMAP and SMTP with an app-specific password.
- **Gmail with an app password:** no approval, no cost. Works for personal accounts with 2-Step Verification. Google supports it but calls it "not recommended", and it is unavailable for some accounts.
- **Gmail with OAuth (Gmail API or IMAP):** every scope that can read mail is *restricted*. That means Google's restricted-scope verification and, very likely, a paid third-party security assessment (CASA) **every 12 months**. Reported price: about **US$540–1,800 a year** at the lower assessment tier, **US$4,500–8,000+** at the higher one. Lead time: several weeks to a few months.
- **Does local-only avoid the assessment?** Google's own pages disagree, and a 2026 report says Google required it for a local-only app anyway. Plan as if it is required.
- **Microsoft (Outlook.com and Microsoft 365):** OAuth only for Outlook.com since 16 September 2024. No fee. Publisher verification is free but needs a verified Microsoft partner account and a work account; organisations can still require admin consent.

**Recommendation for MAIL-014:** ship Gmail at first release over IMAP with an app password, through the same IMAP adapter as every other account. Treat OAuth as a second step that needs Sil's go-ahead on the yearly assessment cost. Details in [Recommendation](#recommendation-for-mail-014).

## Gmail

### Scopes

From Google's [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) page (read 2026-11-24):

| Scope | What it allows | Class |
| --- | --- | --- |
| `https://mail.google.com/` | Read, compose, send, and permanently delete all mail. The only scope for IMAP, POP and SMTP with OAuth ([XOAUTH2](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)) | Restricted |
| `gmail.modify` | Read, compose and send; no permanent delete that bypasses Trash | Restricted |
| `gmail.readonly` | View messages and settings | Restricted |
| `gmail.compose` | Manage drafts and send | Restricted |
| `gmail.metadata` | Labels and headers, no bodies | Restricted |
| `gmail.send` | Send only | Sensitive |
| `gmail.labels` | Manage labels only | Non-sensitive |

A mail client has to read mail, so every route to Gmail with OAuth needs at least one restricted scope. The smallest useful set for the Gmail API is `gmail.modify` (it already includes sending). Over IMAP there is no choice: `https://mail.google.com/`.

### What "restricted" requires

1. **OAuth app verification** — brand, domain, homepage, privacy policy, and a justification for each scope. Google says restricted-scope verification "can potentially take several weeks" ([Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification), read 2026-11-24).
2. **The Limited Use rules** of the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy) (last updated 2024-02-15): appropriate access, limited use, secure handling.
3. **A security assessment** by a Google-approved lab under the App Defense Alliance's CASA framework, renewed **every 12 months**, "a comprehensive test of your app" whether or not it changed ([Annual recertification](https://support.google.com/cloud/answer/13463816), [Security assessment](https://support.google.com/cloud/answer/13465431), both read 2026-11-24). The level (AL1/AL2, often called Tier 2/Tier 3) is set by Google by user count, scopes and data handling, and can rise over time.

### Does a local-only design avoid the assessment?

The sources disagree. Stated plainly:

- **For an exemption:** the restricted-scope page ties the assessment to servers: "If you store or transmit restricted scope data on servers, then you need to complete a security assessment", and requires it for apps that can access data "from or through a third-party server" ([Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification), read 2026-11-24). A client where mail goes straight from Google to the Mac would not meet that condition on a literal reading.
- **Against:** Google's help centre says, without any exception, "applications requesting access to restricted scopes must undergo an annual security assessment" ([Security assessment](https://support.google.com/cloud/answer/13465431), read 2026-11-24). Neither Google page mentions local or on-device apps.
- **In practice:** in March 2026 a developer reported that Google's security team told them an assessment was now mandatory for a local-only iOS app ([Google Cloud Community thread, 2026-03-24](https://security.googlecloudcommunity.com/google-security-operations-2/what-happened-to-local-app-gmail-api-access-7138)). This is second-hand, and the community manager's reply was generated by Gemini, not a policy statement. Several 2026 questions about exactly this case on Google's developer forum have no official answer yet ([example, 2026-10-13](https://discuss.google.dev/t/restricted-gmail-scope-in-a-client-only-app-is-a-security-assessment-required/404126)).
- **Our design adds its own doubt:** metadata derived from mail (sender addresses in rules, space names, notes) goes to the user's private CloudKit database, which is an Apple server. Optional Git export goes to a Git host. Whether Google counts either as "transmitting restricted scope data on servers" is not answered anywhere we found.

**Conclusion:** we cannot rely on avoiding the assessment. Google's Trust and Safety team decides during verification. Budget for it, and ask the question in the verification submission.

### What the assessment costs

Google publishes no price; labs set their own. All figures below are third-party, in US dollars, per application, per assessment (so per year).

| Source | Lower tier (Tier 2 / AL1) | Higher tier (Tier 3 / AL2) | Notes |
| --- | --- | --- | --- |
| TAC Security, via [Bright Softwares](https://bright-softwares.com/blog/en/google-workspace/the-50000-gmail-add-on-myth-what-google-s-casa-certification-really-costs) (published 2026-04-27, updated 2026-11-23) | $540–1,800 a year | — | Says the often-repeated $50,000–75,000 figure is wrong for this tier |
| [Switch Labs comparison](https://www.switchlabs.dev/post/casa-tier-2-tier-3-security-review-providers-pricing-and-the-cheapest-option) (prices "as of 2024") | $540 (TAC) to $1,500+ (Bishop Fox); most labs $800–1,500 | $4,500 (TAC) to $8,000+ | Turnaround 1–4 weeks (Tier 2), 2–6 weeks (Tier 3) |
| Developer report, [Google Cloud Community](https://security.googlecloudcommunity.com/google-security-operations-2/what-happened-to-local-app-gmail-api-access-7138) (2026-03-25) | "typically $10k+" | — | Unsourced claim; included because it is the figure people quote |

TAC Security's own pricing page refused automated access (HTTP 403), so the TAC figures are as reported by others. Not in these figures: our own time to fix findings and re-test, and the annual re-test of an app that keeps changing.

**What it means for a one-time price.** If Google places us at the lower tier, US$540–1,800 a year is real but carryable: a few dozen sales a year at a typical one-time price. At the higher tier, US$4,500–8,000+ a year is not carryable for a one-time-price app without either a subscription element or a separate Gmail add-on price. Which tier we get is decided by Google, not by us, and can rise as users grow. **This is the cost that sends the Gmail-with-OAuth question back to Sil (MAIL-012, MAIL-014).**

### Lead times

| Step | Time | Source |
| --- | --- | --- |
| Brand verification | 2–3 business days | [Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification) |
| Restricted-scope review | "several weeks" | same |
| CASA assessment | 1–6 weeks depending on lab and tier | [Switch Labs](https://www.switchlabs.dev/post/casa-tier-2-tier-3-security-review-providers-pricing-and-the-cheapest-option) (2024) |

Plan on two to three months from submission, and submit only with a working build, a public homepage and a privacy policy (GKM-034).

### Before verification: the 100-user limit

- An unverified app shows a warning screen and is limited to **100 new users in total** until verified ([Unverified apps](https://support.google.com/cloud/answer/7454865), read 2026-11-24).
- In "Testing" status, only listed test users can sign in, and refresh tokens **expire after 7 days** for anything beyond basic profile scopes ([Using OAuth 2.0](https://developers.google.com/identity/protocols/oauth2), read 2026-11-24). Beta testers would have to sign in again every week.
- Google also allows a "personal use" exception: an app used only by its developer or a few people they know ([Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)). That would let a technical user register their own Google Cloud project and paste in their own client ID. It is a power-user escape hatch, not a product path.

### Gmail API quotas and charges

Standard use is free. Projects created from 2026-05-01 have new quotas (6,000 units per user per minute; 80,000,000 units per project per day before charges), and Google says charges above that threshold are planned "later in 2026" with at least 90 days' notice ([Gmail API usage limits](https://developers.google.com/workspace/gmail/api/reference/quota), read 2026-11-24). A single client syncing each user's own mailbox should stay far below the daily threshold, but the billing details are not published yet. IMAP does not use these quotas; it has its own limit of 15 simultaneous client connections per account ([Gmail IMAP help](https://support.google.com/mail/answer/7126229), read 2026-11-24).

### Gmail with an app password

- **Supported:** "App passwords can only be used with accounts that have 2-Step Verification turned on." Google calls them "not recommended and unnecessary in most cases" ([Sign in with app passwords](https://support.google.com/accounts/answer/185833), read 2026-11-24). No deprecation is announced.
- **Unavailable** for accounts with 2-Step Verification set up only with security keys, with Advanced Protection, and for some work, school or organisation accounts (same page).
- **Workspace:** password sign-in for IMAP, SMTP and POP ended on 2025-03-14, "with the exception of app passwords" ([Transition from less secure apps to OAuth](https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth), read 2026-11-24). Admins can still restrict them.
- **IMAP is always on** for personal Gmail since January 2025 ([Gmail IMAP help](https://support.google.com/mail/answer/7126229)).
- **Risk:** Google removed "less secure apps" in 2024–2025. App passwords survived that, but nothing guarantees they stay. If Google removes them, Gmail users lose access until OAuth is approved.

### API or IMAP?

| | Gmail API (`gmail.modify`) | IMAP + SMTP with OAuth (`https://mail.google.com/`) | IMAP + SMTP with app password |
| --- | --- | --- | --- |
| Verification and assessment | Yes | Yes | None |
| Yearly cost | Assessment (see above) | Assessment (see above) | €0 |
| Code | A second sync engine (history IDs, labels, API send) | The IMAP adapter (GKM-011) plus Gmail extensions and XOAUTH2 | The IMAP adapter plus Gmail extensions |
| Labels | Native | Via Gmail IMAP extensions | Via Gmail IMAP extensions |
| Scope breadth | Narrower (no permanent delete) | Broadest scope Google has | Full account access via password |
| Who can use it | Everyone | Everyone | Only accounts that can create app passwords |
| Onboarding | Sign in with Google | Sign in with Google | Turn on 2-Step Verification, create an app password, paste it |

Our opinion, not Google's: a reviewer may prefer the narrower `gmail.modify` over `https://mail.google.com/`, but both are restricted and both need the assessment, so scope breadth does not change the cost. The bigger difference is code: IMAP reuses one engine for every provider; the API is a second engine to build, test and keep correct.

## Microsoft (Outlook.com and Microsoft 365)

Microsoft comes later (MAIL-014, GKM-030), so this is shorter.

- **Outlook.com requires OAuth.** "Basic Authentication no longer available to access any Outlook account" since 2024-09-16 ([Microsoft support](https://support.microsoft.com/en-us/topic/c5d65390-9676-4763-b41f-d7986499a90d), read 2026-11-24). That page does not mention app passwords; community answers report they stopped working too. Treat app passwords as unavailable for Outlook.com.
- **Two routes, both OAuth:** Microsoft Graph mail APIs, or IMAP and SMTP with XOAUTH2 using `https://outlook.office.com/IMAP.AccessAsUser.All` and `https://outlook.office.com/SMTP.Send`, which "is available for both Microsoft 365 … and Outlook.com users" ([Authenticate IMAP, POP or SMTP using OAuth](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth), updated 2025-10-17). IMAP with OAuth again reuses our IMAP adapter.
- **Microsoft 365 SMTP:** basic authentication for SMTP AUTH is disabled by default for existing tenants at the end of December 2026; Microsoft will announce the final removal date in the second half of 2027 ([Exchange Team blog, 2026-01-27](https://techcommunity.microsoft.com/blog/exchange/updated-exchange-online-smtp-auth-basic-authentication-deprecation-timeline/4489835)). OAuth is the only route worth building.
- **Publisher verification:** free ("Microsoft doesn't charge developers for publisher verification"), but needs a verified Microsoft AI Cloud Partner Program account, an app registered with a Microsoft Entra work account (not a personal Microsoft account), and a publisher domain that matches the verified one. Once those exist, verification "can be verified in minutes" ([Publisher verification overview](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview), updated 2026-06-15). How long Partner Program verification of Sil's business takes is not stated; allow a few weeks.
- **Without verification:** since November 2020, where risk-based step-up consent is on, users cannot consent to new multitenant apps from unverified publishers that request more than basic sign-in (same page).
- **Admin consent:** by default users may consent to an app reading their own mailbox, but Microsoft recommends organisations allow user consent only for verified publishers, and admins can turn user consent off entirely ([Configure user consent](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent), updated 2026-08-04). In those organisations the user needs an admin to approve GitKittie Mail. Admins can also turn IMAP off for their mailboxes; verify during GKM-030.
- **Cost:** no fee found for delegated mail access, verification or consent. Microsoft 365 App Certification exists but is optional.

## iCloud

- **Hosts:** IMAP `imap.mail.me.com:993` (SSL, TLS as fallback); SMTP `smtp.mail.me.com:587` (SSL, with TLS or STARTTLS as fallbacks), authentication required. IMAP username is the name without the domain (Apple says to try the full address if that fails); SMTP username is the full address. Password is an app-specific password ([iCloud Mail server settings](https://support.apple.com/en-us/102525), read 2026-11-24). No POP.
- **App-specific passwords** need two-factor authentication; up to 25 active at once; changing the Apple Account password revokes all of them ([App-specific passwords](https://support.apple.com/en-us/102654), read 2026-11-24). GKM-010 must handle a revoked password as "sign in again", not as a sync error.
- **Limits:** 1,000 messages a day, 1,000 recipients a day, 500 recipients per message, 20 MB per message (5 GB with Mail Drop) ([iCloud Mail limits](https://support.apple.com/en-us/102198), read 2026-11-24).
- **Cost and approval:** none.

## Recommendation for MAIL-014

**Go: Gmail at first release, over IMAP with an app password.**

1. **First release (Phase 2, GKM-029):** Gmail through the IMAP adapter with Gmail's IMAP extensions (labels, thread IDs) and app-password sign-in. No verification, no assessment, no yearly cost. Onboarding walks the user through 2-Step Verification and creating an app password, and says plainly who cannot use it (security-key-only, Advanced Protection, some work accounts).
2. **Build the adapter so OAuth is only a different sign-in.** XOAUTH2 over the same IMAP and SMTP connections, so adding OAuth later does not mean a second sync engine. Do not build on the Gmail API unless OAuth is approved and IMAP proves inadequate.
3. **OAuth is a separate decision for Sil, before Phase 2 ends:** apply for restricted-scope verification of `https://mail.google.com/` and pay the yearly assessment, expected US$540–1,800 a year at the lower tier and US$4,500–8,000+ if Google sets the higher one. Start at least three months before the release that needs it.
4. **Does local-only avoid the assessment?** Probably not; Google's pages disagree and the one 2026 report says no. Ask Google directly in the verification submission and record the answer here.

Why not OAuth from the start: it adds a cost we cannot size until Google assigns a tier, two to three months of lead time, and a 100-user, 7-day-token limit during testing, all before we know whether people will pay (MAIL-012). The app-password route reaches most personal Gmail users today at no cost; its weaknesses are a clumsier onboarding and the risk that Google removes app passwords.

## Sources

All read on 2026-11-24.

- Google: [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) · [Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification) · [Security assessment](https://support.google.com/cloud/answer/13465431) · [Annual recertification](https://support.google.com/cloud/answer/13463816) · [Restricted scopes list](https://support.google.com/cloud/answer/13464325) · [API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy) (updated 2024-02-15) · [Unverified apps](https://support.google.com/cloud/answer/7454865) · [Using OAuth 2.0](https://developers.google.com/identity/protocols/oauth2) · [XOAUTH2 for IMAP/SMTP](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol) · [Gmail API usage limits](https://developers.google.com/workspace/gmail/api/reference/quota) · [App passwords](https://support.google.com/accounts/answer/185833) · [Workspace: less secure apps to OAuth](https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth) · [Gmail IMAP](https://support.google.com/mail/answer/7126229)
- App Defense Alliance: [CASA](https://www.appdefensealliance.org/standards/casa) (no prices published)
- Third-party, assessment prices: [Bright Softwares](https://bright-softwares.com/blog/en/google-workspace/the-50000-gmail-add-on-myth-what-google-s-casa-certification-really-costs) (2026-04-27, updated 2026-11-23) · [Switch Labs](https://www.switchlabs.dev/post/casa-tier-2-tier-3-security-review-providers-pricing-and-the-cheapest-option) (prices as of 2024)
- Community reports: [Google Cloud Community, local-only Gmail access](https://security.googlecloudcommunity.com/google-security-operations-2/what-happened-to-local-app-gmail-api-access-7138) (2026-03-24) · [Google Developer forum, client-only restricted scope](https://discuss.google.dev/t/restricted-gmail-scope-in-a-client-only-app-is-a-security-assessment-required/404126) (2026-10-13, unanswered)
- Microsoft: [IMAP/POP/SMTP with OAuth](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth) (updated 2025-10-17) · [Publisher verification](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview) (updated 2026-06-15) · [Configure user consent](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent) (updated 2026-08-04) · [Outlook.com basic auth end](https://support.microsoft.com/en-us/topic/c5d65390-9676-4763-b41f-d7986499a90d) · [SMTP AUTH timeline](https://techcommunity.microsoft.com/blog/exchange/updated-exchange-online-smtp-auth-basic-authentication-deprecation-timeline/4489835) (2026-01-27)
- Apple: [iCloud Mail settings](https://support.apple.com/en-us/102525) · [App-specific passwords](https://support.apple.com/en-us/102654) · [iCloud Mail limits](https://support.apple.com/en-us/102198) · [Advanced Data Protection](https://support.apple.com/guide/security/sec973254c5f/web)
