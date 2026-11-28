---
config: review
id: PETS-3-onboarding
card: PETS-3
title: Onboarding page
requested_by: claude
checks:
  - id: onboarding-page
    url: https://preview-95.example.app/onboarding
    title: Onboarding page on the new site
    note: Preview of PR 95.
    sizes: [phone, Desktop, 1080x1920, { id: kiosk, label: Kiosk, width: 1080, height: 1920, ua: desktop }, { id: tablet, label: iPad }, mystery]
    appearance: [light, dark, sepia, dark]
    checklist:
      - id: hero
        text: The headline fits without an awkward break
      - The download button shows without scrolling
      - { text: "" }
    revises: onboarding-old
    on_accept: { move: PETS-31, to: testing }
    results:
      phone.light:
        viewport: 402x874
        by: sil
        at: 2026-11-30T10:05:12Z
        screenshot: results/onboarding-page-phone.light.png
        answers:
          hero: { result: pass, at: 2026-11-30T10:04:40Z }
          the-download-button-shows-without-scroll: { result: fail, note: Below the fold., at: 2026-11-30T10:04:58Z }
      desktop.dark:
        answers:
          hero: { result: note, note: Looks off }
          the-download-button-shows-without-scroll: { result: maybe }
      custom:
        viewport: 1012x768
        answers:
          hero: { result: fail }
    status: changes-requested
    decided_by: sil
    decided_at: 2026-11-30T10:06:00Z
    comments:
      - { by: sil, at: 2026-11-30T10:06:00Z, text: "Phone: download button below the fold." }
  - id: plain
    url: http://localhost:5173/
    checklist: [Loads]
  - id: no-url
    title: dropped
---
