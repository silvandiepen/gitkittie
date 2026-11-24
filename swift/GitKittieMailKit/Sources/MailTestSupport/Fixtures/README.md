# Mail fixtures

Synthetic messages for tests (GKM-003). Every address uses a reserved domain such as
`example.com`, `example.org` or `example.net`. Never add real mail, even with consent.
Every person, shop and service is invented; `FixtureCorpusTests` fails on any other host.

## Files

- `*.eml`: one message each, CRLF line endings (except `mal-bare-lf-line-endings.eml`).
  `.gitattributes` marks them `-text` so Git never rewrites the bytes.
- `expectations.json`: per file the expected `purpose`, `risk`, `urgency` (Classification.md
  taxonomy), the parse `outcome` (`ok`, `recovered`, `limited`) and exact parse `warnings`,
  `language`, `tags`, an optional modelled `providerVerdict` and `duplicateGroup`. `context`
  is the mailbox the corpus is addressed to (`alex.morgan@example.net`): its trusted
  `authserv-id`, known correspondents and trusted sender domains.

Name prefixes: `conv-`, `txn-`, `sec-`, `notif-`, `sub-`, `promo-`, `phish-`, `spam-`, and
`mal-` for malformed or hostile structure.

## Rules for new fixtures

- Hand-write them; keep them small. Describe huge payloads with headers (`size=` on
  Content-Disposition), never commit them.
- Add the expectation in the same change; the tests reject a fixture without one.
- A risky message keeps the purpose it claims (a fake invoice is `transaction` with risk
  `phishing`).
- The parse warnings are the contract for the real MIME library (GKM-002): it must report the
  same problems, whatever it calls them.
