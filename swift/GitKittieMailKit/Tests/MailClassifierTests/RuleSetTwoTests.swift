import XCTest
import MailCore
import MailClassifier

/// GKM-017: the Public Suffix List, the gkm-rules-2 fixes for the GKM-007 weaknesses (each with
/// the case that must still be caught), and where each verdict lives in the window.
final class RuleSetTwoTests: XCTestCase {
    // MARK: Public Suffix List

    func testRegistrableDomainsFollowThePublicSuffixList() {
        let list = PublicSuffixList.shared
        XCTAssertFalse(list.version.isEmpty)
        XCTAssertEqual(list.registrableDomain(of: "login.bank.example.co.uk"), "example.co.uk")
        XCTAssertEqual(list.registrableDomain(of: "www.shop.co.uk"), "shop.co.uk")
        XCTAssertEqual(list.registrableDomain(of: "a.b.c.com"), "c.com")
        XCTAssertEqual(list.publicSuffix(of: "news.example.com.au"), "com.au")
        // Private section: a site on a shared host is its own organisation.
        XCTAssertEqual(list.registrableDomain(of: "someone.github.io"), "someone.github.io")
        // Wildcard and exception rules (*.ck, !www.ck).
        XCTAssertEqual(list.registrableDomain(of: "shop.other.ck"), "shop.other.ck")
        XCTAssertEqual(list.registrableDomain(of: "www.ck"), "www.ck")
        // Unlisted top-level domain: one label.
        XCTAssertEqual(list.registrableDomain(of: "mail.internal.zz-unlisted"), "internal.zz-unlisted")
        // Internationalised suffixes match in their xn-- form, whichever form the host is in.
        XCTAssertEqual(list.registrableDomain(of: "shop.例え.jp"), "xn--r8jz45g.jp")
        // The reserved documentation domains keep fixtures' subdomains apart.
        XCTAssertEqual(list.registrableDomain(of: "accounts.cloudvault.example.com"), "cloudvault.example.com")
        XCTAssertEqual(list.registrableDomain(of: "co.uk"), "co.uk", "a bare suffix stays as it is")
    }

    func testLookalikesUseTheRegistrableDomain() {
        let trusted: Set<String> = ["cloudvault.co.uk"]
        XCTAssertEqual(DomainCheck.lookalikeTarget(ofHost: "login.c1oudvault.co.uk", trusted: trusted), "cloudvault.co.uk")
        XCTAssertNil(DomainCheck.lookalikeTarget(ofHost: "mail.cloudvault.co.uk", trusted: trusted))
        XCTAssertEqual(DomainCheck.organisationDomain(of: "mail.cloudvault.co.uk"), "cloudvault.co.uk")
    }

    func testABarePublicSuffixIsNobodysOrganisation() {
        // Found end to end: people write from addresses directly at a reserved example domain.
        XCTAssertTrue(DomainCheck.isPublicSuffix("example.org"))
        XCTAssertTrue(DomainCheck.isPublicSuffix("co.uk"))
        XCTAssertFalse(DomainCheck.isPublicSuffix("shop.co.uk"))
        XCTAssertNil(DomainCheck.lookalikeTarget(ofHost: "example.com", trusted: ["example.org"]))
        XCTAssertNil(DomainCheck.lookalikeTarget(ofHost: "co.uk", trusted: ["co.nz"]))
    }

    // MARK: Click trackers

    private func campaign(href: String, text: String, subject: String = "15% off beans this week",
                          from: String = "news@news.larkspur.example.com", list: Bool = true) -> ClassificationInput {
        ClassificationInput(
            from: MailAddress(name: "Larkspur", address: from), subject: subject,
            headers: list ? [.init(name: "List-ID", value: "<offers.larkspur.example.com>"),
                             .init(name: "List-Unsubscribe", value: "<https://larkspur.example.com/u>")] : [],
            htmlBody: "<p><a href=\"\(href)\">\(text)</a></p>")
    }

    func testASendersOwnClickTrackerIsNotDeception() {
        let verdict = MailClassifier().classify(campaign(href: "https://click.mailrelay.example.net/c?u=1",
                                                         text: "https://larkspur.example.com/beans"))
        XCTAssertEqual(verdict.risk, .none)
        XCTAssertEqual(verdict.purpose, .promotion)
        XCTAssertTrue(verdict.reasons.contains(.trackedLink))
        XCTAssertFalse(verdict.reasons.contains(.linkTextMismatch))
    }

    func testATrackerStillCountsAsDeceptionWhenItMatters() {
        let classifier = MailClassifier()
        // Text shows another organisation than the sender's.
        XCTAssertEqual(classifier.classify(campaign(href: "https://click.mailrelay.example.net/c",
                                                    text: "https://nordbank.example.com/login")).risk, .phishing)
        // An account claim in the subject.
        XCTAssertEqual(classifier.classify(campaign(href: "https://click.mailrelay.example.net/c", text: "https://larkspur.example.com/a",
                                                    subject: "Verify your account")).risk, .phishing)
        // A payment claim in the subject.
        XCTAssertEqual(classifier.classify(campaign(href: "https://click.mailrelay.example.net/c", text: "https://larkspur.example.com/a",
                                                    subject: "Invoice overdue")).risk, .phishing)
        // Not bulk mail: a one-to-one message with a disguised link.
        XCTAssertEqual(classifier.classify(campaign(href: "https://click.mailrelay.example.net/c", text: "https://larkspur.example.com/a",
                                                    list: false)).risk, .phishing)
    }

    // MARK: Discussion lists

    private func listPost(from: String = "ravi.patel@example.org", post: String? = "<mailto:walkers@lists.example.org>",
                          extra: [ClassificationInput.Header] = [], subject: String = "[Walkers] Saturday?") -> ClassificationInput {
        var headers: [ClassificationInput.Header] = [.init(name: "List-ID", value: "<walkers.lists.example.org>"),
                                                     .init(name: "List-Unsubscribe", value: "<mailto:leave@lists.example.org>")]
        if let post { headers.append(.init(name: "List-Post", value: post)) }
        return ClassificationInput(from: MailAddress(address: from), subject: subject, headers: headers + extra, textBody: "Who's in?")
    }

    func testAPersonPostingToADiscussionListIsAConversation() {
        let verdict = MailClassifier().classify(listPost())
        XCTAssertEqual(verdict.purpose, .conversation)
        XCTAssertTrue(verdict.reasons.contains(.listDiscussion))
        XCTAssertEqual(verdict.home, .focused)
    }

    func testAnnouncementListsAndCampaignsStaySubscriptions() {
        let classifier = MailClassifier()
        XCTAssertEqual(classifier.classify(listPost(post: "NO")).purpose, .subscription, "announcement list")
        XCTAssertEqual(classifier.classify(listPost(post: nil)).purpose, .subscription, "no List-Post")
        XCTAssertEqual(classifier.classify(listPost(from: "editor@news.example.org")).purpose, .subscription, "role sender")
        XCTAssertEqual(classifier.classify(listPost(extra: [.init(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click")])).purpose,
                       .subscription, "one-click unsubscribe is a bulk sender's mark")
        XCTAssertEqual(classifier.classify(listPost(subject: "Club sale: 20% off boots")).purpose, .promotion)
    }

    // MARK: Keyword collisions

    func testAPersonMentioningAPasswordIsNotASecurityAlert() {
        let classifier = MailClassifier()
        let reply = classifier.classify(.init(from: MailAddress(address: "mila.novak@example.org"), subject: "Re: wifi password",
                                              headers: [.init(name: "In-Reply-To", value: "<a@example.net>")], textBody: "On the card."))
        XCTAssertEqual(reply.purpose, .conversation)
        let note = classifier.classify(.init(from: MailAddress(address: "mila.novak@example.org"), subject: "The wifi password",
                                             textBody: "On the fridge."))
        XCTAssertEqual(note.purpose, .conversation)
        // A function sending it is still account mail.
        let alert = classifier.classify(.init(from: MailAddress(address: "security@cloudvault.example.com"), subject: "Your password was changed",
                                              textBody: "If this was not you, contact us."))
        XCTAssertEqual(alert.purpose, .security)
        XCTAssertEqual(alert.urgency, .high)
    }

    func testAPersonalLookingPhishStillCountsItsClaimForRisk() {
        let context = ClassificationContext(trustedAuthServIDs: ["mx.example.net"])
        let verdict = MailClassifier(context: context).classify(.init(
            from: MailAddress(address: "john.smith@cloudvault-help.example.net"), subject: "Your password expires today",
            headers: [.init(name: "Authentication-Results", value: "mx.example.net; spf=fail; dkim=none; dmarc=fail")],
            textBody: "Keep it here."))
        XCTAssertEqual(verdict.risk, .phishing, "the credential claim with failed authentication is phishing whoever 'sent' it")
        XCTAssertEqual(verdict.home, .quarantine)
    }

    func testYourOrderInAnOfferIsAPromotionButARealOrderIsNot() {
        let classifier = MailClassifier()
        let offer = classifier.classify(.init(from: MailAddress(address: "offers@shop.example.com"), subject: "20% off your order this weekend",
                                              headers: [.init(name: "List-Unsubscribe", value: "<https://shop.example.com/u>")],
                                              textBody: "Prices from EUR 20."))
        XCTAssertEqual(offer.purpose, .promotion)
        XCTAssertTrue(offer.reasons.contains(.offerNotOrder))
        let order = classifier.classify(.init(from: MailAddress(address: "orders@shop.example.com"), subject: "Your order: 20% off next time",
                                              textBody: "Order #482113. Total EUR 30.00."))
        XCTAssertEqual(order.purpose, .transaction, "an order number makes it the order")
        let receipt = classifier.classify(.init(from: MailAddress(address: "orders@shop.example.com"), subject: "Your receipt - 20% off next time",
                                                textBody: "Total EUR 30.00."))
        XCTAssertEqual(receipt.purpose, .transaction, "strong transaction words always win over an offer")
    }

    // MARK: Transactions and urgency

    func testTransactionUrgencyDecidesFocused() {
        let classifier = MailClassifier()
        func verdict(_ subject: String) -> Classification {
            classifier.classify(.init(from: MailAddress(address: "billing@notely.example.org"), subject: subject, textBody: "USD 48.00"))
        }
        XCTAssertEqual(verdict("Payment failed for your plan").urgency, .high)
        XCTAssertEqual(verdict("Payment failed for your plan").home, .focused)
        XCTAssertEqual(verdict("Invoice 2026-04").urgency, .normal)
        XCTAssertEqual(verdict("Invoice 2026-04").home, .focused)
        XCTAssertEqual(verdict("Payment received").urgency, .low)
        XCTAssertEqual(verdict("Payment received").home, .transactions)
    }

    // MARK: Provider junk folder

    func testTheProvidersJunkFolderIsItsVerdict() {
        let input = { (folders: [String]) in
            ClassificationInput(from: MailAddress(address: "desk@prizes.example.net"), subject: "Hello", textBody: "Hi",
                                provider: ProviderSignals(folders: folders))
        }
        for folder in ["Junk", "[Gmail]/Spam", "INBOX.Spam", "Junk E-mail"] {
            let verdict = MailClassifier().classify(input([folder]))
            XCTAssertEqual(verdict.risk, .spam, folder)
            XCTAssertTrue(verdict.reasons.contains(.providerJunkFolder), folder)
        }
        XCTAssertEqual(MailClassifier().classify(input(["INBOX", "Archive"])).risk, .none)
        XCTAssertEqual(MailClassifier().classify(input(["Projects/Junkyard"])).risk, .none, "only the folder's own name counts")
    }

    // MARK: Categories

    func testEveryVerdictHasOneHomeAndQuarantineWins() {
        for purpose in MailPurpose.allCases {
            for urgency in MailUrgency.allCases {
                XCTAssertEqual(MailCategory.home(purpose: purpose, risk: .phishing, urgency: urgency), .quarantine)
                XCTAssertEqual(MailCategory.home(purpose: purpose, risk: .spam, urgency: urgency), .quarantine)
                let home = MailCategory.home(purpose: purpose, risk: .suspicious, urgency: urgency)
                XCTAssertNotEqual(home, .quarantine, "suspicious mail stays visible")
            }
        }
        XCTAssertEqual(MailCategory.home(purpose: .unknown, risk: .none, urgency: .normal), .focused, "uncertain mail is never hidden")
        XCTAssertEqual(MailCategory.home(purpose: .security, risk: .suspicious, urgency: .normal), .focused)
        XCTAssertEqual(MailCategory.home(purpose: .promotion, risk: .none, urgency: .low), .promotions)
        XCTAssertEqual(MailCategory.home(purpose: .notification, risk: .none, urgency: .normal), .updates)
        XCTAssertEqual(MailCategory.home(purpose: .notification, risk: .none, urgency: .high), .focused)
        XCTAssertFalse(MailCategory.promotions.asksForAttention)
        XCTAssertTrue(MailCategory.focused.asksForAttention)
    }
}
