import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class CameraWindowTests: XCTestCase {
    func testRequestIdentityIsStableAcrossTopologyPresentationChanges() throws {
        let server = PairedServer(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            endpoint: try XCTUnwrap(HomeBaseEndpoint(host: "homebase.local", port: 10_503))
        )
        let original = CameraWindowRequest(
            server: server,
            camera: camera(identifier: "camera-a", displayName: "Front Door")
        )
        let renamed = CameraWindowRequest(
            server: server,
            camera: camera(identifier: "camera-a", displayName: "Porch")
        )

        XCTAssertEqual(original, renamed)
        XCTAssertEqual(Set([original, renamed]).count, 1)
    }

    func testDifferentCamerasHaveIndependentWindowIdentities() throws {
        let server = PairedServer(
            endpoint: try XCTUnwrap(HomeBaseEndpoint(host: "homebase.local", port: 10_503))
        )

        XCTAssertNotEqual(
            CameraWindowRequest(server: server, camera: camera(identifier: "camera-a")),
            CameraWindowRequest(server: server, camera: camera(identifier: "camera-b"))
        )
    }

    private func camera(
        identifier: String,
        displayName: String = "Camera"
    ) -> CameraVideoDevice {
        CameraVideoDevice(
            device: HBTopologyDeviceDescriptor(
                identifier: identifier,
                addressableName: identifier,
                displayName: displayName
            ),
            capability: CameraLiveVideoCapability(qualities: [.high])
        )
    }
}
