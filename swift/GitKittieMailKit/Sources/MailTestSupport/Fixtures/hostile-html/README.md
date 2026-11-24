# Hostile HTML fixtures

Synthetic messages for the reader's safety tests (GKM-012, ThreatModel §1 and §2). Kept apart
from the classifier corpus one level up, whose `expectations.json` is a classification contract;
these fixtures carry no labels, only attacks. Same rules: reserved domains only (`example.com`,
`example.org`, `example.net`, and `192.0.2.0/24` for an IP link), hand-written, small.

- `hostile-script-variants.eml`: every way we know to run script or navigate: script tags,
  event handlers, `javascript:` and obfuscated schemes, SVG/MathML, iframes and `srcdoc`, plug-ins,
  `<meta refresh>`, `<base>`, forms with a password field, split and unclosed tags. Each script
  would set `data-pwned` on the root element.
- `hostile-css-exfiltration.eml`: `@import`, `@font-face`, attribute-selector exfiltration,
  `url()` in every property that takes one, CSS escapes hiding `url(`, `image-set`, legacy hooks.
- `hostile-tracking-pixels.eml`: pixels by size, by style and by name, `srcset`, `<picture>`,
  media, `<input type=image>`, prefetch/preconnect, `ping`, and one real remote image.
- `hostile-malformed-markup.eml`: broken quoting, comment and CDATA tricks, raw-text elements,
  3,000 nested `div`s, an unterminated comment.
- `lookalike-links.eml`: a spoofed display name, Reply-To elsewhere, link text that shows another
  domain, user-info and IP links, a mixed-script IDN host, blocked schemes, and an inline `cid:`
  image beside a real attachment.

The network tests point every `example.*` URL at a local listener and assert it receives no
connection at all; a control run without the reader's protections proves the fixtures do make
requests and run scripts when nothing stops them.
