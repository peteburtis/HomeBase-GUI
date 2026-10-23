import XCTest
@testable import HomeBase_GUI

final class PairingEndpointTests: XCTestCase {
    func testManualEndpointUsesStandardServerPort() throws {
        let endpoint = try XCTUnwrap(
            HomeBaseEndpoint(
                host: "192.168.1.42",
                port: HomeBaseEndpoint.defaultPort
            )
        )

        XCTAssertEqual(endpoint.host, "192.168.1.42")
        XCTAssertEqual(endpoint.port, 10_503)
        XCTAssertEqual(endpoint.webSocketURL?.absoluteString, "ws://192.168.1.42:10503/")
    }

    func testManualEndpointTrimsHostnameAndAllowsCustomPort() throws {
        let endpoint = try XCTUnwrap(
            HomeBaseEndpoint(host: "  homebase.local \n", port: 12_345)
        )

        XCTAssertEqual(endpoint.host, "homebase.local")
        XCTAssertEqual(endpoint.port, 12_345)
    }

    func testManualEndpointRejectsUnusableValues() {
        XCTAssertNil(HomeBaseEndpoint(host: "", port: 10_503))
        XCTAssertNil(HomeBaseEndpoint(host: "not a host/path", port: 10_503))
        XCTAssertNil(HomeBaseEndpoint(host: "192.168.1.42", port: 0))
        XCTAssertNil(HomeBaseEndpoint(host: "192.168.1.42", port: 65_536))
    }
}
