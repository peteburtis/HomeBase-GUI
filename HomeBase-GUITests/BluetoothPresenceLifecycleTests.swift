#if os(iOS)
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class BluetoothPresenceLifecycleTests: XCTestCase {
    func testBackgroundLaunchReconcilesWhenApplicationBecomesActiveWithoutAnyScreen() async {
        let fixture = Fixture(initiallyForeground: false)
        fixture.service.start()
        XCTAssertEqual(fixture.transport.foregroundStates, [false])

        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(fixture.transport.foregroundStates, [false, true],
                       "Presence recovery must not depend on a screen or WebSocket session")
    }

    func testReturningFromBackgroundReconcilesBeforeApplicationBecomesActive() async {
        let fixture = Fixture(initiallyForeground: true)
        fixture.service.start()
        fixture.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(fixture.transport.foregroundStates, [true, false, true],
                       "Presence must begin reconciling before foreground screens resume requests")

        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(fixture.transport.foregroundStates, [true, false, true])
    }

    func testRepeatedStartsAndNotificationsForwardEachActualTransitionOnce() async {
        let fixture = Fixture(initiallyForeground: true)
        fixture.service.start()
        fixture.service.start()
        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(fixture.transport.foregroundStates, [true, false, true])
        XCTAssertEqual(fixture.transport.synchronizations, 1)
    }

    func testPermissionSheetOrOtherTransientInactivityDoesNotTriggerRecovery() async {
        let fixture = Fixture(initiallyForeground: true)
        fixture.service.start()
        fixture.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        fixture.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(fixture.transport.foregroundStates, [true],
                       "Only an actual background-to-foreground return should revalidate presence")
    }

    func testLifecycleObservationDoesNotRetainTheService() async {
        let notifications = NotificationCenter()
        let transport = Transport()
        var service: BluetoothPresenceService? = BluetoothPresenceService(
            store: Store(), transport: transport, notificationCenter: notifications,
            applicationIsForeground: { true })
        weak var observedService = service
        service?.start()
        service = nil
        XCTAssertNil(observedService)

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(transport.foregroundStates, [true])
    }

    private final class Fixture {
        let notifications = NotificationCenter()
        let transport = Transport()
        let initiallyForeground: Bool
        lazy var service = BluetoothPresenceService(
            store: Store(), transport: transport, notificationCenter: notifications,
            applicationIsForeground: { [initiallyForeground] in initiallyForeground })

        init(initiallyForeground: Bool) { self.initiallyForeground = initiallyForeground }
    }

    private final class Store: BluetoothPresenceStoring {
        func load() throws -> [BluetoothPresenceRegistration] { [] }
        func save(_ registrations: [BluetoothPresenceRegistration]) throws {
            XCTFail("Lifecycle changes must not modify saved pairing credentials")
        }
    }

    private final class Transport: BluetoothPresenceTransporting {
        var onEvent: ((BluetoothPresenceTransportEvent) -> Void)?
        var foregroundStates: [Bool] = []
        var synchronizations = 0
        func synchronize(_ registrations: [BluetoothPresenceRegistration]) { synchronizations += 1 }
        func showPicker(for registration: BluetoothPresenceRegistration) throws {}
        func removeAccessory(peripheralID: UUID) {}
        func retryConnections() {}
        func setForeground(_ isForeground: Bool) { foregroundStates.append(isForeground) }
    }
}
#endif
