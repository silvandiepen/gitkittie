import Foundation
import MailProvider
import NIOIMAP

// Message structure and single sections, for partial messages and attachments on demand
// (GKM-036): BODYSTRUCTURE tells the sync which parts are large; BODY.PEEK[<section>] fetches
// the header, the MIME headers and the parts it keeps, and later a left-out part when opened.
// PEEK throughout: fetching never marks a message read.
extension IMAPSession {
    public func bodyStructures(of ids: [RemoteMessageID]) async throws -> [RemoteMessageID: RemoteBodyPart] {
        guard !ids.isEmpty else { return [:] }
        let (folder, uids) = try await selectForMessages(ids)
        let result = try await wire.run(.uidFetch(.set(Self.uidSet(uids)), [.uid, .bodyStructure(extensions: true)], []),
                                        logAs: "UID FETCH (\(uids.count) × BODYSTRUCTURE) in \(folder)")
        try Self.check(result, "UID FETCH BODYSTRUCTURE")
        let wanted = Set(uids)
        var structures: [RemoteMessageID: RemoteBodyPart] = [:]
        for fetch in result.fetches {
            guard let uid = fetch.uid ?? fetch.attributes.lazy.compactMap({ attribute -> UInt32? in
                if case .uid(let uid) = attribute { return uid.rawValue }
                return nil
            }).first, wanted.contains(uid) else { continue }
            for case .body(.valid(let structure), _) in fetch.attributes {
                structures[RemoteMessageID(folder: folder, uidValidity: ids[0].uidValidity, uid: uid)] = Self.bodyPart(structure, path: [])
            }
        }
        return structures
    }

    public func fetchSections(_ sections: [String], of id: RemoteMessageID) async throws -> [String: Data] {
        guard !sections.isEmpty else { return [:] }
        var specifiers: [SectionSpecifier: String] = [:]
        var items: [FetchAttribute] = [.uid]
        for name in sections {
            guard let specifier = Self.sectionSpecifier(name) else { throw MailProviderError.unsupported("section \(name)") }
            if specifiers.updateValue(name, forKey: specifier) == nil { items.append(.bodySection(peek: true, specifier, nil)) }
        }
        let (folder, uids) = try await selectForMessages([id])
        let result = try await wire.run(.uidFetch(.set(Self.uidSet(uids)), items, []),
                                        logAs: "UID FETCH \(id.uid) (\(sections.count) sections) in \(folder)")
        try Self.check(result, "UID FETCH sections")
        guard let fetch = result.fetches.first(where: { $0.uid == id.uid || $0.attributes.contains(.uid(UID(rawValue: id.uid))) })
        else { throw MailProviderError.messageNotFound(id) }
        var fetched: [String: Data] = [:]
        for (specifier, data) in fetch.sections {
            if let name = specifiers[specifier] { fetched[name] = data }
        }
        return fetched
    }

    /// "HEADER", "1.2.MIME", "1.2" → the codec's section specifier.
    static func sectionSpecifier(_ name: String) -> SectionSpecifier? {
        if name == "HEADER" { return SectionSpecifier(kind: .header) }
        var components = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var kind = SectionSpecifier.Kind.complete
        if components.last == "MIME" {
            kind = .MIMEHeader
            components.removeLast()
        }
        let numbers = components.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == components.count, numbers.allSatisfy({ $0 > 0 }) else { return nil }
        return SectionSpecifier(part: SectionSpecifier.Part(numbers), kind: kind)
    }

    /// The codec's BODYSTRUCTURE as the provider-neutral part tree. A message/rfc822 part is a
    /// leaf here: it is fetched (or left out) whole.
    static func bodyPart(_ structure: BodyStructure, path: [Int]) -> RemoteBodyPart {
        let section = path.isEmpty ? "" : path.map(String.init).joined(separator: ".")
        switch structure {
        case .multipart(let multipart):
            let parameters = multipart.extension?.parameters
            let disposition = multipart.extension?.dispositionAndLanguage?.disposition
            let children = multipart.parts.enumerated().map { bodyPart($0.element, path: path + [$0.offset + 1]) }
            return RemoteBodyPart(section: section, mediaType: "multipart/" + String(multipart.mediaSubtype),
                                  boundary: parameters.flatMap { parameter("boundary", in: $0) },
                                  size: children.reduce(0) { $0 + $1.size },
                                  disposition: disposition.map { $0.kind.rawValue }, parts: children)
        case .singlepart(let single):
            let mediaType: String
            switch single.kind {
            case .basic(let media): mediaType = String(media.topLevel) + "/" + String(media.sub)
            case .message(let message): mediaType = "message/" + String(message.message)
            case .text(let text): mediaType = "text/" + String(text.mediaSubtype)
            }
            let disposition = single.extension?.dispositionAndLanguage?.disposition
            let fileName = disposition.flatMap { parameter("filename", in: $0.parameters) }
                ?? parameter("name", in: single.fields.parameters)
            let contentID = single.fields.id?.trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
            return RemoteBodyPart(section: path.isEmpty ? "1" : section, mediaType: mediaType,
                                  encoding: single.fields.encoding.map { String($0) }, size: single.fields.octetCount,
                                  fileName: fileName, disposition: disposition.map { $0.kind.rawValue },
                                  contentID: contentID.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// A parameter by name, any case, also in its RFC 2231 forms (`filename*`, `filename*0*`):
    /// for those the raw value only says that there is a name.
    private static func parameter<S: Sequence>(_ name: String, in parameters: S) -> String?
    where S.Element == (key: String, value: String) {
        if let exact = parameters.first(where: { $0.key.lowercased() == name }) { return exact.value }
        return parameters.first { $0.key.lowercased().hasPrefix(name + "*") }?.value
    }
}
