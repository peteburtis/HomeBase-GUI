import XCTest
import HomeBaseProtocol
import Smithy
import SmithyHTTPAPI
@testable import HomeBase_GUI

@MainActor
final class CameraS3ObjectReaderTests: XCTestCase {
    private var destination: HBCameraPlaybackMetadata.S3Store {
        .init(id: "store", name: "Synthetic", bucket: "synthetic-bucket", region: "us-west-2",
              prefix: "recordings/", expectedOwner: "123456789012")
    }
    private var credentials: CameraS3Credentials {
        .init(destinationID: CameraS3Destination(store: destination).id, accessKeyID: "SYNTHETIC", secretAccessKey: "synthetic-secret", encryptionPassword: nil)
    }
    func testScopeAndExactEncoding() throws {
        try CameraS3ReadScope.validate(destination: destination, credentials: credentials)
        for key in ["recordings/x.mp4", "recordings/café +#%?.mp4", "recordings/a//b"] {
            XCTAssertNoThrow(try CameraS3ReadScope.validate(key: key, prefix: destination.prefix))
        }
        for key in ["recordings-elsewhere/x", "elsewhere/x", "recordings/../x", "recordings/./x", "recordings/x\0y", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try CameraS3ReadScope.validate(key: key, prefix: destination.prefix))
        }
        XCTAssertThrowsError(try CameraS3ReadScope.validate(key: "cafe\u{301}/x", prefix: "café/"))
        XCTAssertEqual(CameraS3ReadScope.encodedPath(bucket: "bucket", key: "recordings/café +#%?.mp4"),
            "/bucket/recordings/caf%C3%A9%20%2B%23%25%3F.mp4")
        XCTAssertEqual(CameraS3ReadScope.host(destination), "s3.us-west-2.amazonaws.com")
        XCTAssertEqual(CameraS3ReadScope.host(.init(id: "x", name: "x", bucket: "bucket", region: "cn-north-1", prefix: "")), "s3.cn-north-1.amazonaws.com.cn")
    }
    func testRejectsCrossStoreAndUnsafeDestinationBeforeNetwork() throws {
        let wrong = CameraS3Credentials(destinationID: "other", accessKeyID: "x", secretAccessKey: "y", encryptionPassword: nil)
        XCTAssertThrowsError(try CameraS3ObjectReader(destination: destination, credentials: wrong))
        let moved = HBCameraPlaybackMetadata.S3Store(id: "store", name: "Same ID, changed bucket",
            bucket: "another-bucket", region: "us-west-2", prefix: "recordings/", expectedOwner: "123456789012")
        XCTAssertThrowsError(try CameraS3ObjectReader(destination: moved, credentials: credentials))
        let renamed = HBCameraPlaybackMetadata.S3Store(id: "store", name: "Renamed",
            bucket: "synthetic-bucket", region: "us-west-2", prefix: "recordings/", expectedOwner: "123456789012")
        XCTAssertNoThrow(try CameraS3ObjectReader(destination: renamed, credentials: credentials))
        for bad in [
            HBCameraPlaybackMetadata.S3Store(id: "store", name: "x", bucket: "bucket/other", region: "us-west-2", prefix: ""),
            .init(id: "store", name: "x", bucket: "bucket", region: "us-west-2.example.test", prefix: ""),
            .init(id: "store", name: "x", bucket: "bucket", region: "us-west-2", prefix: "", expectedOwner: "wrong"),
        ] {
            XCTAssertThrowsError(try CameraS3ObjectReader(destination: bad, credentials: credentials))
        }
    }
    func testExactGetAndReadSizeBounds() async throws {
        let reader = try CameraS3ObjectReader(destination: destination, credentials: credentials) { destination, credentials, key, limit in
            XCTAssertEqual(destination.bucket, "synthetic-bucket")
            XCTAssertEqual(destination.expectedOwner, "123456789012")
            XCTAssertEqual(credentials.accessKeyID, "SYNTHETIC")
            XCTAssertEqual(key, "recordings/key")
            XCTAssertEqual(limit, 4)
            return Data([1, 2, 3, 4])
        }
        let value = try await reader.read(key: "recordings/key", maximumBytes: 4)
        XCTAssertEqual(value, Data([1, 2, 3, 4]))
        let oversized = try CameraS3ObjectReader(destination: destination, credentials: credentials) { _, _, _, _ in Data(repeating: 1, count: 5) }
        do { _ = try await oversized.read(key: "recordings/key", maximumBytes: 4); XCTFail("Must enforce bound") }
        catch { XCTAssertEqual(error as? CameraS3ReadError, .tooLarge) }
        for limit in [0, -1, 512 * 1024 * 1024 + 1] {
            do { _ = try await reader.read(key: "recordings/key", maximumBytes: limit); XCTFail("Invalid limit") }
            catch { XCTAssertEqual(error as? CameraS3ReadError, .tooLarge) }
        }
        await reader.close()
        do { _ = try await reader.read(key: "recordings/key", maximumBytes: 4); XCTFail("Closed reader") }
        catch { XCTAssertEqual(error as? CameraS3ReadError, .closed) }
    }
    func testErrorsAreSanitizedAnd403IsNeverEmptyHistory() async throws {
        XCTAssertEqual(CameraS3ReadError.forHTTPStatus(404), .missing)
        XCTAssertEqual(CameraS3ReadError.forHTTPStatus(403), .accessDenied)
        XCTAssertEqual(CameraS3ReadError.forHTTPStatus(301), .invalidDestination)
        XCTAssertEqual(CameraS3ReadError.sanitized(URLError(.timedOut)) as? CameraS3ReadError, .timeout)
        let reader = try CameraS3ObjectReader(destination: destination, credentials: credentials) { _, _, _, _ in
            throw NSError(domain: "secret-error", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic-secret Authorization URL"])
        }
        do { _ = try await reader.read(key: "recordings/key", maximumBytes: 4); XCTFail("Expected error") }
        catch {
            XCTAssertEqual(error as? CameraS3ReadError, .network)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }
    func testRealSDKSignsOnlyExactObjectWithExpectedOwnerAndEscaping() async throws {
        let key = "recordings/café +#%?.mp4"
        let engine = SignedRequestTestEngine(destination: destination, key: key)
        let data = try await CameraS3ObjectReader.getObject(destination: destination,
            credentials: credentials, key: key, engine: engine)
        XCTAssertEqual(data, Data([1, 2, 3]))
        let count = await engine.count
        XCTAssertEqual(count, 1)
    }
    func testSDKDoesNotRetryOrEraseStructuredReadFailures() async throws {
        for expected in [CameraS3ReadError.missing, .accessDenied, .timeout] {
            let engine = FailingSignedRequestEngine(error: expected)
            do {
                _ = try await CameraS3ObjectReader.getObject(destination: destination,
                    credentials: credentials, key: "recordings/key", engine: engine)
                XCTFail("Expected SDK transport failure")
            } catch { XCTAssertEqual(error as? CameraS3ReadError, expected) }
            let count = await engine.count
            XCTAssertEqual(count, 1)
        }
    }
    func testHTTPBoundaryRefusesOtherHostsPathsMethodsAndQueries() throws {
        func request(host: String = "s3.us-west-2.amazonaws.com", path: String = "/synthetic-bucket/recordings/key",
                     method: HTTPMethodType = .get, query: [URIQueryItem] = [.init(name: "x-id", value: "GetObject")]) -> HTTPRequest {
            HTTPRequestBuilder().withHost(host).withPath(path).withMethod(method).withQueryItems(query).build()
        }
        XCTAssertNoThrow(try CameraS3ReadHTTP.makeURLRequest(request(), destination: destination, key: "recordings/key"))
        for bad in [request(host: "attacker.example"), request(path: "/synthetic-bucket/elsewhere/key"),
                    request(method: .put), request(query: []), request(query: [.init(name: "list-type", value: "2")])] {
            XCTAssertThrowsError(try CameraS3ReadHTTP.makeURLRequest(bad, destination: destination, key: "recordings/key"))
        }
    }
    func testHTTPAdapterBoundsBodiesAndSanitizesFailuresWithoutRealNetwork() async throws {
        let scenarios: [(String, CameraS3ReadError?)] = [("ok", nil), ("large-header", .tooLarge),
            ("large-chunks", .tooLarge), ("missing", .missing), ("denied", .accessDenied),
            ("redirect", .invalidDestination), ("wrong-region", .invalidDestination), ("timeout", .timeout)]
        for (scenario, expected) in scenarios {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SyntheticS3URLProtocol.self]
            let key = "recordings/" + scenario
            let engine = CameraS3ReadHTTP(destination: destination, key: key, maximumBytes: 4, sessionConfiguration: config)
            let request = HTTPRequestBuilder().withHost(CameraS3ReadScope.host(destination))
                .withPath(CameraS3ReadScope.encodedPath(bucket: destination.bucket, key: key))
                .withQueryItem(.init(name: "x-id", value: "GetObject")).build()
            do {
                let response = try await engine.send(request: request)
                let data = try await response.body.readData()
                XCTAssertNil(expected, scenario)
                XCTAssertEqual(data, Data([1, 2, 3]), scenario)
            } catch { XCTAssertEqual(error as? CameraS3ReadError, expected, scenario) }
            engine.close()
        }
    }
    func testCloseCancelsInFlightAndDoesNotPublishLateBytes() async throws {
        let started = expectation(description: "fetch started")
        let reader = try CameraS3ObjectReader(destination: destination, credentials: credentials) { _, _, _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(60))
            return Data([1])
        }
        let read = Task { try await reader.read(key: "recordings/key", maximumBytes: 4) }
        await fulfillment(of: [started], timeout: 2)
        await reader.close()
        do { _ = try await read.value; XCTFail("Cancelled fetch must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCallerCancellationCancelsFetch() async throws {
        let started = expectation(description: "fetch started")
        let reader = try CameraS3ObjectReader(destination: destination, credentials: credentials) { _, _, _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(60))
            return Data([1])
        }
        let read = Task { try await reader.read(key: "recordings/key", maximumBytes: 4) }
        await fulfillment(of: [started], timeout: 2)
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancelled fetch must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        await reader.close()
    }
}

/// Installed only on this test's ephemeral session. No test traffic reaches AWS.
private nonisolated final class SyntheticS3URLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = url.lastPathComponent
        if scenario == "timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let status = ["missing": 404, "denied": 403, "redirect": 307][scenario] ?? 200
        var headers = [String: String]()
        if scenario == "large-header" { headers["Content-Length"] = "1000000" }
        if scenario == "wrong-region" { headers["x-amz-bucket-region"] = "eu-west-1" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        if scenario == "large-chunks" { client?.urlProtocol(self, didLoad: Data([4, 5, 6])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor SignedRequestTestEngine: HTTPClient {
    let destination: HBCameraPlaybackMetadata.S3Store
    let key: String
    var count = 0
    init(destination: HBCameraPlaybackMetadata.S3Store, key: String) { self.destination = destination; self.key = key }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        let urlRequest = try CameraS3ReadHTTP.makeURLRequest(request, destination: destination, key: key)
        XCTAssertEqual(urlRequest.url?.absoluteString,
            "https://s3.us-west-2.amazonaws.com/synthetic-bucket/recordings/caf%C3%A9%20%2B%23%25%3F.mp4?x-id=GetObject")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-amz-expected-bucket-owner"), "123456789012")
        XCTAssertTrue(urlRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=SYNTHETIC/") == true)
        XCTAssertEqual(urlRequest.httpMethod, "GET")
        return HTTPResponse(body: .data(Data([1, 2, 3])), statusCode: .ok)
    }
}

private actor FailingSignedRequestEngine: HTTPClient {
    let error: CameraS3ReadError
    var count = 0
    init(error: CameraS3ReadError) { self.error = error }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        throw error
    }
}
