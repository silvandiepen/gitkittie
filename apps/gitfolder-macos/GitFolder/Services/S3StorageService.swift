import CryptoKit
import Foundation

struct S3Credentials: Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String? = nil
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

struct S3StorageService: Sendable {
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    func testConnection(settings: BucketStorageSettings, credentials: S3Credentials) async throws {
        var request = try request(
            method: "HEAD",
            settings: settings,
            credentials: credentials,
            objectKey: nil,
            payloadHash: Self.emptyPayloadHash
        )
        request.timeoutInterval = 30
        let (_, response) = try await session.data(for: request)
        try validate(response, expected: 200..<300)
    }

    func uploadFile(
        at fileURL: URL,
        objectKey: String,
        sha256: String,
        settings: BucketStorageSettings,
        credentials: S3Credentials
    ) async throws {
        let byteCount = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if byteCount > Self.singleUploadLimit {
            try await uploadMultipartFile(
                at: fileURL,
                objectKey: objectKey,
                sha256: sha256,
                settings: settings,
                credentials: credentials
            )
            return
        }
        var request = try request(
            method: "PUT",
            settings: settings,
            credentials: credentials,
            objectKey: objectKey,
            payloadHash: sha256,
            additionalHeaders: ["x-amz-meta-gitfolder-sha256": sha256]
        )
        request.timeoutInterval = 3_600
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        try validate(response, expected: 200..<300)
    }

    func verifyObject(
        objectKey: String,
        sha256: String,
        settings: BucketStorageSettings,
        credentials: S3Credentials
    ) async throws {
        var request = try request(
            method: "HEAD",
            settings: settings,
            credentials: credentials,
            objectKey: objectKey,
            payloadHash: Self.emptyPayloadHash
        )
        request.timeoutInterval = 30
        let (_, response) = try await session.data(for: request)
        try validate(response, expected: 200..<300)
        guard let http = response as? HTTPURLResponse else { throw S3StorageError.invalidResponse }
        let remoteHash = http.value(forHTTPHeaderField: "x-amz-meta-gitfolder-sha256")
        guard remoteHash == sha256 else {
            throw S3StorageError.checksumMismatch(expected: sha256, actual: remoteHash ?? "missing")
        }
    }

    private func uploadMultipartFile(
        at fileURL: URL,
        objectKey: String,
        sha256: String,
        settings: BucketStorageSettings,
        credentials: S3Credentials
    ) async throws {
        let initiateRequest = try request(
            method: "POST",
            settings: settings,
            credentials: credentials,
            objectKey: objectKey,
            query: [("uploads", "")],
            payloadHash: Self.emptyPayloadHash,
            additionalHeaders: ["x-amz-meta-gitfolder-sha256": sha256]
        )
        let (initiateData, initiateResponse) = try await session.data(for: initiateRequest)
        try validate(initiateResponse, expected: 200..<300)
        guard let uploadID = Self.uploadID(from: initiateData), !uploadID.isEmpty else {
            throw S3StorageError.invalidMultipartResponse
        }

        var completedParts: [(number: Int, etag: String)] = []
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var partNumber = 1
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: Self.multipartPartSize) ?? Data()
                if data.isEmpty { break }
                let payloadHash = Self.sha256(data)
                var partRequest = try request(
                    method: "PUT",
                    settings: settings,
                    credentials: credentials,
                    objectKey: objectKey,
                    query: [("partNumber", String(partNumber)), ("uploadId", uploadID)],
                    payloadHash: payloadHash
                )
                partRequest.timeoutInterval = 3_600
                let (_, response) = try await session.upload(for: partRequest, from: data)
                try validate(response, expected: 200..<300)
                guard let http = response as? HTTPURLResponse,
                      let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                      !etag.isEmpty else {
                    throw S3StorageError.invalidMultipartResponse
                }
                completedParts.append((partNumber, etag))
                partNumber += 1
            }

            let completionXML = Self.completionXML(parts: completedParts)
            let completionHash = Self.sha256(completionXML)
            var completeRequest = try request(
                method: "POST",
                settings: settings,
                credentials: credentials,
                objectKey: objectKey,
                query: [("uploadId", uploadID)],
                payloadHash: completionHash,
                additionalHeaders: ["content-type": "application/xml"]
            )
            completeRequest.httpBody = completionXML
            completeRequest.timeoutInterval = 3_600
            let (completionData, completionResponse) = try await session.data(for: completeRequest)
            try validate(completionResponse, expected: 200..<300)
            if let text = String(data: completionData, encoding: .utf8), text.contains("<Error>") {
                throw S3StorageError.multipartFailed
            }
        } catch {
            var abortRequest = try? request(
                method: "DELETE",
                settings: settings,
                credentials: credentials,
                objectKey: objectKey,
                query: [("uploadId", uploadID)],
                payloadHash: Self.emptyPayloadHash
            )
            abortRequest?.timeoutInterval = 30
            if let abortRequest { _ = try? await session.data(for: abortRequest) }
            throw error
        }
    }

    func downloadFile(
        objectKey: String,
        destinationURL: URL,
        expectedSHA256: String,
        settings: BucketStorageSettings,
        credentials: S3Credentials
    ) async throws {
        var request = try request(
            method: "GET",
            settings: settings,
            credentials: credentials,
            objectKey: objectKey,
            payloadHash: Self.emptyPayloadHash
        )
        request.timeoutInterval = 3_600
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response, expected: 200..<300)
        let actualHash = try Self.sha256(of: temporaryURL)
        guard actualHash == expectedSHA256 else {
            throw S3StorageError.checksumMismatch(expected: expectedSHA256, actual: actualHash)
        }

        let manager = FileManager.default
        try manager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stagedURL = destinationURL.deletingLastPathComponent().appending(path: ".\(destinationURL.lastPathComponent).gitfolder-download")
        try? manager.removeItem(at: stagedURL)
        try manager.moveItem(at: temporaryURL, to: stagedURL)
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try manager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private func request(
        method: String,
        settings: BucketStorageSettings,
        credentials: S3Credentials,
        objectKey: String?,
        query: [(String, String)] = [],
        payloadHash: String,
        additionalHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        guard !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty else {
            throw S3StorageError.missingCredentials
        }
        guard let endpoint = URL(string: settings.endpoint), let host = endpoint.host, !settings.bucket.isEmpty else {
            throw S3StorageError.invalidConfiguration
        }

        let canonicalURI = canonicalPath(bucket: settings.bucket, objectKey: objectKey)
        var encodedQuery: [(name: String, value: String)] = []
        for item in query {
            encodedQuery.append((Self.percentEncodeQuery(item.0), Self.percentEncodeQuery(item.1)))
        }
        encodedQuery.sort {
            if $0.name == $1.name { return $0.value < $1.value }
            return $0.name < $1.name
        }
        let canonicalQuery = encodedQuery.map { $0.name + "=" + $0.value }.joined(separator: "&")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw S3StorageError.invalidConfiguration
        }
        components.percentEncodedPath = canonicalURI
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        guard let url = components.url else { throw S3StorageError.invalidConfiguration }

        let timestamp = Self.amzTimestamp(now())
        let dateStamp = String(timestamp.prefix(8))
        var headers = additionalHeaders
        headers["host"] = endpoint.port.map { "\(host):\($0)" } ?? host
        headers["x-amz-content-sha256"] = payloadHash
        headers["x-amz-date"] = timestamp
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            headers["x-amz-security-token"] = sessionToken
        }

        let sortedHeaders = headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted { $0.0 < $1.0 }
        let canonicalHeaders = sortedHeaders.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = sortedHeaders.map(\.0).joined(separator: ";")
        let canonicalRequest = [method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let region = settings.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : settings.region
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, Self.sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = Self.signature(
            stringToSign: stringToSign,
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func canonicalPath(bucket: String, objectKey: String?) -> String {
        let segments = ([bucket] + (objectKey?.split(separator: "/", omittingEmptySubsequences: true).map(String.init) ?? []))
        return "/" + segments.map(Self.percentEncodePathSegment).joined(separator: "/")
    }

    private func validate(_ response: URLResponse, expected: Range<Int>) throws {
        guard let response = response as? HTTPURLResponse else { throw S3StorageError.invalidResponse }
        guard expected.contains(response.statusCode) else { throw S3StorageError.httpStatus(response.statusCode) }
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func signature(stringToSign: String, secret: String, dateStamp: String, region: String) -> String {
        let dateKey = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = hmac(key: regionKey, data: Data("s3".utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        return hmac(key: signingKey, data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func amzTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func percentEncodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func percentEncodeQuery(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func uploadID(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "<UploadId>"),
              let end = text.range(of: "</UploadId>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func completionXML(parts: [(number: Int, etag: String)]) -> Data {
        let body = parts.map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(escapeXML($0.etag))</ETag></Part>"
        }.joined()
        return Data("<CompleteMultipartUpload>\(body)</CompleteMultipartUpload>".utf8)
    }

    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let emptyPayloadHash = sha256(Data())
    private static let singleUploadLimit = 4_500_000_000
    private static let multipartPartSize = 64 * 1_024 * 1_024
}

enum S3StorageError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case missingCredentials
    case invalidResponse
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case invalidMultipartResponse
    case multipartFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The bucket endpoint, region, or name is invalid."
        case .missingCredentials: "Add storage credentials before connecting."
        case .invalidResponse: "The storage provider returned an invalid response."
        case .httpStatus(let status): "The storage provider returned HTTP \(status)."
        case .checksumMismatch(let expected, let actual): "Downloaded data failed verification (expected \(expected), received \(actual))."
        case .invalidMultipartResponse: "The storage provider returned an invalid multipart upload response."
        case .multipartFailed: "The storage provider could not complete the multipart upload."
        }
    }
}
