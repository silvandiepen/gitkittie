import Foundation
import GitKittieKit

/// File storage: a repository can send its images, audio, video and other big files to a
/// bucket and keep only pointers (see `BucketSource`). This is what the settings screen
/// drives.
extension AppModel {
    /// Whether this kind of entry can offload at all. Folders on this device and folder
    /// servers keep their files where they are.
    public func supportsFileStorage(_ repo: AddedRepo) -> Bool { !repo.kind.isFolder }

    /// The repository's storage settings as they are in the repository now, nil when it
    /// has none.
    public func storageConfig(for repo: AddedRepo) async -> BoardStorageConfig? {
        guard let source = remoteSource(for: repo) as? BucketSource else { return nil }
        await BucketConfigCache.shared.forget(repo.id)
        return await source.config()
    }

    /// Whether this device holds the keys of that bucket.
    public func hasStorageKeys(for config: BoardStorageConfig) -> Bool {
        bucketCredentials.load(for: config) != nil
    }

    /// Check that the bucket answers with these keys. Nil when it does, else what went wrong.
    /// Empty key fields mean: the keys already on this device.
    public func testStorage(_ config: BoardStorageConfig, accessKeyID: String, secretAccessKey: String) async -> String? {
        guard let keys = keys(config, accessKeyID, secretAccessKey) else { return "Enter the access key ID and the secret access key." }
        do {
            try await S3StorageService().testConnection(bucket: config.s3, credentials: keys)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Write the settings to the repository and keep the keys on this device. Nil when
    /// saved, else what went wrong.
    public func saveStorage(_ config: BoardStorageConfig, accessKeyID: String, secretAccessKey: String, for repo: AddedRepo) async -> String? {
        guard let source = remoteSource(for: repo) else { return "Sign in to the git provider first." }
        do {
            if let keys = keys(config, accessKeyID, secretAccessKey), !accessKeyID.isEmpty {
                try bucketCredentials.save(keys, for: config)
            }
            let text = try config.encoded()
            if (try? await source.readText(BoardStorageConfig.path)) != text {
                try await source.write(path: BoardStorageConfig.path, text: text, message: "chore(tasks): set file storage")
            }
            await BucketConfigCache.shared.store(config, for: repo.id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func keys(_ config: BoardStorageConfig, _ accessKeyID: String, _ secret: String) -> S3Credentials? {
        let id = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty && secret.isEmpty { return bucketCredentials.load(for: config) }
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return S3Credentials(accessKeyID: id, secretAccessKey: secret)
    }

    /// How many files in the repository would be in the bucket had they been written
    /// today. Nil when the provider cannot list the whole repository.
    public func filesStillInRepository(_ repo: AddedRepo) async -> Int? {
        guard let source = remoteSource(for: repo) as? BucketSource else { return nil }
        return await source.filesStillInRepository()?.count
    }

    /// Move the files that are still in the repository to the bucket, one by one, each
    /// replaced by its pointer. `progress` gets (done, total) after every file. Stops at
    /// the first failure and says what it was; what was moved before that stays moved.
    /// The files remain in the repository's history: this stops the checkout from
    /// growing, it does not shrink what git already holds.
    public func moveExistingFilesToBucket(_ repo: AddedRepo, progress: @MainActor (Int, Int) -> Void) async -> String? {
        guard let source = remoteSource(for: repo) as? BucketSource else { return "Sign in to the git provider first." }
        guard let files = await source.filesStillInRepository() else { return "This provider cannot list the whole repository." }
        progress(0, files.count)
        for (index, path) in files.enumerated() {
            if Task.isCancelled { return "Stopped after \(index) of \(files.count) files." }
            do {
                try await source.offloadExisting(path)
            } catch {
                return "Stopped at \(path): \(error.localizedDescription)"
            }
            progress(index + 1, files.count)
        }
        return nil
    }
}
