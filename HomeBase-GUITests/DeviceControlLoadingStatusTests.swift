#if os(iOS)
import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class DeviceControlLoadingStatusTests: XCTestCase {
    func testPushedDeviceReportsLoadingUntilItsControlsSubscriptionIsAccepted() async throws {
        let fixture = try await makeFixture(split: false)
        fixture.navigation.path = [DeviceLoadingServer.device.identifier]

        try await waitUntil("The real device screen must request device details", fixture: fixture) {
            await fixture.server.detailRequestCount == 1
        }
        try await assertLoading(fixture, stage: "Device details response is deliberately withheld")

        try await fixture.server.releaseDeviceDetails()
        try await waitUntil("The real model must request its controls subscription", fixture: fixture) {
            await fixture.server.controlRequestCount == 1
        }
        try await assertLoading(fixture, stage: "Controls subscription acceptance is deliberately withheld")

        try await fixture.server.releaseControls()
        try await waitUntil("Accepted controls should make the shared badge connected", fixture: fixture) {
            fixture.status.presentation == .connected && fixture.status.visibleReportCount == 1
        }
        attachSnapshot(fixture, name: "Device controls accepted — connected")

        fixture.navigation.path = []
        try await waitUntil("Popping the device screen must remove its status report", fixture: fixture) {
            fixture.status.visibleReportCount == 0
        }
        XCTAssertEqual(fixture.status.presentation, .connected)
    }

    func testCompactSplitDeviceReportsLoadingAndLeavingDropsItsPendingReport() async throws {
        let fixture = try await makeFixture(split: true)
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        XCTAssertTrue(split.isCollapsed, "Exercise the iPhone's compact navigation split, not two visible columns.")
        fixture.navigation.selection = .device(DeviceLoadingServer.device.identifier)
        fixture.navigation.compactColumn = .detail

        try await waitUntil("The production topology destination must request device details", fixture: fixture) {
            await fixture.server.detailRequestCount == 1
        }
        try await assertLoading(fixture, stage: "Compact split device details are still loading")

        // Compact split navigation reparents the same destination. Keep the
        // actual request pending across the sidebar/detail appearance callbacks.
        fixture.navigation.compactColumn = .sidebar
        try await settle(fixture)
        fixture.navigation.compactColumn = .detail
        try await assertLoading(fixture, stage: "Returning to the compact detail must restore its loading report")

        try await fixture.server.releaseDeviceDetails()
        try await waitUntil("The compact detail model must request controls", fixture: fixture) {
            await fixture.server.controlRequestCount == 1
        }
        try await assertLoading(fixture, stage: "Compact split controls are still loading")

        fixture.navigation.selection = nil
        fixture.navigation.compactColumn = .sidebar
        try await waitUntil("Leaving a loading detail must remove its pending report", fixture: fixture) {
            fixture.status.visibleReportCount == 0
        }
        XCTAssertEqual(fixture.status.presentation, .connected)

        // A late server reply to a departed screen must not re-register its
        // status or keep a loading badge on the device catalog.
        try await fixture.server.releaseControls()
        try await settle(fixture)
        XCTAssertEqual(fixture.status.visibleReportCount, 0)
        XCTAssertEqual(fixture.status.presentation, .connected)
    }

    func testMountedInactiveDeviceStartsLoadingWhenSceneBecomesActive() async throws {
        let fixture = try await makeFixture(split: false, initialScenePhase: .inactive)
        fixture.navigation.path = [DeviceLoadingServer.device.identifier]
        try await settle(fixture)
        let inactiveRequests = await fixture.server.detailRequestCount
        XCTAssertEqual(inactiveRequests, 0, "An inactive screen must not start controls monitoring.")
        XCTAssertEqual(fixture.status.visibleReportCount, 0,
                       "An inactive screen must not contribute a loading report.")
        XCTAssertEqual(fixture.status.presentation, .connected)

        fixture.navigation.scenePhase = .active
        try await waitUntil("The same mounted screen must start monitoring on activation", fixture: fixture) {
            await fixture.server.detailRequestCount == 1
        }
        try await assertLoading(fixture, stage: "Activated device waits for its details response")
        try await fixture.server.releaseDeviceDetails()
        try await waitUntil("The activated screen must request its controls subscription", fixture: fixture) {
            await fixture.server.controlRequestCount == 1
        }
        try await assertLoading(fixture, stage: "Activated device waits for controls acceptance")
        try await fixture.server.releaseControls()
        try await waitUntil("The activated device becomes connected only after controls load", fixture: fixture) {
            fixture.status.presentation == .connected && fixture.status.visibleReportCount == 1
        }
    }

    private func makeFixture(split: Bool, initialScenePhase: ScenePhase = .active) async throws -> Fixture {
        let server = DeviceLoadingServer()
        let client = HomeBaseWebSocketClient(
            endpoint: try XCTUnwrap(HomeBaseEndpoint(host: "device-loading.invalid", port: 10503)),
            requestTimeout: 15,
            makeControlSocket: { _ in DeviceLoadingSocket(server: server) })
        let status = ConnectionStatusController()
        let navigation = DeviceLoadingNavigation()
        navigation.scenePhase = initialScenePhase
        // The application always injects CameraAccessSession. Omitting it takes
        // CameraAccessGate's preview branch and misses the real content closure.
        let access = CameraAccessSession(credentials: DeviceLoadingCredentials(),
                                         authenticator: DeviceLoadingAuthenticator(), environment: .device)
        let lifecycle = CameraAccessLifecycle(session: access)
        let host = UIHostingController(rootView: AnyView(
            DeviceLoadingRoot(navigation: navigation, client: client, split: split)
                .connectionStatusHost(status)
                .environment(\.cameraAccessSession, access)
                .environment(\.cameraAccessLifecycle, lifecycle)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        host.traitOverrides.horizontalSizeClass = .compact
        host.traitOverrides.verticalSizeClass = .regular
        let fixture = Fixture(server: server, client: client, status: status, navigation: navigation,
                              host: host, window: window, previousKeyWindow: previousKeyWindow)
        addTeardownBlock { @MainActor in
            host.rootView = AnyView(Color.clear)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
            await client.disconnect()
            await server.close()
        }
        try await client.connect()
        status.updateConnection(presentation: .connected, route: await client.currentControlRoute())
        window.makeKeyAndVisible()
        try await settle(fixture)
        XCTAssertEqual(status.visibleReportCount, 0)
        XCTAssertEqual(status.presentation, .connected)
        return fixture
    }

    private func assertLoading(_ fixture: Fixture, stage: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        // No model mutation, camera-session publication or parent-view refresh
        // here: only the actual network request should drive the screen report.
        try await settle(fixture)
        XCTAssertEqual(fixture.status.visibleReportCount, 1, stage, file: file, line: line)
        XCTAssertEqual(fixture.status.presentation, .pending("Loading controls…"), stage, file: file, line: line)
        attachSnapshot(fixture, name: stage)
    }

    private func waitUntil(_ message: String, fixture: Fixture, condition: () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let requests = await fixture.server.diagnostics()
        let detail = "\(message); presentation=\(String(describing: fixture.status.presentation)); reports=\(fixture.status.visibleReportCount); scenePhase=\(fixture.navigation.scenePhase); \(requests)"
        attachSnapshot(fixture, name: "Timed out — " + message)
        XCTFail(detail, file: file, line: line)
        throw URLError(.timedOut)
    }

    private func settle(_ fixture: Fixture) async throws {
        fixture.host.view.setNeedsLayout()
        fixture.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        fixture.host.view.layoutIfNeeded()
    }

    private func attachSnapshot(_ fixture: Fixture, name: String) {
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? controller.children.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private struct Fixture {
        let server: DeviceLoadingServer
        let client: HomeBaseWebSocketClient
        let status: ConnectionStatusController
        let navigation: DeviceLoadingNavigation
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previousKeyWindow: UIWindow?
    }
}

@MainActor
private final class DeviceLoadingNavigation: ObservableObject {
    @Published var path: [String] = []
    @Published var scenePhase = ScenePhase.active
    @Published var selection: TopologyDetailDestination?
    @Published var compactColumn = NavigationSplitViewColumn.sidebar
    nonisolated deinit {}
}

private struct DeviceLoadingRoot: View {
    @ObservedObject var navigation: DeviceLoadingNavigation
    let client: HomeBaseWebSocketClient
    let split: Bool

    var body: some View {
        TabView {
            Group {
                if split {
                    NavigationSplitView(preferredCompactColumn: $navigation.compactColumn) {
                        List { Text("Device catalog") }.navigationTitle("Home")
                    } detail: {
                        TopologyDetailDestinationView(selection: navigation.selection,
                            topology: HBTopologyListResult(devices: [DeviceLoadingServer.device], rooms: [], groups: []),
                            client: client)
                    }
                } else {
                    NavigationStack(path: $navigation.path) {
                        List { Text("Device catalog") }
                            .navigationTitle("Home")
                            .navigationDestination(for: String.self) { _ in
                                DeviceDetailView(device: DeviceLoadingServer.device, client: client)
                            }
                    }
                }
            }
            .connectionStatusScope(isActive: true)
            .tabItem { Label("Home", systemImage: "house") }
        }
        .environment(\.scenePhase, navigation.scenePhase)
    }
}

@MainActor
private final class DeviceLoadingCredentials: CameraS3CredentialStoring {
    nonisolated deinit {}
    func inspect() async throws -> CameraS3CredentialPresence { .missing }
    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials {
        throw CameraAccessError.invalidCredentials
    }
    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {
        throw CameraAccessError.credentialManagementUnavailable
    }
}

@MainActor
private final class DeviceLoadingAuthenticator: CameraBiometricAuthenticating {
    nonisolated deinit {}
    func authenticate(using attempt: CameraAuthenticationAttempt) async throws {
        XCTFail("A non-camera device must not request biometric authentication")
        throw CameraAccessError.authenticationUnavailable
    }
}

private nonisolated final class DeviceLoadingSocket: HomeBaseControlSocket, @unchecked Sendable {
    let server: DeviceLoadingServer
    let inbox = DeviceLoadingInbox()
    var maximumMessageSize: Int { get { 1_048_576 } set {} }
    init(server: DeviceLoadingServer) { self.server = server }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { await inbox.close() }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { throw URLError(.badServerResponse) }
        let request = try JSONDecoder().decode(HBProtocolEnvelope.self, from: Data(text.utf8))
        try await server.accept(request, inbox: inbox)
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        .string(try await inbox.receive())
    }
}

private actor DeviceLoadingInbox {
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    func push(_ envelope: HBProtocolEnvelope) throws {
        guard !closed else { return }
        let text = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: text) }
        else { queue.append(text) }
    }
    func receive() async throws -> String {
        if closed { throw URLError(.networkConnectionLost) }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() {
        closed = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
        queue.removeAll()
    }
}

private actor DeviceLoadingServer {
    nonisolated static let device = HBTopologyDeviceDescriptor(identifier: "loading-test-device",
        addressableName: "LoadingTestDevice", displayName: "Test Light")
    private(set) var detailRequestCount = 0
    private(set) var controlRequestCount = 0
    private var pendingDetails: (HBProtocolEnvelope, DeviceLoadingInbox)?
    private var pendingControls: (HBProtocolEnvelope, DeviceLoadingInbox)?
    private let sessionID = UUID()
    private let serverInstanceID = UUID()
    private let subscriptionID = UUID()
    private var deliverySequence: Int64 = 0
    private var receivedOperations: [String] = []

    func accept(_ request: HBProtocolEnvelope, inbox: DeviceLoadingInbox) async throws {
        receivedOperations.append(request.operation)
        switch request.operation {
        case HBProtocolOperations.openSession:
            var response = try HBProtocolEnvelope.response(to: request, body: .success(
                HBWebSocketSessionOpened(sessionID: sessionID, resumeToken: "test-resume",
                    serverInstanceID: serverInstanceID, authorization: .administrator,
                    limits: .init(resumeWindowSeconds: 60, maximumReplayMessages: 100,
                                  maximumReplayBytes: 1_048_576, maximumRequestRecords: 100))))
            response.sessionID = sessionID
            try await inbox.push(response)
        case HBProtocolOperations.listDevices:
            detailRequestCount += 1
            pendingDetails = (request, inbox)
        case HBProtocolOperations.streamControls:
            controlRequestCount += 1
            pendingControls = (request, inbox)
        case HBProtocolOperations.ping:
            try await respond(to: request, body: .successWithoutResult, inbox: inbox)
        case HBProtocolOperations.acknowledgeSession:
            let ack = try request.decodedPayload(as: HBWebSocketSessionAckRequest.self)
            var response = try HBProtocolEnvelope.response(to: request,
                body: .success(HBWebSocketSessionAckResult(acknowledgedDeliverySequence: ack.deliverySequence)))
            response.sessionID = request.sessionID
            try await inbox.push(response)
        case HBProtocolOperations.cancelSubscription:
            let cancel = try request.decodedPayload(as: HBSubscriptionCancelRequest.self)
            try await respond(to: request, body: .success(HBSubscriptionCancelResult(subscriptionID: cancel.subscriptionID)), inbox: inbox)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func releaseDeviceDetails() async throws {
        guard let (request, inbox) = pendingDetails else { throw URLError(.badServerResponse) }
        pendingDetails = nil
        let control = HBControlDescriptor(identifier: "Power", name: "Power", kind: "BinarySwitch",
                                          value: .bool(false), metadata: ["readable": true])
        let details = HBDeviceDescriptor(identifier: Self.device.identifier, addressableName: Self.device.addressableName,
            displayName: Self.device.displayName, moduleName: "test", controls: [control])
        try await respond(to: request, body: .success(HBDeviceListResult(devices: [details])), inbox: inbox)
    }

    func releaseControls() async throws {
        guard let (request, inbox) = pendingControls else { throw URLError(.badServerResponse) }
        pendingControls = nil
        let control = HBControlWatchStreamControl(control: "LoadingTestDevice:Power",
            deviceIdentifier: Self.device.identifier, controlIdentifier: "Power", displayName: "Power", kind: "BinarySwitch")
        try await respond(to: request,
            body: .success(HBControlWatchStreamAccepted(subscriptionID: subscriptionID, controls: [control])), inbox: inbox)
    }

    private func respond(to request: HBProtocolEnvelope, body: HBProtocolResponse, inbox: DeviceLoadingInbox) async throws {
        var response = try HBProtocolEnvelope.response(to: request, body: body)
        response.sessionID = request.sessionID
        deliverySequence += 1
        response.deliverySequence = deliverySequence
        try await inbox.push(response)
    }

    func diagnostics() -> String {
        "details=\(detailRequestCount); controls=\(controlRequestCount); pendingDetails=\(pendingDetails != nil); pendingControls=\(pendingControls != nil); operations=\(receivedOperations)"
    }

    func close() {
        pendingDetails = nil
        pendingControls = nil
    }
}
#endif
