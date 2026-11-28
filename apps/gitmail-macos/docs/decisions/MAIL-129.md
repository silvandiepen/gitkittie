---
id: MAIL-129
title: "**A new random archive key per archive, wrapped by a recovery key shown once**"
date: 2026-11-27
status: proposed
---

# MAIL-129: **A new random archive key per archive, wrapped by a recovery key shown once**

**Decision.** **A new random archive key per archive, wrapped by a recovery key shown once**: 128 random bits as 28 Crockford base32 characters in seven groups of four with a 10-bit typo check, turned into the wrapping key by HKDF-SHA256 with a per-archive salt. The Mac shows it with Copy Key and Save as Text File…; Done needs the last four characters typed back; Delete Archive… is the only other way out and removes the archive. The app keeps no copy. **No passphrase in format 1**: CryptoKit has no password-hashing KDF (PBKDF2, scrypt, Argon2), and a passphrase through HKDF could be guessed offline at full speed; the header's `keys` list takes a passphrase slot later without a format change. Open for Sil: review `GKM-032-encrypted-archive` (a passphrase slot through CommonCrypto PBKDF2, and one key per archive or one saved key)

**Why.** A key derived from a passphrase alone was ruled out in the card: people choose guessable ones. 128 random bits can't be guessed and still fit on one line to type; the check makes a typo say "typo" instead of "wrong key". One key per archive means a lost key loses one archive, and needs no key stored on the Mac, where it would sit next to the mail it protects. Typing the last group back is the confirm step: a person who never saved the key can't pass it by clicking. `EncryptedArchiveTests`, `EncryptedArchiveAppTests`. GKM-032

**Links.** GKM-032
