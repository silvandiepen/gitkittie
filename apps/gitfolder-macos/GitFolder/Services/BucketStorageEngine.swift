import Foundation
import GitKittieKit

struct BucketStorageEngine: Sendable {
    private let service: S3StorageService
    private let folderAccessService: FolderAccessService

    init(service: S3StorageService = S3StorageService(), folderAccessService: FolderAccessService = FolderAccessService()) {
        self.service = service
        self.folderAccessService = folderAccessService
    }

    func testConnection(folder: SyncedFolder, credentials: S3Credentials) async throws {
        guard let settings = folder.storage, settings.enabled else { throw BucketStorageError.notEnabled }
        try await service.testConnection(bucket: settings.s3, credentials: credentials)
    }

    func uploadEligibleFiles(folder: SyncedFolder, credentials: S3Credentials) async throws -> StorageUploadOutcome {
        guard let settings = folder.storage, settings.enabled else { throw BucketStorageError.notEnabled }
        return try await folderAccessService.withSecurityScopedAccess(for: folder) { folderURL in
            var manifest = try loadManifest(in: folderURL)
            let candidates = try eligibleFiles(in: folderURL, settings: settings)
            var uploadedCount = 0
            var uploadedBytes: Int64 = 0
            var unchangedCount = 0

            for candidate in candidates {
                try Task.checkCancellation()
                let hash = try S3StorageService.sha256(of: candidate.url)
                if manifest.objects[candidate.relativePath]?.sha256 == hash {
                    unchangedCount += 1
                    continue
                }
                let objectKey = "gitfolder/v1/objects/\(hash.prefix(2))/\(hash)"
                try await service.uploadFile(
                    at: candidate.url,
                    objectKey: objectKey,
                    sha256: hash,
                    bucket: settings.s3,
                    credentials: credentials
                )
                try await service.verifyObject(
                    objectKey: objectKey,
                    sha256: hash,
                    bucket: settings.s3,
                    credentials: credentials
                )
                manifest.objects[candidate.relativePath] = StoredObjectRecord(
                    relativePath: candidate.relativePath,
                    objectKey: objectKey,
                    sha256: hash,
                    byteCount: candidate.byteCount,
                    modifiedAt: candidate.modifiedAt
                )
                try saveManifest(manifest, in: folderURL)
                uploadedCount += 1
                uploadedBytes += candidate.byteCount
            }

            return StorageUploadOutcome(
                uploadedCount: uploadedCount,
                uploadedBytes: uploadedBytes,
                unchangedCount: unchangedCount,
                manifest: manifest
            )
        }
    }

    func restore(relativePath: String, folder: SyncedFolder, credentials: S3Credentials) async throws {
        guard let settings = folder.storage, settings.enabled else { throw BucketStorageError.notEnabled }
        try await folderAccessService.withSecurityScopedAccess(for: folder) { folderURL in
            let manifest = try loadManifest(in: folderURL)
            guard let record = manifest.objects[relativePath] else { throw BucketStorageError.objectNotFound(relativePath) }
            let destination = folderURL.appending(path: relativePath)
            try await service.downloadFile(
                objectKey: record.objectKey,
                destinationURL: destination,
                expectedSHA256: record.sha256,
                bucket: settings.s3,
                credentials: credentials
            )
        }
    }

    private func eligibleFiles(in folderURL: URL, settings: BucketStorageSettings) throws -> [Candidate] {
        let extensions = Set(settings.offloadExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let threshold = Int64(max(1, settings.minimumFileSizeMB)) * 1_000_000
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var candidates: [Candidate] = []
        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(folderURL.path.count + 1))
            if relativePath == ".git" || relativePath.hasPrefix(".git/") || relativePath.hasPrefix(".gitfolder/") {
                if relativePath == ".git" || relativePath == ".gitfolder" { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            let matchesExtension = extensions.contains(url.pathExtension.lowercased())
            guard matchesExtension || Int64(size) >= threshold else { continue }
            candidates.append(Candidate(
                url: url,
                relativePath: relativePath,
                byteCount: Int64(size),
                modifiedAt: values.contentModificationDate ?? Date.distantPast
            ))
        }
        return candidates.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func loadManifest(in folderURL: URL) throws -> StorageManifest {
        let url = manifestURL(in: folderURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder.storage.decode(StorageManifest.self, from: Data(contentsOf: url))
    }

    private func saveManifest(_ manifest: StorageManifest, in folderURL: URL) throws {
        let url = manifestURL(in: folderURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func manifestURL(in folderURL: URL) -> URL {
        folderURL.appending(path: ".gitfolder/storage-manifest.json")
    }

    private struct Candidate {
        var url: URL
        var relativePath: String
        var byteCount: Int64
        var modifiedAt: Date
    }
}

enum BucketStorageError: LocalizedError, Equatable, Sendable {
    case notEnabled
    case objectNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled: "Enable bucket storage before running it."
        case .objectNotFound(let path): "No uploaded object is recorded for \(path)."
        }
    }
}

private extension JSONDecoder {
    static var storage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct StoredObjectRecord: Codable, Equatable, Sendable {
    var relativePath: String
    var objectKey: String
    var sha256: String
    var byteCount: Int64
    var modifiedAt: Date
}

struct StorageManifest: Codable, Equatable, Sendable {
    var version: Int
    var objects: [String: StoredObjectRecord]

    static let empty = StorageManifest(version: 1, objects: [:])
}

struct StorageUploadOutcome: Equatable, Sendable {
    var uploadedCount: Int
    var uploadedBytes: Int64
    var unchangedCount: Int
    var manifest: StorageManifest
}

extension BucketStorageSettings {
    /// The bucket these settings point at, for the shared S3 service.
    var s3: S3Bucket { S3Bucket(endpoint: endpoint, bucket: bucket, region: region) }
}
