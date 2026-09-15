//
//  SceneLiveEditingSessionTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class SceneLiveEditingSessionTests: XCTestCase {
    func testTargetsUseLastControlSetForDuplicatePath() {
        let actions = [
            action(0, ["ControlSet": ["Lamp", "Level", 0.2]]),
            action(1, ["Wait": 2]),
            action(2, ["ControlSet": ["Other", "Switch", 1]]),
            action(3, ["ControlSet": ["lamp", "level", 0.8]]),
        ]

        XCTAssertEqual(
            SceneLiveEditingTarget.targets(for: actions),
            [
                SceneLiveEditingTarget(
                    controlPath: "Other:Switch",
                    value: 1
                ),
                SceneLiveEditingTarget(
                    controlPath: "lamp:level",
                    value: 0.8
                ),
            ]
        )
    }

    func testStartHoldsEveryTargetImmediatelyAtUserPriority() async throws {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)

        try await session.start(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Level",
                    value: 0.4
                ),
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Switch",
                    value: 1
                ),
            ]
        )

        let events = await client.recordedEvents()
        let isActive = await session.isActive()
        let hasOutstandingHolds = await session.hasOutstandingHolds()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .hold(
                    control: "Lamp:Level",
                    value: 0.4,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-1"
                ),
                .hold(
                    control: "Lamp:Switch",
                    value: 1,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-2"
                ),
            ]
        )
        XCTAssertTrue(isActive)
        XCTAssertTrue(hasOutstandingHolds)
    }

    func testReconcileReplacesExistingHoldWithoutChangingItsOrder()
        async throws
    {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)
        try await session.start(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Level",
                    value: 0.2
                ),
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Switch",
                    value: 1
                ),
            ]
        )
        await client.clearEvents()

        try await session.reconcile(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Level",
                    value: 0.9
                ),
                SceneLiveEditingTarget(
                    controlPath: "Other:Switch",
                    value: 0
                ),
            ]
        )

        let events = await client.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .replace(
                    token: "hold-1",
                    value: 0.9,
                    transitionSeconds: nil,
                ),
                .hold(
                    control: "Other:Switch",
                    value: 0,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-3"
                ),
                .release(token: "hold-2"),
            ]
        )
    }

    func testInsertingGroupBeforeLeafReacquiresLeafAfterGroup()
        async throws
    {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)
        let leaf = SceneLiveEditingTarget(
            controlPath: "Lamp:Level",
            value: 0.8
        )
        try await session.start(targets: [leaf])
        await client.clearEvents()

        try await session.reconcile(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Room:Lights",
                    value: 0
                ),
                leaf,
            ]
        )

        let events = await client.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .release(token: "hold-1"),
                .hold(
                    control: "Room:Lights",
                    value: 0,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-2"
                ),
                .hold(
                    control: "Lamp:Level",
                    value: 0.8,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-3"
                ),
            ]
        )
    }

    func testReorderingExistingTargetsReacquiresChangedSuffix()
        async throws
    {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)
        let group = SceneLiveEditingTarget(
            controlPath: "Room:Lights",
            value: 0
        )
        let leaf = SceneLiveEditingTarget(
            controlPath: "Lamp:Level",
            value: 0.8
        )
        try await session.start(targets: [leaf, group])
        await client.clearEvents()

        try await session.reconcile(targets: [group, leaf])

        let events = await client.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .release(token: "hold-1"),
                .release(token: "hold-2"),
                .hold(
                    control: "Room:Lights",
                    value: 0,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-3"
                ),
                .hold(
                    control: "Lamp:Level",
                    value: 0.8,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-4"
                ),
            ]
        )
    }

    func testFailedStructuralReleaseBlocksReacquisitionUntilCleanupSucceeds()
        async throws
    {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)
        let leaf = SceneLiveEditingTarget(
            controlPath: "Lamp:Level",
            value: 0.8
        )
        try await session.start(targets: [leaf])
        await client.clearEvents()
        await client.failRelease(token: "hold-1")

        do {
            try await session.reconcile(
                targets: [
                    SceneLiveEditingTarget(
                        controlPath: "Room:Lights",
                        value: 0
                    ),
                    leaf,
                ]
            )
            XCTFail("Expected structural release to fail")
        } catch {}
        let failedEvents = await client.recordedEvents()
        XCTAssertEqual(
            failedEvents,
            [.reactivate, .release(token: "hold-1")]
        )

        await client.clearEvents()
        await client.allowRelease(token: "hold-1")
        try await session.reconcile(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Room:Lights",
                    value: 0
                ),
                leaf,
            ]
        )

        let retriedEvents = await client.recordedEvents()
        XCTAssertEqual(
            retriedEvents,
            [
                .reactivate,
                .release(token: "hold-1"),
                .hold(
                    control: "Room:Lights",
                    value: 0,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-2"
                ),
                .hold(
                    control: "Lamp:Level",
                    value: 0.8,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-3"
                ),
            ]
        )
    }

    func testFailedReplacementKeepsExistingHoldForLaterCleanup() async throws {
        let client = SceneLiveEditingClientSpy(
            failingReplacementTokens: ["hold-1"]
        )
        let session = SceneLiveEditingSession(client: client)
        try await session.start(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Level",
                    value: 0.2
                )
            ]
        )
        await client.clearEvents()

        do {
            try await session.reconcile(
                targets: [
                    SceneLiveEditingTarget(
                        controlPath: "Lamp:Level",
                        value: 0.9
                    )
                ]
            )
            XCTFail("Expected replacement to fail")
        } catch {}

        try await session.stop()
        let events = await client.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .failedReplace(token: "hold-1"),
                .reactivate,
                .release(token: "hold-1"),
            ]
        )
    }

    func testFailedStartReleasesAlreadyAcquiredTokens() async {
        let client = SceneLiveEditingClientSpy(failingHoldNumber: 2)
        let session = SceneLiveEditingSession(client: client)

        do {
            try await session.start(
                targets: [
                    SceneLiveEditingTarget(
                        controlPath: "Lamp:Level",
                        value: 0.2
                    ),
                    SceneLiveEditingTarget(
                        controlPath: "Lamp:Switch",
                        value: 1
                    ),
                ]
            )
            XCTFail("Expected the second hold to fail")
        } catch {}

        let events = await client.recordedEvents()
        let isActive = await session.isActive()
        let hasOutstandingHolds = await session.hasOutstandingHolds()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .hold(
                    control: "Lamp:Level",
                    value: 0.2,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-1"
                ),
                .failedHold(control: "Lamp:Switch"),
                .reactivate,
                .release(token: "hold-1"),
            ]
        )
        XCTAssertFalse(isActive)
        XCTAssertFalse(hasOutstandingHolds)
    }

    func testStopTreatsServerMissingTokenAsAlreadyReleased() async throws {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)
        try await session.start(
            targets: [
                SceneLiveEditingTarget(
                    controlPath: "Lamp:Level",
                    value: 0.5
                )
            ]
        )
        await client.failReleaseAsNotFound(token: "hold-1")

        try await session.stop()

        let isActive = await session.isActive()
        let hasOutstandingHolds = await session.hasOutstandingHolds()
        XCTAssertFalse(isActive)
        XCTAssertFalse(hasOutstandingHolds)
    }

    func testReplacementSessionReacquiresEveryUnchangedTarget() async throws {
        let client = SceneLiveEditingClientSpy()
        let session = SceneLiveEditingSession(client: client)
        let targets = [
            SceneLiveEditingTarget(
                controlPath: "Lamp:Level",
                value: 0.5
            ),
            SceneLiveEditingTarget(
                controlPath: "Lamp:Switch",
                value: 1
            ),
        ]
        try await session.start(targets: targets)
        await client.clearEvents()
        await client.replaceSession()

        try await session.reconcile(targets: targets)

        let events = await client.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .reactivate,
                .hold(
                    control: "Lamp:Level",
                    value: 0.5,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-3"
                ),
                .hold(
                    control: "Lamp:Switch",
                    value: 1,
                    transitionSeconds: nil,
                    priority: Int(AutomationPresentationFormat.userPriority),
                    lifetime: .session,
                    token: "hold-4"
                ),
            ]
        )
    }

    private func action(
        _ index: Int,
        _ value: HBJSONValue
    ) -> SceneActionConfiguration {
        SceneActionConfiguration(index: index, rawValue: value)
    }
}

private actor SceneLiveEditingClientSpy: SceneLiveEditingRemoteClient {
    enum Event: Equatable {
        case reactivate
        case hold(
            control: String,
            value: HBJSONValue,
            transitionSeconds: TimeInterval?,
            priority: Int?,
            lifetime: HBControlHoldLifetime?,
            token: String
        )
        case failedHold(control: String)
        case replace(
            token: String,
            value: HBJSONValue,
            transitionSeconds: TimeInterval?
        )
        case failedReplace(token: String)
        case release(token: String)
    }

    enum StubError: Error {
        case holdFailed
    }

    private var events: [Event] = []
    private var nextTokenNumber = 1
    private let failingHoldNumber: Int?
    private let failingReplacementTokens: Set<String>
    private var notFoundReleaseTokens: Set<String> = []
    private var failingReleaseTokens: Set<String> = []
    private var sessionIdentifier = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    init(
        failingHoldNumber: Int? = nil,
        failingReplacementTokens: Set<String> = []
    ) {
        self.failingHoldNumber = failingHoldNumber
        self.failingReplacementTokens = failingReplacementTokens
    }

    func reactivate() async throws {
        events.append(.reactivate)
    }

    func currentSessionIdentifier() async -> UUID? {
        sessionIdentifier
    }

    func holdControl(
        _ control: String,
        at value: HBJSONValue,
        transitionSeconds: TimeInterval?,
        priority: Int?,
        lifetime: HBControlHoldLifetime?
    ) async throws -> HBControlHoldResult {
        let holdNumber = nextTokenNumber
        nextTokenNumber += 1
        guard holdNumber != failingHoldNumber else {
            events.append(.failedHold(control: control))
            throw StubError.holdFailed
        }

        let token = "hold-\(holdNumber)"
        events.append(
            .hold(
                control: control,
                value: value,
                transitionSeconds: transitionSeconds,
                priority: priority,
                lifetime: lifetime,
                token: token
            )
        )
        return HBControlHoldResult(
            token: token,
            control: control,
            value: value
        )
    }

    func replaceControlHold(
        token: String,
        with value: HBJSONValue,
        transitionSeconds: TimeInterval?
    ) async throws -> HBControlHoldReplaceResult {
        guard !failingReplacementTokens.contains(token) else {
            events.append(.failedReplace(token: token))
            throw StubError.holdFailed
        }
        events.append(
            .replace(
                token: token,
                value: value,
                transitionSeconds: transitionSeconds
            )
        )
        return HBControlHoldReplaceResult(
            token: token,
            control: "Lamp:Level",
            value: value
        )
    }

    func releaseControlHold(token: String) async throws
        -> HBControlReleaseResult
    {
        events.append(.release(token: token))
        if failingReleaseTokens.contains(token) {
            throw StubError.holdFailed
        }
        if notFoundReleaseTokens.contains(token) {
            throw HBProtocolError(
                code: HBProtocolErrorCodes.notFound,
                message: "Hold token is no longer present."
            )
        }
        return HBControlReleaseResult(releasedCount: 1)
    }

    func recordedEvents() -> [Event] {
        events
    }

    func clearEvents() {
        events = []
    }

    func failReleaseAsNotFound(token: String) {
        notFoundReleaseTokens.insert(token)
    }

    func failRelease(token: String) {
        failingReleaseTokens.insert(token)
    }

    func allowRelease(token: String) {
        failingReleaseTokens.remove(token)
    }

    func replaceSession() {
        sessionIdentifier = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
    }
}
