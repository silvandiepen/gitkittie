# Product concept

## Keep the conversations. Lose the noise.

GitKittie Mail is a proposed local-first email client that works with your existing address and provider. Separate communication from marketing and automated noise, organise important information around your life and work, and keep important email in open formats you own. The reason to switch is a calmer inbox, not Git. File ownership is the architectural advantage. No mandatory GitKittie account, subscription, AI service or migration for core mail. No ads or resale of mail data. One-time universal Apple-platform purchase is a hypothesis, not a commitment.

## Audience and positioning

Freelancers, independent businesses, developers, knowledge-management users, privacy-conscious Apple users, people with multiple accounts or years of accumulated mail. Not just Git users. Existing clients already offer classification, search or local storage; differentiate through the combination of sender controls, retention, project organisation, open files and provider independence. Validate willingness to pay using a working cleanup experience and interviews. Do not claim exclusivity or unimplemented capabilities.

## Everyday experience

- Unified inbox, account views, receive, compose, reply, reply-all, forward, drafts, sent, archive, trash, spam, flags and attachments.
- Focused inbox for conversations, important transactions and security alerts. Separate Transactions, Updates, Subscriptions, Promotions, Quarantine and All Mail views. Uncertain messages stay visible.
- Marketing as a disposable feed, grouped by company or list. Review counts, latest messages, mute, unsubscribe and expiry. Promotions do not contribute to the main unread badge by default.
- Sender management shows volume, categories, last received and local reading history. Keep receipts while muting offers from the same retailer. Policies per list and purpose, not just domain.
- Subscription manager identifies legitimate lists, suggests review, supports confirmed unsubscribe and reports outcomes. Never open suspicious unsubscribe links automatically.
- Cleanup onboarding: progressive import, mailbox breakdown, top noisy senders, samples, suggested actions, correction and optional reversible cleanup. No destructive initial import.
- Spaces: virtual collections by project, topic, person, company or life area, across accounts; an email may belong to multiple spaces without duplication. Rules populate spaces. Linked tasks, notes and attachments appear in context.
- Settings (⌘, on the Mac; Settings ▸ an account on iPhone and iPad): accounts and their order; per account its names, password and servers, and its mailboxes: which sync, which show and in what order, which folder is Sent, Drafts, Archive, Trash and Junk, and folders made, renamed and deleted at the provider (GKM-066, MAIL-093..097).
- Local search with account, participant, category, date, attachment, space, status and subject filters; extract supported attachment text. Later optional local semantic search.
- Waiting for reply, follow-up views, contact timelines, attachment library, stable links, Markdown composer delivering ordinary MIME. GitKittie Tasks integration through stable identifiers and explicit export, not cross-app imports.

## Organisation modes

Virtual mode is default: classification does not change provider folders or flags. Explicit normal mail actions still work. Active mode is opt-in per account and rule, previews scope, respects provider capabilities and uses reversible moves before optional retention deletion. Apple Mail and other clients continue to work. Automatic rules run only when a capable device or optional service is active. Built (GKM-031, MAIL-115..119): Settings ▸ Organisation turns active mode on per account; retention policies per category and sender rules' archive at the provider move mail only then, each previewed as a dry run first, run by one coordinating device that pauses while offline, logged in a History without mail content and undone from there.

## Onboarding and marketing

Connect securely; explain permissions and per-device authentication. Fetch recent messages first then history, with cancellation and storage budgets. Show mailbox composition and samples; offer focused inbox immediately, then cleanup suggestions, private metadata sync and optional archive separately.

Suggested copy: **Keep the conversations. Lose the noise.** Connect your existing email, separate marketing from important messages, organise conversations around your projects and keep the emails you want in files you own.

Supporting messages: Keep your address. Find the important stuff. Control what reaches your inbox. Your mail, your files. Website launch follows existing conventions including support, terms, privacy and SEO requirements. Only advertise shipped functionality.

## Measures

Track important-message false suppression, correction rate, cleanup reversals, time to find known email, duplicate sends, sync discrepancies, storage and onboarding completion. Prefer on-device metrics and consenting tests; never upload mail content for analytics. Trust and correctness are release gates.
