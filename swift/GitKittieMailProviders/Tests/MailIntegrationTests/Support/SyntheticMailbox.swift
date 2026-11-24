import Foundation
import MailProvider

/// A large synthetic mailbox for the sync benchmark (GKM-035): deterministic (the same seed
/// gives the same bytes), reserved domains only (example.com/.org/.net), no real mail.
///
/// The mix, per message: 65 % 5–15 KB, 32 % 15–50 KB (text and HTML alternatives), 2.4 % with
/// an attachment of 30–200 KB, 0.5 % with 300 KB–1 MB, 0.1 % with 1–3 MB (`attachmentShare`
/// scales those three and `bodyScale` the text, to fit a large run on a small disk); one in ten HTML
/// messages carries the same inline logo (deduplicated as one blob). About 15 % are replies
/// that link a thread with In-Reply-To and References. 80 % in INBOX, 10 % in Sent, 10 % in
/// Archive (each split into folders of at most `folderSize`, newest in the first); appended
/// oldest first, so UIDs follow the date as at a real provider.
struct SyntheticMailbox {
    struct Spec {
        var index: Int
        var folder: String
        var textBytes: Int
        var attachmentBytes: Int
        var hasLogo: Bool
        var replyTo: Int?
        var date: Date
        var flags: MessageFlags
    }

    let count: Int
    let specs: [Spec]
    /// Every folder the mailbox uses, the inbox first.
    let folders: [String]
    let owner: String

    init(count: Int, owner: String, attachmentShare: Double = 1, bodyScale: Double = 1, folderSize: Int = .max, seed: UInt64 = 0x6B69_7474_6965) {
        self.count = count
        self.owner = owner
        var random = SplitMix64(seed: seed)
        // Three years of mail, ending on a fixed day, oldest first.
        let end = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01T00:00:00Z
        let span: TimeInterval = 3 * 365 * 24 * 3600
        var specs: [Spec] = []
        specs.reserveCapacity(count)
        for index in 0..<count {
            let size = random.unit()
            let withAttachment = 1 - 0.03 * attachmentShare
            var text: Int
            var attachment = 0
            switch size {
            case ..<(0.65 * withAttachment / 0.97): text = random.int(in: 5_000...15_000)
            case ..<withAttachment: text = random.int(in: 15_000...50_000)
            case ..<(1 - 0.006 * attachmentShare): text = random.int(in: 5_000...20_000); attachment = random.int(in: 30_000...200_000)
            case ..<(1 - 0.001 * attachmentShare): text = random.int(in: 5_000...20_000); attachment = random.int(in: 300_000...1_000_000)
            default: text = random.int(in: 5_000...20_000); attachment = random.int(in: 1_000_000...3_000_000)
            }
            text = max(1_000, Int(Double(text) * bodyScale))
            let folderRoll = random.int(in: 0...9)
            let folder = folderRoll < 8 ? "INBOX" : folderRoll == 8 ? "Sent" : "Archive"
            let replyTo = index > 10 && random.unit() < 0.15 ? max(0, index - random.int(in: 1...200)) : nil
            let recent = index >= count - count / 20
            let flags = MessageFlags(seen: folder != "INBOX" || random.unit() < (recent ? 0.5 : 0.95),
                                     answered: random.unit() < 0.1, flagged: random.unit() < 0.02)
            specs.append(Spec(index: index, folder: folder, textBytes: text, attachmentBytes: attachment,
                              hasLogo: random.unit() < 0.1, replyTo: replyTo,
                              date: end.addingTimeInterval(-span + span * Double(index) / Double(max(1, count))), flags: flags))
        }
        // GreenMail answers every UID FETCH in time proportional to the folder's size, so a
        // folder of many thousands is slow at the server, not the client (Performance.md).
        // `folderSize` splits each folder, newest first: "INBOX", then "INBOX 2", "INBOX 3"…
        var folders: [String] = []
        for base in ["INBOX", "Sent", "Archive"] {
            let members = specs.indices.filter { specs[$0].folder == base }.reversed()
            for (position, index) in members.enumerated() {
                let part = position / max(1, folderSize)
                let name = part == 0 ? base : "\(base == "INBOX" ? "Inbox" : base) \(part + 1)"
                specs[index].folder = name
                if !folders.contains(name) { folders.append(name) }
            }
        }
        self.specs = specs
        self.folders = folders
    }

    /// Roughly the bytes the messages take on the wire (attachments in base64).
    var approximateBytes: Int64 {
        specs.reduce(0) { $0 + Int64($1.textBytes) + Int64(Double($1.attachmentBytes) * 1.37) + ($1.hasLogo ? 8_400 : 0) + 1_200 }
    }

    static func messageID(_ index: Int) -> String { "<bench-\(index)@mail.example.net>" }

    /// The message's bytes. `variant` makes a different message for the same spec (the
    /// "new mail" pass).
    func message(_ spec: Spec, variant: String = "") -> Data {
        var random = SplitMix64(seed: UInt64(spec.index) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(variant.count))
        let people = Self.people
        let sender = people[random.int(in: 0...(people.count - 1))]
        let me = "Bench Owner <\(owner)>"
        let from = spec.folder == "Sent" ? me : "\(sender.name) <\(sender.address)>"
        let to = spec.folder == "Sent" ? "\(sender.name) <\(sender.address)>" : me
        let subjectWords = (0..<random.int(in: 3...8)).map { _ in Self.words[random.int(in: 0...(Self.words.count - 1))] }
        var subject = subjectWords.joined(separator: " ").capitalizedFirst
        if let replyTo = spec.replyTo { subject = "Re: thread \(replyTo % 997) " + subject }
        let id = variant.isEmpty ? Self.messageID(spec.index) : "<bench-\(spec.index)-\(variant)@mail.example.net>"

        var paragraphs: [String] = []
        var length = 0
        let textTarget = spec.textBytes * 45 / 100 // the rest is the HTML alternative
        while length < textTarget {
            let sentenceCount = random.int(in: 3...7)
            let paragraph = (0..<sentenceCount).map { _ -> String in
                let words = (0..<random.int(in: 6...18)).map { _ in Self.words[random.int(in: 0...(Self.words.count - 1))] }
                return words.joined(separator: " ").capitalizedFirst + "."
            }.joined(separator: " ")
            paragraphs.append(paragraph)
            length += paragraph.utf8.count + 2
        }
        let text = paragraphs.map { Self.wrap($0) }.joined(separator: "\r\n\r\n") + "\r\n"
        let html = "<html><body style=\"font-family: sans-serif\">\r\n"
            + paragraphs.map { "<p style=\"margin: 0 0 12px 0\">\(Self.wrap($0))</p>" }.joined(separator: "\r\n")
            + (spec.hasLogo ? "\r\n<img src=\"cid:logo@example.net\" alt=\"Example\">" : "")
            + "\r\n</body></html>\r\n"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var headers = [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(subject)",
            "Date: \(formatter.string(from: spec.date))",
            "Message-ID: \(id)",
            "MIME-Version: 1.0",
        ]
        if let replyTo = spec.replyTo {
            headers.append("In-Reply-To: \(Self.messageID(replyTo))")
            headers.append("References: \(Self.messageID(replyTo))")
        }

        let alternative = "alt-\(spec.index)"
        var alternativePart = "Content-Type: multipart/alternative; boundary=\"\(alternative)\"\r\n\r\n"
        alternativePart += "--\(alternative)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(text)\r\n"
        alternativePart += "--\(alternative)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(html)\r\n"
        alternativePart += "--\(alternative)--\r\n"

        var body = alternativePart
        if spec.hasLogo {
            let related = "rel-\(spec.index)"
            body = "Content-Type: multipart/related; boundary=\"\(related)\"\r\n\r\n--\(related)\r\n\(alternativePart)\r\n"
                + "--\(related)\r\nContent-Type: image/png\r\nContent-ID: <logo@example.net>\r\nContent-Disposition: inline; filename=\"logo.png\"\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n\(Self.logo)\r\n--\(related)--\r\n"
        }
        if spec.attachmentBytes > 0 {
            let mixed = "mix-\(spec.index)"
            var bytes = [UInt8](repeating: 0, count: spec.attachmentBytes)
            var fill = SplitMix64(seed: UInt64(spec.index) &+ 17)
            var offset = 0
            while offset < bytes.count {
                var word = fill.next()
                for _ in 0..<8 where offset < bytes.count { bytes[offset] = UInt8(truncatingIfNeeded: word); word >>= 8; offset += 1 }
            }
            let encoded = Data(bytes).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            body = "Content-Type: multipart/mixed; boundary=\"\(mixed)\"\r\n\r\n--\(mixed)\r\n\(body)\r\n"
                + "--\(mixed)\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"report-\(spec.index).pdf\"\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n\(encoded)\r\n--\(mixed)--\r\n"
        }
        return Data((headers.joined(separator: "\r\n") + "\r\n" + body).utf8)
    }

    private static func wrap(_ text: String) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.utf8.count + word.utf8.count > 72 { lines.append(line); line = "" }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\r\n")
    }

    /// The same 6 KB image in every message that has it.
    private static let logo: String = {
        var random = SplitMix64(seed: 42)
        let bytes = (0..<6_000).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        return Data(bytes).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }()

    private static let people: [(name: String, address: String)] = {
        let first = ["Ada", "Grace", "Alan", "Edsger", "Barbara", "Donald", "Frances", "Ken", "Radia", "Tim", "Margaret", "Dennis"]
        let last = ["Example", "Sample", "Tester", "Placeholder", "Demo", "Fixture"]
        let domains = ["example.com", "example.org", "example.net", "mail.example.com"]
        var result: [(String, String)] = []
        for (i, f) in first.enumerated() {
            for (j, l) in last.enumerated() {
                result.append(("\(f) \(l)", "\(f.lowercased()).\(l.lowercased())@\(domains[(i + j) % domains.count])"))
            }
        }
        return result
    }()

    private static let words: [String] = """
        the of and to in is that for it as was with be by on not he this are or his from at which but have an they \
        you were her she there been one all we their has would when if so what out up more about into them can only \
        other time new some could these two may first then do any like my now over such our man me even most made \
        after also did many before must through back years where much your way well down should because each just \
        those people how too little state good very make world still own see men work long get here between both \
        life being under never day same another know while last might us great old year off come since against go \
        came right used take three meeting project invoice schedule review budget report deadline update release \
        team design draft proposal contract shipment order account payment receipt agenda summary notes question \
        answer feedback launch quarter planning milestone travel booking confirmation reminder newsletter weekly
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
}

/// A small, fast, seedable generator (SplitMix64), so every run makes the same mailbox.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(in range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
