import Foundation
import MailCore
import MailMIME

// Partial messages in the store (GKM-036, MAIL-062). Format and rules: PartialMessage.swift.
//
// Files, per partial message, in `<device>/partial/<account>/`:
//   <id>.manifest.json   what it is made of, what is still at the provider (written last: a
//                        partial message exists when its manifest exists)
//   <id>.skeleton.eml    the fetched sections with the left-out parts empty; never an original
//   <id>.skeleton.md     the derived Markdown, as for a complete message
// Its parts are blobs in `<device>/cache/blobs/<sha256>`, re-fetchable from the provider.

/// What ``MailStore/integrityReport()`` found.
public struct IntegrityReport: Equatable, Sendable {
    /// Originals or attachments that no longer match their recorded hash.
    public var failed: [MailMessageID] = []
    /// Partial messages: no original to check yet, so not checked as one (their fetched parts are).
    public var partial: [MailMessageID] = []
    /// Originals checked.
    public var checked = 0

    public init(failed: [MailMessageID] = [], partial: [MailMessageID] = [], checked: Int = 0) {
        self.failed = failed
        self.partial = partial
        self.checked = checked
    }
}

/// A part of a partial message fetched since it arrived.
struct FetchedPart: Codable, Equatable {
    var blob: String
    var size: Int
}

extension MailStore {
    // MARK: - Files

    func partialDirectory(account: String) -> URL {
        locations.partialFolder.appendingPathComponent(account, isDirectory: true)
    }

    func partialManifestURL(_ id: MailMessageID, account: String) -> URL {
        partialDirectory(account: account).appendingPathComponent("\(id.rawValue).manifest.json")
    }

    func partialSkeletonURL(_ id: MailMessageID, account: String) -> URL {
        partialDirectory(account: account).appendingPathComponent("\(id.rawValue).skeleton.eml")
    }

    private func partialIndexPath(_ id: MailMessageID, account: String) -> String {
        "partial/\(account)/\(id.rawValue).skeleton.eml"
    }

    func cacheBlobURL(_ blob: String) -> URL {
        locations.cacheBlobsFolder.appendingPathComponent(blob)
    }

    /// Records that a cached part was read, for least-recently-used eviction.
    func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes a partial message's files (its original took over, or its account went).
    func removePartialFiles(_ id: MailMessageID, account: String) throws {
        let fileManager = FileManager.default
        let directory = partialDirectory(account: account)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        // The manifest first: without it the rest is leftovers, whatever stops this.
        for name in ["\(id.rawValue).manifest.json", "\(id.rawValue).skeleton.eml", "\(id.rawValue).skeleton.md"] {
            let url = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    func readManifest(_ id: MailMessageID, account: String) throws -> PartialManifest? {
        let url = partialManifestURL(id, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest = try JSONCoding.decoder.decode(PartialManifest.self, from: Data(contentsOf: url))
        guard manifest.format <= PartialManifest.format, manifest.id == id else {
            throw MailStoreError.unsupportedMetadataVersion(manifest.format)
        }
        return manifest
    }

    // MARK: - Storing what the sync fetched

    /// Stores messages the sync fetched partially (large attachments left at the provider), with
    /// the same rules as ``storeSynced(_:account:floor:)``: a location on record is never stored twice,
    /// and the same message seen again gains a location instead of a copy. A partial copy
    /// matches a stored partial copy with the same signature (header, size, structure, every
    /// fetched part). It never matches a complete message by itself: where a complete message
    /// could be the same one, the outcome is `nil`, and the caller fetches the whole original and
    /// stores it with ``storeSynced(_:account:floor:)``, which compares bytes.
    /// With a `floor`, nothing is written when the batch would leave less free space than its
    /// minimum (GKM-091), as for ``storeSynced(_:account:floor:)``.
    public func storeSyncedPartials(_ messages: [SyncedPartialMessage], account: MailAccountID,
                                    floor: FreeSpaceFloor? = nil) throws -> [SyncedOutcome?] {
        try floor?.check(incoming: messages.reduce(0) { $0 + Int64($1.storedSize) }, in: locations.mailFolder)
        let accountName = try SafePath.component(account.rawValue)
        let mapping = try mapping(for: accountName)
        var outcomes: [SyncedOutcome?] = Array(repeating: nil, count: messages.count)
        var flags: [MailMessageID: MailMessageFlags] = [:]
        var fresh: [(offset: Int, plan: PlannedPartial)] = []
        var freshBySignature: [String: Int] = [:]
        var sameAsFresh: [(offset: Int, of: Int)] = []

        for (offset, message) in messages.enumerated() {
            if let existing = try mapping.localID(at: message.remote) {
                outcomes[offset] = .alreadyStored(existing)
                flags[existing] = message.flags
                continue
            }
            let plan = try planPartial(message, account: account)
            var matched: MailMessageID?
            var completeCandidate = false
            for candidate in try index.candidates(account: account, messageID: plan.derived.message.messageID,
                                                  fingerprint: ContentFingerprint.of(plan.derived.message)) {
                if let manifest = try readManifest(candidate, account: accountName) {
                    if manifest.signature == plan.manifest.signature { matched = candidate; break }
                } else if try index.location(of: candidate)?.isPartial == false {
                    completeCandidate = true
                }
            }
            if let matched {
                try record(message.remote, for: matched, account: account)
                outcomes[offset] = .matched(matched)
                flags[matched] = message.flags
                continue
            }
            if completeCandidate { continue } // nil: fetch the original and compare its bytes
            if let first = freshBySignature[plan.manifest.signature] {
                sameAsFresh.append((offset, first))
                continue
            }
            freshBySignature[plan.manifest.signature] = offset
            fresh.append((offset, plan))
        }

        let ids = try writePartials(fresh.map(\.plan), account: account)
        for (entry, id) in zip(fresh, ids) {
            outcomes[entry.offset] = .stored(id)
            flags[id] = messages[entry.offset].flags
        }
        for (offset, first) in sameAsFresh {
            guard case .stored(let id) = outcomes[first] else { continue }
            try record(messages[offset].remote, for: id, account: account)
            outcomes[offset] = .matched(id)
        }
        if !flags.isEmpty { try setFlags(flags, account: account) }
        let bytes = fresh.reduce(Int64(0)) { $0 + Int64($1.plan.skeleton.count) }
        if bytes > 0 { try addImportedBytes(bytes, account: account) }
        return outcomes
    }

    struct PlannedPartial {
        var manifest: PartialManifest
        var skeleton: Data
        var derived: Derived
        var remote: RemoteLocation?
    }

    private func planPartial(_ message: SyncedPartialMessage, account: MailAccountID) throws -> PlannedPartial {
        let omitted = PartialPlan.omitted(message.structure, threshold: 0).filter { leaf in
            message.sections[leaf.section] == nil
        }.map(\.section)
        guard !omitted.isEmpty else { throw MailStoreError.unparseableMessage("a partial message must leave something out") }
        let skeleton = try PartialPlan.skeleton(header: message.header, root: message.structure, sections: message.sections)
        let id = MailMessageID()
        let received = Date(timeIntervalSince1970: message.receivedAt.timeIntervalSince1970.rounded(.down))
        let manifest = PartialManifest(
            format: PartialManifest.format, id: id, account: account, size: message.size, headerLength: message.header.count,
            headerSha256: Hashing.sha256Hex(message.header), structure: message.structure, omitted: omitted, fetched: [:],
            signature: try PartialPlan.signature(header: message.header, size: message.size, structure: message.structure,
                                                 sections: message.sections),
            received: received)
        return PlannedPartial(manifest: manifest, skeleton: skeleton, derived: try derivePartial(skeleton, manifest: manifest),
                              remote: message.remote)
    }

    /// The front matter, Markdown and blobs of a partial message, from its skeleton: what the
    /// index, search and classification use. Parts left at the provider are listed with their
    /// section and, until fetched, a stand-in blob and an estimated size.
    func derivePartial(_ skeleton: Data, manifest: PartialManifest) throws -> Derived {
        // MailMIME directly (not the injectable parser): the left-out parts are matched to the
        // structure by position, which needs MailMIME's own part order.
        let mime = MIMEParser.parse(skeleton)
        guard !mime.headers.fields.isEmpty else { throw MailStoreError.unparseableMessage("no header fields") }
        let parsed = MIMEMessageParser.map(mime)
        let leaves = mime.root.leaves
        let described = manifest.structure.leaves
        guard leaves.count == described.count else {
            throw MailStoreError.unparseableMessage("the partial copy's parts do not match its structure")
        }
        let omitted = Set(manifest.omitted)
        var blobs: [(hash: String, data: Data)] = []
        var attachments: [AttachmentReference] = []
        for (leaf, info) in zip(leaves, described) {
            let isLeftOut = omitted.contains(info.section)
            guard leaf.isAttachment else {
                // A left-out part must be one MailMIME lists as an attachment, or text would go missing.
                if isLeftOut { throw MailStoreError.unparseableMessage("part \(info.section) is not an attachment") }
                continue
            }
            let mediaType = leaf.mimeType.isEmpty ? "application/octet-stream" : leaf.mimeType
            let inline = leaf.disposition?.value == "inline" || (leaf.disposition == nil && leaf.contentID != nil)
            let contentID = leaf.contentID.flatMap { $0.isEmpty ? nil : $0 }
            if isLeftOut {
                let fetched = manifest.fetched[info.section]
                attachments.append(AttachmentReference(
                    blob: fetched?.blob ?? AttachmentReference.pendingBlob(info.section), fileName: SafePath.displayFileName(leaf.filename),
                    mediaType: mediaType, size: fetched?.size ?? info.estimatedDecodedSize, inline: inline, contentId: contentID,
                    section: info.section))
            } else {
                let hash = Hashing.sha256Hex(leaf.body)
                blobs.append((hash, leaf.body))
                attachments.append(AttachmentReference(blob: hash, fileName: SafePath.displayFileName(leaf.filename), mediaType: mediaType,
                                                       size: leaf.body.count, inline: inline, contentId: contentID))
            }
        }
        let front = MessageFrontMatter(
            schema: DerivedMarkdown.schemaVersion, id: manifest.id, account: manifest.account, messageId: parsed.messageID,
            inReplyTo: parsed.inReplyTo, references: parsed.references, from: parsed.from, to: parsed.to, cc: parsed.cc,
            replyTo: parsed.replyTo, subject: parsed.subject, date: parsed.date, received: manifest.received,
            // No original yet: no hash to check it by (MAIL-062). The size is the provider's.
            eml: "\(manifest.id.rawValue).skeleton.eml", emlSha256: "", emlSize: manifest.size, attachments: attachments)
        return Derived(message: parsed, front: front, markdown: try DerivedMarkdown.render(front, message: parsed), blobs: blobs)
    }

    /// Writes partial messages as one unit, like ``write(_:account:)``: one journal file, then the
    /// cached parts, the skeletons and Markdown, the manifests last; then the index and the
    /// mapping in one transaction each. After a crash each one is wholly there (its manifest made
    /// it; recovery completes the index and mapping) or wholly absent.
    private func writePartials(_ plans: [PlannedPartial], account: MailAccountID) throws -> [MailMessageID] {
        guard !plans.isEmpty else { return [] }
        let accountName = try SafePath.component(account.rawValue)
        let directory = partialDirectory(account: accountName)
        let journalURL = locations.journalFolder.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        let entries = plans.map { JournalEntry(id: $0.manifest.id, account: account, directory: "", remote: $0.remote,
                                               received: $0.manifest.received, partial: true) }
        try writer.write(JSONCoding.encoder.encode(entries), to: journalURL)

        try storeCacheBlobs(plans.flatMap(\.derived.blobs))
        for plan in plans {
            let id = plan.manifest.id
            let skeleton = try writer.stage(plan.skeleton, for: partialSkeletonURL(id, account: accountName))
            let markdown = try writer.stage(Data(plan.derived.markdown.utf8),
                                            for: directory.appendingPathComponent("\(id.rawValue).skeleton.md"))
            let manifest = try writer.stage(JSONCoding.encoder.encode(plan.manifest), for: partialManifestURL(id, account: accountName))
            try writer.rename(skeleton)
            try writer.rename(markdown)
            try writer.rename(manifest)
        }
        try AtomicWriter.syncDirectory(directory)

        try index.batch {
            for plan in plans {
                var record = IndexRecord(front: plan.derived.front, message: plan.derived.message,
                                         path: partialIndexPath(plan.manifest.id, account: accountName))
                record.isPartial = true
                try index.upsert(record)
                if let remote = plan.remote { try index.setMailboxes([remote.mailbox], for: plan.manifest.id, account: account) }
            }
        }
        let mapping = try mapping(for: accountName)
        try mapping.database.transaction {
            for plan in plans { if let remote = plan.remote { try mapping.record(remote, for: plan.manifest.id) } }
        }
        try FileManager.default.removeItem(at: journalURL)
        do {
            try index.batch {
                for plan in plans { classifyAfterIngest(plan.manifest.id, account: account, parsed: plan.derived.message) }
            }
        } catch {
            classification.lastError = String(describing: error)
        }
        return plans.map(\.manifest.id)
    }

    /// Writes parts into the device cache, each once (named by its hash). A part the mail
    /// folder already holds is not copied.
    private func storeCacheBlobs(_ blobs: [(hash: String, data: Data)]) throws {
        var written = false
        var seen = Set<String>()
        for blob in blobs where seen.insert(blob.hash).inserted {
            let url = cacheBlobURL(blob.hash)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: locations.blobsFolder.appendingPathComponent(blob.hash).path) { continue }
            try writer.rename(writer.stage(blob.data, for: url))
            written = true
        }
        if written { try AtomicWriter.syncDirectory(locations.cacheBlobsFolder) }
    }

    func rewriteManifest(_ manifest: PartialManifest, account: String) throws -> Derived {
        let skeleton = try Data(contentsOf: partialSkeletonURL(manifest.id, account: account))
        let derived = try derivePartial(skeleton, manifest: manifest)
        // Markdown first: the manifest is what readers trust, so it goes in last.
        try writer.write(Data(derived.markdown.utf8),
                         to: partialDirectory(account: account).appendingPathComponent("\(manifest.id.rawValue).skeleton.md"))
        try writer.write(JSONCoding.encoder.encode(manifest), to: partialManifestURL(manifest.id, account: account))
        var record = IndexRecord(front: derived.front, message: derived.message, path: partialIndexPath(manifest.id, account: account),
                                 attachmentText: "")
        record.isPartial = true
        try index.upsert(record)
        return derived
    }

    // MARK: - Reading

    public func isPartial(_ id: MailMessageID) throws -> Bool {
        try index.location(of: id)?.isPartial ?? false
    }

    /// What a partial message still lacks, and where it can be fetched from. `nil` when the
    /// message is complete.
    public func partialStatus(_ id: MailMessageID) throws -> PartialStatus? {
        guard try isPartial(id), let account = try index.account(of: id) else { return nil }
        let name = try SafePath.component(account.rawValue)
        guard let manifest = try readManifest(id, account: name) else { throw MailStoreError.messageNotFound(id.rawValue) }
        let sizes = Dictionary(manifest.structure.leaves.map { ($0.section, $0.size) }, uniquingKeysWith: { a, _ in a })
        let missing = manifest.omitted.filter { manifest.fetched[$0] == nil }.map { ($0, sizes[$0] ?? 0) }
        return PartialStatus(id: id, account: account, size: manifest.size, missing: missing,
                             fetched: manifest.fetched.mapValues(\.blob), locations: try mapping(for: name).locations(of: id))
    }

    /// What Reply and Reply All quote and address from: the original, or for a partial message
    /// its skeleton, which has the exact header and every text part (only attachments are
    /// missing, and a reply carries none). Forward needs the original: complete the message first.
    public func replySource(of id: MailMessageID) throws -> Data {
        let (url, isPartial) = try fileLocation(of: id)
        return isPartial ? try Data(contentsOf: url) : try originalData(of: id)
    }

    /// Partial messages, in an account or everywhere.
    public func partialMessages(account: MailAccountID? = nil) throws -> [MailMessageID] {
        try index.partialIDs(account: account)
    }

    // MARK: - Fetched on demand

    /// Stores a left-out part fetched from the provider (`body` as fetched, still encoded):
    /// decoded as MailMIME decodes it, kept in the device cache by hash, and recorded in the
    /// message's manifest, index and Markdown. Returns the attachment as the reader lists it now.
    @discardableResult
    public func storeFetchedPart(_ body: Data, section: String, of id: MailMessageID) throws -> AttachmentReference {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        let name = try SafePath.component(account.rawValue)
        guard var manifest = try readManifest(id, account: name) else { throw MailStoreError.partialMessage(id.rawValue) }
        guard manifest.omitted.contains(section),
              let info = manifest.structure.leaves.first(where: { $0.section == section }) else {
            throw MailStoreError.partialMismatch(id.rawValue)
        }
        let data = PartialPlan.decode(body, encoding: info.encoding)
        let hash = Hashing.sha256Hex(data)
        try storeCacheBlobs([(hash, data)])
        manifest.fetched[section] = FetchedPart(blob: hash, size: data.count)
        let derived = try rewriteManifest(manifest, account: name)
        guard let reference = derived.front.attachments.first(where: { $0.section == section }) else {
            throw MailStoreError.partialMismatch(id.rawValue)
        }
        return reference
    }

    /// Completes a partial message with its whole original, fetched from the provider: written
    /// like any message, byte for byte, under the same local id (flags, folders, spaces, pins and
    /// the verdict stay with it); the partial copy goes once the original is in place. The bytes
    /// must be that message: the same size, the same header, the same text and the same parts
    /// as the partial copy; otherwise nothing is written.
    public func completePartial(_ id: MailMessageID, with eml: Data) throws {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        let name = try SafePath.component(account.rawValue)
        guard let manifest = try readManifest(id, account: name) else { return } // completed meanwhile
        let parsed = try parser.parse(eml)
        guard try partialMatches(manifest, account: name, eml: eml, parsed: parsed) else {
            throw MailStoreError.partialMismatch(id.rawValue)
        }
        _ = try write([NewMessage(eml: eml, parsed: parsed, remote: nil, receivedAt: manifest.received, completes: id)], account: account)
        try refreshSpaceIdentity(of: id)
    }

    /// True when `eml` is the original of the partial copy `manifest` describes: it begins with
    /// exactly the same header, has the same text (fingerprint), and every part the copy holds
    /// or fetched is in it with the same bytes. (The left-out parts cannot be compared: that is
    /// what the copy lacks. The size is not compared: servers' RFC822.SIZE is not always the
    /// octet count of what they send — GreenMail's is not. IMAP never changes a message under a
    /// UID, so this is the same message; MAIL-063.)
    func partialMatches(_ manifest: PartialManifest, account: String, eml: Data, parsed: ParsedMessage) throws -> Bool {
        guard eml.count >= manifest.headerLength,
              Hashing.sha256Hex(eml.prefix(manifest.headerLength)) == manifest.headerSha256 else { return false }
        let skeleton = try Data(contentsOf: partialSkeletonURL(manifest.id, account: account))
        let copy = try derivePartial(skeleton, manifest: manifest)
        guard ContentFingerprint.of(copy.message) == ContentFingerprint.of(parsed) else { return false }
        let present = Set(parsed.attachments.map { Hashing.sha256Hex($0.data) })
        let held = copy.front.attachments.filter(\.isDownloaded).map(\.blob)
        return held.allSatisfy(present.contains)
    }

    /// A space keeps each member's original hash for matching across devices (MAIL-042); a
    /// partial member had none until now.
    private func refreshSpaceIdentity(of id: MailMessageID) throws {
        guard let identity = try index.identities(of: [id]).first, !identity.emlSha256.isEmpty else { return }
        for space in try spaces() where space.format <= MailSpace.formatVersion
            && space.members.contains(where: { $0.message == id && $0.emlSha256.isEmpty }) {
            var updated = space
            for index in updated.members.indices where updated.members[index].message == id {
                updated.members[index].emlSha256 = identity.emlSha256
            }
            try write(updated, now: Date())
        }
    }

    // MARK: - Recovery and rebuild

    /// Finishes or undoes a partial write the journal still lists. False when it cannot tell.
    func recoverPartialWrite(_ entry: JournalEntry) throws -> Bool {
        guard let name = try? SafePath.component(entry.account.rawValue) else { return false }
        let directory = partialDirectory(account: name)
        try removePartials(in: directory, prefix: ".\(entry.id.rawValue).")
        guard let manifest = try? readManifest(entry.id, account: name) else {
            // The manifest never made it: whatever else did is a leftover.
            try removePartialFiles(entry.id, account: name)
            return true
        }
        try removePartials(in: locations.cacheBlobsFolder)
        let skeleton = try Data(contentsOf: partialSkeletonURL(entry.id, account: name))
        let derived = try derivePartial(skeleton, manifest: manifest)
        try storeCacheBlobs(derived.blobs)
        try writer.write(Data(derived.markdown.utf8), to: directory.appendingPathComponent("\(entry.id.rawValue).skeleton.md"))
        var record = IndexRecord(front: derived.front, message: derived.message, path: partialIndexPath(entry.id, account: name))
        record.isPartial = true
        try index.upsert(record)
        if let remote = entry.remote {
            try mapping(for: name).record(remote, for: entry.id)
            try index.setMailboxes(Set(mapping(for: name).locations(of: entry.id).map(\.mailbox)), for: entry.id, account: entry.account)
        }
        return true
    }

    /// Adds every partial message in the device folder to a rebuild; a partial copy whose
    /// original is in the mail folder (`skipping`) is removed instead.
    func rebuildPartials(_ insert: (IndexRecord) throws -> Void, skipping originals: Set<MailMessageID>) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: locations.partialFolder.path) else { return }
        for accountFolder in try sortedContents(of: locations.partialFolder) {
            guard let name = try? SafePath.component(accountFolder.lastPathComponent) else { continue }
            try removePartials(in: accountFolder)
            let files = try sortedContents(of: accountFolder)
            let manifests = Set(files.compactMap { file -> String? in
                let fileName = file.lastPathComponent
                return fileName.hasSuffix(".manifest.json") ? String(fileName.dropLast(".manifest.json".count)) : nil
            })
            for file in files {
                // Skeletons and Markdown without a manifest are leftovers of an interrupted write.
                let stem = file.lastPathComponent.components(separatedBy: ".").first ?? ""
                if !manifests.contains(stem), MailMessageID(stem) != nil { try fileManager.removeItem(at: file) }
            }
            for raw in manifests.sorted() {
                guard let id = MailMessageID(raw) else { continue }
                if originals.contains(id) {
                    try removePartialFiles(id, account: name)
                    continue
                }
                guard let manifest = try? readManifest(id, account: name),
                      let skeleton = try? Data(contentsOf: partialSkeletonURL(id, account: name)),
                      let derived = try? derivePartial(skeleton, manifest: manifest) else { continue }
                try storeCacheBlobs(derived.blobs)
                var record = IndexRecord(front: derived.front, message: derived.message, path: partialIndexPath(id, account: name))
                record.isPartial = true
                try insert(record)
            }
        }
    }
}

extension MailIndex {
    /// Partial messages, oldest first.
    func partialIDs(account: MailAccountID?) throws -> [MailMessageID] {
        let statement = account == nil
            ? try database.prepare("SELECT local_id FROM messages WHERE partial = 1 ORDER BY sort_date, local_id")
            : try database.prepare("SELECT local_id FROM messages WHERE partial = 1 AND account_id = ? ORDER BY sort_date, local_id")
                .bind([.text(account!.rawValue)])
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }
}
