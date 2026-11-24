import Foundation

// Deterministic template vocabulary (Classification.md, step 4) in English, Dutch, German,
// Japanese and Greek. Lower-case substrings matched against a lower-cased subject (and, where
// stated, body). Substring matching is deliberate: it works for scripts without word spaces.
// Each list is part of the rule set; changing one changes `MailClassifier.ruleSetVersion`.
enum Templates {
    /// Words that name a one-time code. Matched in subject or body, and only count with a code.
    static let securityCode = [
        "verification code", "security code", "login code", "sign-in code", "one-time code", "one-time password", "your code",
        "inlogcode", "verificatiecode", "beveiligingscode", "bestätigungscode", "sicherheitscode", "anmeldecode", "einmalcode",
        "認証コード", "確認コード", "ワンタイム", "κωδικός επαλήθευσης", "κωδικός μίας χρήσης",
    ]

    /// Account security events. Subject only.
    static let securityAlert = [
        "new sign-in", "sign-in attempt", "signed in", "password", "unusual activity", "suspicious activity", "account locked",
        "account will be closed", "verify your account", "security alert", "two-factor",
        "wachtwoord", "nieuwe aanmelding", "inlogpoging", "account geblokkeerd",
        "passwort", "neue anmeldung", "konto wurde gesperrt", "gesperrt", "sicherheitswarnung",
        "パスワード", "新しいログイン", "不正なログイン", "κωδικός πρόσβασης", "νέα σύνδεση",
    ]

    /// Parcel and shipping progress: notifications, not transactions. Subject only.
    static let delivery = [
        "out for delivery", "has shipped", "has been shipped", "on its way", "has been delivered", "track your parcel", "your parcel",
        "wordt vandaag bezorgd", "is onderweg", "je pakket", "uw pakket", "zustellung", "ihr paket", "wurde versandt",
        "発送しました", "配達", "η αποστολή σας",
    ]

    /// Receipts, orders, invoices, payments, travel. Subject only.
    static let transaction = [
        "receipt", "order confirmation", "your order", "order #", "order no", "invoice", "payment received", "payment confirmation",
        "payment failed", "booking confirmed", "booking confirmation", "e-ticket", "itinerary", "refund",
        "bestelling", "bestelbevestiging", "factuur", "betaling", "ontvangstbewijs", "boekingsbevestiging",
        "bestellbestätigung", "bestellung", "rechnung", "zahlungsbestätigung", "buchungsbestätigung",
        "ご注文", "注文番号", "領収書", "請求書", "予約確認",
        "απόδειξη", "παραγγελία", "τιμολόγιο", "κράτηση",
    ]

    /// Offers and campaigns. Subject only; a percentage in the subject also counts.
    static let promotion = [
        "sale", "% off", "discount", "coupon", "deal", "offer", "free shipping", "shop now", "limited time",
        "korting", "aanbieding", "uitverkoop", "rabatt", "angebot", "gutschein", "reduziert",
        "セール", "割引", "クーポン", "特価", "έκπτωση", "εκπτώσεις", "προσφορά",
    ]

    /// Editorial newsletters and digests. Subject only.
    static let newsletter = [
        "newsletter", "digest", "issue", "weekly", "edition", "bulletin",
        "nieuwsbrief", "samenvatting", "wekelijks", "ausgabe", "rundbrief", "wöchentlich",
        "ニュースレター", "メールマガジン", "ενημερωτικό",
    ]

    /// Phrases of advance-fee and junk mail. Two or more in subject + body.
    static let spamPhrases = [
        "you have won", "you've won", "claim your prize", "lottery", "lucky winner", "processing fee", "wire transfer",
        "inheritance", "guaranteed returns", "double your bitcoin",
        "u heeft gewonnen", "sie haben gewonnen", "当選", "κερδίσατε",
    ]

    /// Senders that are a function, not a person. A role address is never "personal".
    static let roleLocalParts: Set<String> = [
        "info", "support", "help", "noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification", "notify",
        "billing", "invoices", "facturen", "documents", "sales", "marketing", "news", "newsletter", "hello", "team", "admin",
        "security", "accounts", "receipts", "orders", "order", "tracking", "alerts", "alert", "updates", "mailer", "postmaster",
        "offers", "deals", "digest", "bookings", "service", "klantenservice", "kundenservice", "bestellung", "angebote",
        "aanbiedingen", "herinneringen", "reminders", "backup", "editor", "sicherheit", "claims",
    ]

    /// Role senders that announce events rather than sell or converse.
    static let notificationLocalParts: Set<String> = [
        "notifications", "notification", "notify", "alerts", "alert", "updates", "tracking", "reminders", "herinneringen",
        "backup", "monitoring",
    ]

    /// Attachment extensions that run code or render active content when opened.
    static let dangerousExtensions: Set<String> = [
        "exe", "scr", "com", "bat", "cmd", "pif", "js", "jse", "vbs", "vbe", "wsf", "hta", "msi", "jar", "ps1", "lnk",
        "iso", "img", "html", "htm", "svg", "app", "pkg", "dmg",
    ]

    static func firstMatch(_ terms: [String], in text: String) -> String? {
        terms.first { text.contains($0) }
    }
}
