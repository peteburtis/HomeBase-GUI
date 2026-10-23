import Foundation
import HomeBaseProtocol
import AWSS3
import AWSSDKIdentity
import Smithy
import SmithyIdentity
import SmithyHTTPAPI
import SmithyHTTPClientAPI
import ClientRuntime

nonisolated protocol CameraS3ObjectReading: Sendable {
    func read(key: String, maximumBytes: Int) async throws -> Data
    func list(prefix: String, continuationToken: String?) async throws -> CameraS3ObjectPage?
    func close() async
}

extension CameraS3ObjectReading {
    // Existing GET-only sources remain usable without an availability inventory.
    func list(prefix: String, continuationToken: String?) async throws -> CameraS3ObjectPage? { nil }
}

nonisolated struct CameraS3ObjectPage: Sendable {
    let keys: [String]
    let next: String?
}

nonisolated enum CameraS3ReadError: Error, LocalizedError, Equatable {
    case missing, accessDenied, timeout, tooLarge, invalidDestination, invalidKey, network, closed
    var errorDescription: String? {
        switch self {
        case .missing: "The requested S3 object is not available."
        case .accessDenied: "S3 could not provide this object. It may be missing, or the reader credentials may lack access."
        case .timeout: "Reading S3 timed out. Try again."
        case .tooLarge: "This S3 object exceeds the playback size limit."
        case .invalidDestination: "The advertised S3 destination is invalid or does not match these credentials."
        case .invalidKey: "The recording index references an invalid object or an object outside this store."
        case .network: "Could not read S3. Check the network and try again."
        case .closed: "S3 playback has closed."
        }
    }
    static func forHTTPStatus(_ status: Int) -> Self? {
        switch status {
        case 200: nil
        case 404: .missing
        case 401, 403: .accessDenied // Without ListBucket, a missing key may be 403.
        case 300...399: .invalidDestination // Never follow a redirect with signed credentials.
        default: .network
        }
    }
    static func sanitized(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let known = error as? Self { return known }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return CancellationError() }
            if ns.code == NSURLErrorTimedOut { return Self.timeout }
        }
        return Self.network // Never display SDK/HTTP errors containing URLs, headers or keys.
    }
}

/// Object reads and optional prefix-scoped listings. Explicit credentials are scoped
/// to one advertised store; there is no AWS-file/environment credential chain,
/// remote credential validation, or persistent response cache.
actor CameraS3ObjectReader: CameraS3ObjectReading {
    typealias Fetch = @Sendable (HBCameraPlaybackMetadata.S3Store, CameraS3Credentials, String, Int) async throws -> Data
    typealias List = @Sendable (HBCameraPlaybackMetadata.S3Store, CameraS3Credentials, String, String?) async throws -> CameraS3ObjectPage
    private let destination: HBCameraPlaybackMetadata.S3Store
    private var credentials: CameraS3Credentials?
    private let fetch: Fetch
    private let listing: List
    private var closed = false
    private var tasks: [UUID: Task<Data, Error>] = [:]
    private var listTasks: [UUID: Task<CameraS3ObjectPage, Error>] = [:]

    init(destination: HBCameraPlaybackMetadata.S3Store, credentials: CameraS3Credentials,
         listing: @escaping List = CameraS3ObjectReader.listFromAWS,
         fetch: @escaping Fetch = CameraS3ObjectReader.fetchFromAWS) throws {
        try CameraS3ReadScope.validate(destination: destination, credentials: credentials)
        self.destination = destination
        // The transport never needs (or retains) the media encryption password.
        self.credentials = CameraS3Credentials(destinationID: credentials.destinationID,
            accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey, encryptionPassword: nil)
        self.fetch = fetch
        self.listing = listing
    }

    func read(key: String, maximumBytes: Int) async throws -> Data {
        guard !closed, let credentials else { throw CameraS3ReadError.closed }
        try Task.checkCancellation()
        try CameraS3ReadScope.validate(key: key, prefix: destination.prefix)
        guard maximumBytes > 0, maximumBytes <= 512 * 1024 * 1024 else { throw CameraS3ReadError.tooLarge }
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { [destination, credentials, fetch] in
            let result = try await fetch(destination, credentials, key, maximumBytes)
            try Task.checkCancellation()
            guard result.count <= maximumBytes else { throw CameraS3ReadError.tooLarge }
            return result
        }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closed else { throw CameraS3ReadError.closed }
            return value
        } catch { throw CameraS3ReadError.sanitized(error) }
    }

    func list(prefix: String, continuationToken: String?) async throws -> CameraS3ObjectPage? {
        guard !closed, let credentials else { throw CameraS3ReadError.closed }
        try Task.checkCancellation()
        try CameraS3ReadScope.validate(listPrefix: prefix, destination: destination)
        guard continuationToken.map({ !$0.isEmpty && $0.utf8.count <= 16384 }) ?? true else {
            throw CameraS3ReadError.invalidKey
        }
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { [destination, credentials, listing] in
            try await listing(destination, credentials, prefix, continuationToken)
        }
        listTasks[id] = task
        defer { listTasks.removeValue(forKey: id) }
        do {
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closed else { throw CameraS3ReadError.closed }
            try Self.validate(page: page, prefix: prefix)
            return page
        } catch { throw CameraS3ReadError.sanitized(error) }
    }

    private nonisolated static func validate(page: CameraS3ObjectPage, prefix: String) throws {
        guard page.keys.count <= 1000, Set(page.keys).count == page.keys.count,
              page.next.map({ !$0.isEmpty && $0.utf8.count <= 16384 }) ?? true else {
            throw CameraS3ReadError.network
        }
        for key in page.keys { try CameraS3ReadScope.validate(key: key, prefix: prefix) }
    }

    func close() {
        closed = true
        credentials = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for task in listTasks.values { task.cancel() }
        listTasks.removeAll()
    }

    private nonisolated static func listFromAWS(_ destination: HBCameraPlaybackMetadata.S3Store,
        _ credentials: CameraS3Credentials, _ prefix: String, _ token: String?) async throws -> CameraS3ObjectPage {
        let engine = CameraS3ReadHTTP(destination: destination, listPrefix: prefix, continuationToken: token)
        defer { engine.close() }
        return try await listObjects(destination: destination, credentials: credentials,
                                     prefix: prefix, continuationToken: token, engine: engine)
    }

    private nonisolated static func fetchFromAWS(_ destination: HBCameraPlaybackMetadata.S3Store,
        _ credentials: CameraS3Credentials, _ key: String, _ maximumBytes: Int) async throws -> Data {
        let engine = CameraS3ReadHTTP(destination: destination, key: key, maximumBytes: maximumBytes)
        defer { engine.close() }
        return try await getObject(destination: destination, credentials: credentials, key: key, engine: engine)
    }

    /// Injectable signed-request boundary; tests use synthetic credentials and
    /// a memory-only engine, exercising the real SDK without any AWS request.
    nonisolated static func getObject(destination: HBCameraPlaybackMetadata.S3Store,
        credentials: CameraS3Credentials, key: String, engine: any HTTPClient) async throws -> Data {
        let output = try await client(destination: destination, credentials: credentials, engine: engine)
            .getObject(input: .init(bucket: destination.bucket, expectedBucketOwner: destination.expectedOwner, key: key))
        try Task.checkCancellation()
        return try await output.body?.readData() ?? Data()
    }

    nonisolated static func listObjects(destination: HBCameraPlaybackMetadata.S3Store,
        credentials: CameraS3Credentials, prefix: String, continuationToken: String?,
        engine: any HTTPClient) async throws -> CameraS3ObjectPage {
        let output = try await client(destination: destination, credentials: credentials, engine: engine)
            .listObjectsV2(input: .init(bucket: destination.bucket, continuationToken: continuationToken,
                encodingType: .url, expectedBucketOwner: destination.expectedOwner, maxKeys: 1000, prefix: prefix))
        try Task.checkCancellation()
        guard output.encodingType == .url, output.isTruncated != nil,
              output.isTruncated != true || output.nextContinuationToken?.isEmpty == false else {
            throw CameraS3ReadError.network
        }
        let keys = try (output.contents ?? []).map { object in
            guard let key = object.key?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw CameraS3ReadError.network
            }
            return key
        }
        let page = CameraS3ObjectPage(keys: keys, next: output.isTruncated == true ? output.nextContinuationToken : nil)
        try validate(page: page, prefix: prefix)
        return page
    }

    private nonisolated static func client(destination: HBCameraPlaybackMetadata.S3Store,
        credentials: CameraS3Credentials, engine: any HTTPClient) async throws -> S3Client {
        let resolver = StaticAWSCredentialIdentityResolver(AWSCredentialIdentity(
            accessKey: credentials.accessKeyID, secret: credentials.secretAccessKey))
        var config = try await S3Client.S3ClientConfig(useFIPS: false, useDualStack: false,
            awsCredentialIdentityResolver: resolver, maxAttempts: 1, ignoreConfiguredEndpointURLs: true,
            region: destination.region, forcePathStyle: true, useArnRegion: false,
            disableMultiRegionAccessPoints: true, accelerate: false, disableS3ExpressSessionAuth: true,
            useGlobalEndpoint: false, clientLogMode: ClientLogMode.none, httpClientEngine: engine,
            httpClientConfiguration: HttpClientConfiguration(connectTimeout: 15, socketTimeout: 45))
        config.logger = CameraS3SilentLogger()
        return S3Client(config: config)
    }
}

nonisolated enum CameraS3ReadScope {
    static func validate(destination: HBCameraPlaybackMetadata.S3Store, credentials: CameraS3Credentials) throws {
        guard !destination.id.isEmpty, credentials.destinationID == CameraS3Destination(store: destination).id,
              !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty,
              (3...63).contains(destination.bucket.utf8.count),
              destination.bucket.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil,
              !destination.bucket.contains(".."),
              destination.region.range(of: "^(?:[a-z]{2}-[a-z]+-[0-9]+|us-gov-[a-z]+-[0-9]+)$", options: .regularExpression) != nil,
              destination.prefix.utf8.count <= 1024,
              destination.prefix.rangeOfCharacter(from: .controlCharacters) == nil,
              destination.expectedOwner.map({ $0.range(of: "^[0-9]{12}$", options: .regularExpression) != nil }) ?? true else {
            throw CameraS3ReadError.invalidDestination
        }
    }
    static func validate(key: String, prefix: String) throws {
        guard !key.isEmpty, key.utf8.count <= 1024, key.utf8.starts(with: prefix.utf8),
              key.rangeOfCharacter(from: .controlCharacters) == nil,
              !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw CameraS3ReadError.invalidKey
        }
    }
    static func validate(listPrefix: String, destination: HBCameraPlaybackMetadata.S3Store) throws {
        if listPrefix.isEmpty, destination.prefix.isEmpty { return }
        try validate(key: listPrefix, prefix: destination.prefix)
    }
    static func host(_ destination: HBCameraPlaybackMetadata.S3Store) -> String {
        "s3.\(destination.region).amazonaws.com" + (destination.region.hasPrefix("cn-") ? ".cn" : "")
    }
    static func encodedPath(bucket: String, key: String) -> String {
        // S3 SigV4 preserves slashes inside keys and percent-encodes every
        // non-unreserved UTF-8 byte exactly once (including %, +, ? and #).
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/".utf8)
        return "/" + bucket + "/" + key.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
}

/// Minimal HTTP adapter for the AWS SDK's already signed requests. Keeping this
/// narrow avoids the default engine's disk cache, URL logging, redirect behavior
/// and unbounded response buffering. Cryptographic signing stays in the SDK.
nonisolated final class CameraS3ReadHTTP: NSObject, HTTPClient, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: HBCameraPlaybackMetadata.S3Store
    private let key: String?
    private let listPrefix: String?
    private let continuationToken: String?
    private let maximumBytes: Int
    private let sessionConfiguration: URLSessionConfiguration?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var finished = false
    private var session: URLSession?

    /// Only called with lock held, on first send. No lazy property: its implicit
    /// synchronization would be unsafe and incompatible with nonisolated types.
    private func makeSession() -> URLSession {
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    init(destination: HBCameraPlaybackMetadata.S3Store, key: String, maximumBytes: Int,
         sessionConfiguration: URLSessionConfiguration? = nil) {
        self.destination = destination; self.key = key; self.maximumBytes = maximumBytes
        self.listPrefix = nil; self.continuationToken = nil
        self.sessionConfiguration = sessionConfiguration
    }
    init(destination: HBCameraPlaybackMetadata.S3Store, listPrefix: String, continuationToken: String?,
         sessionConfiguration: URLSessionConfiguration? = nil) {
        self.destination = destination; self.key = nil; self.maximumBytes = 4 * 1024 * 1024
        self.listPrefix = listPrefix; self.continuationToken = continuationToken
        self.sessionConfiguration = sessionConfiguration
    }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let outgoing: URLRequest
        if let key { outgoing = try Self.makeURLRequest(request, destination: destination, key: key) }
        else if let listPrefix {
            outgoing = try Self.makeListURLRequest(request, destination: destination,
                prefix: listPrefix, continuationToken: continuationToken)
        } else { throw CameraS3ReadError.invalidDestination }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished || self.continuation != nil {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let session = makeSession()
                self.session = session
                let task = session.dataTask(with: outgoing)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.close() }
    }
    static func makeURLRequest(_ request: HTTPRequest, destination: HBCameraPlaybackMetadata.S3Store, key: String) throws -> URLRequest {
        let query = request.queryItems ?? []
        guard request.method == .get, request.destination.scheme == .https,
              request.destination.host == CameraS3ReadScope.host(destination),
              request.destination.port == nil || request.destination.port == 443,
              request.destination.path == CameraS3ReadScope.encodedPath(bucket: destination.bucket, key: key),
              query.count == 1, query[0].name == "x-id", query[0].value == "GetObject" else {
            throw CameraS3ReadError.invalidDestination
        }
        return try urlRequest(request)
    }
    static func makeListURLRequest(_ request: HTTPRequest, destination: HBCameraPlaybackMetadata.S3Store,
                                  prefix: String, continuationToken: String?) throws -> URLRequest {
        try CameraS3ReadScope.validate(listPrefix: prefix, destination: destination)
        let query = request.queryItems ?? []
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard request.method == .get, request.destination.scheme == .https,
              request.destination.host == CameraS3ReadScope.host(destination),
              request.destination.port == nil || request.destination.port == 443,
              request.destination.path == CameraS3ReadScope.encodedPath(bucket: destination.bucket, key: "").dropLast(),
              values.count == query.count,
              Set(values.keys).isSubset(of: ["list-type", "encoding-type", "prefix", "max-keys", "continuation-token", "x-id"]),
              values["list-type"] == "2", values["encoding-type"] == "url", values["max-keys"] == "1000",
              values["prefix"]?.removingPercentEncoding == prefix,
              values["continuation-token"]?.removingPercentEncoding == continuationToken,
              values["x-id"] == nil || values["x-id"] == "ListObjectsV2" else {
            throw CameraS3ReadError.invalidDestination
        }
        return try urlRequest(request)
    }
    private static func urlRequest(_ request: HTTPRequest) throws -> URLRequest {
        // Mirror the SDK's URLSession conversion: destination.path is already
        // percent-encoded. Assigning URLComponents.path would double-encode it.
        var components = URLComponents()
        components.scheme = "https"; components.host = request.destination.host
        components.percentEncodedPath = request.destination.path
        components.percentEncodedQueryItems = (request.queryItems ?? []).map { URLQueryItem(name: $0.name, value: $0.value) }
        guard let url = components.url else { throw CameraS3ReadError.invalidKey }
        var outgoing = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        outgoing.httpMethod = "GET"
        for header in request.headers.headers {
            for value in header.value { outgoing.addValue(value, forHTTPHeaderField: header.name) }
        }
        return outgoing
    }
    func close() {
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<HTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        let session = self.session; self.session = nil
        bytes = Data(); response = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(CameraS3ReadError.invalidDestination))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(CameraS3ReadError.network)); return
        }
        if let error = CameraS3ReadError.forHTTPStatus(response.statusCode) {
            completionHandler(.cancel); finish(.failure(error)); return
        }
        if let region = response.value(forHTTPHeaderField: "x-amz-bucket-region"), region != destination.region {
            completionHandler(.cancel); finish(.failure(CameraS3ReadError.invalidDestination)); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(CameraS3ReadError.tooLarge)); return
        }
        lock.lock(); self.response = response; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - bytes.count else {
            lock.unlock(); finish(.failure(CameraS3ReadError.tooLarge)); return
        }
        bytes.append(data)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(CameraS3ReadError.sanitized(error))); return }
        lock.lock(); let response = self.response; let data = bytes; lock.unlock()
        guard let response else { finish(.failure(CameraS3ReadError.network)); return }
        var headers = Headers()
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers.add(name: key, value: String(describing: value)) }
        }
        finish(.success(HTTPResponse(headers: headers, body: .data(data), statusCode: .ok)))
    }
}

private nonisolated struct CameraS3SilentLogger: LogAgent {
    let name = "CameraS3Reader"
    func log(level: LogAgentLevel, message: @autoclosure () -> String,
             metadata: @autoclosure () -> [String: String]?, source: @autoclosure () -> String,
             file: String, function: String, line: UInt) {}
}
