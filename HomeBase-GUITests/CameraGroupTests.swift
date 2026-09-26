import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraGroupTests: XCTestCase {
    func testFullScreenFocusPreservesGroupSessionsAndPausedHistory() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: true))
        group.toggle(try camera("B"))
        group.toggle(try camera("C", history: false))
        for session in group.sessions where session.historyAvailable {
            session.playback.history.configure(cameraID: session.id, transport: GroupHistoryFetcher())
            try await settled(session.playback.history)
        }
        let ids = group.sessions.map(\.id)
        let sessions = group.sessions.map(ObjectIdentifier.init)
        let renderers = group.sessions.map { ObjectIdentifier($0.playback.renderer) }
        let batches = group.sessions.map { $0.playback.history.buffer.batches.map(\.batch.id) }
        for focusedID in [nil, ids[1], ids[2], nil, ids[0], nil] {
            let presentation = CameraGroupPresentation(sessions: group.sessions, focusedCameraID: focusedID)
            XCTAssertEqual(presentation.focusedSession?.id, focusedID)
            XCTAssertEqual(presentation.visibleSessions.map(\.id), focusedID.map { [$0] } ?? ids)
            XCTAssertEqual(presentation.showsMultipleCameras, focusedID == nil)
            XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
            XCTAssertEqual(group.sessions.map { ObjectIdentifier($0.playback.renderer) }, renderers)
            XCTAssertEqual(group.sessions.map { $0.playback.history.buffer.batches.map(\.batch.id) }, batches)
            XCTAssertEqual(group.cursor, 500)
            XCTAssertTrue(group.isPaused)
            XCTAssertTrue(group.active)
        }
        let invalid = CameraGroupPresentation(sessions: group.sessions, focusedCameraID: "removed")
        XCTAssertNil(invalid.focusedSession)
        XCTAssertEqual(invalid.visibleSessions.map(\.id), ids)
        group.toggle(try camera("C", history: false))
        group.toggle(try camera("B"))
        XCTAssertNil(CameraGroupPresentation(sessions: group.sessions, focusedCameraID: ids[0]).focusedSession,
            "Collapsing to one camera removes the Back override")
    }

    func testFullScreenUsesSingleCameraFrameWhileHiddenPanesRetainTheirFrames() throws {
        let client = try makeClient()
        let sessions = try ["A", "B", "C", "D"].map { CameraGroupSession(camera: try camera($0), client: client) }
        defer { sessions.forEach { $0.close() } }
        let size = CGSize(width: 900, height: 600)
        let divisions: [CameraGroupLayout.Division?] = [nil,
            .init(frame: CGRect(x: 440, y: 0, width: 20, height: 600), margins: EdgeInsets()),
            .init(frame: CGRect(x: 0, y: 290, width: 900, height: 20), margins: EdgeInsets())]
        for division in divisions {
            let cells = division.map { CameraGroupLayout.cells(count: 4, in: size, division: $0) }
                ?? CameraGroupLayout.cells(count: 4, in: size)
            for focused in sessions {
                let presentation = CameraGroupPresentation(sessions: sessions, focusedCameraID: focused.id)
                for (index, session) in sessions.enumerated() {
                    let expected = session === focused
                        ? (division.map { CameraGroupLayout.cells(count: 1, in: size, division: $0)[0] }
                            ?? CGRect(origin: .zero, size: size)) : cells[index]
                    XCTAssertEqual(presentation.frame(for: session, normal: cells[index], size: size, division: division), expected)
                    XCTAssertEqual(presentation.isVisible(session), session === focused)
                }
            }
        }
    }

    func testFocusedQualityDoesNotChangeOtherCamerasAndGroupCanReapplyItsPreference() throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .live)
        group.toggle(try camera("B"))
        group.setQuality(.high)
        let presentation = CameraGroupPresentation(sessions: group.sessions, focusedCameraID: "B")
        try XCTUnwrap(presentation.focusedSession).setQuality(.medium)
        XCTAssertEqual(group.sessions.map(\.quality), [.high, .medium])
        XCTAssertEqual(group.quality, .high)
        group.setQuality(.high)
        XCTAssertEqual(group.sessions.map(\.quality), [.high, .high])
    }

    func testPickerDefaultsToMultipleWithoutChangingSingleCameraPlayback() async throws {
        let client = try makeClient()
        let session = CameraGroupSession(camera: try camera("A"), client: client, quality: .high)
        let group = CameraGroupPlayback(client: client, initialSession: session)
        defer { group.deactivate() }
        session.playback.setNVRHistoryAvailable(true)
        session.playback.history.configure(cameraID: "A", transport: GroupHistoryFetcher())
        session.playback.seek(to: Date(timeIntervalSince1970: 500), paused: true)
        try await settled(session.playback.history)
        let batches = session.playback.history.buffer.batches.map(\.batch.id)
        let renderer = session.playback.renderer
        XCTAssertTrue(group.multipleSelectionEnabled)
        for _ in 0..<3 {
            group.setMultipleSelection(false)
            XCTAssertFalse(group.multipleSelectionEnabled)
            group.beginCameraSelection()
            XCTAssertTrue(group.multipleSelectionEnabled, "Every opening defaults to multiple selection")
            XCTAssertFalse(group.active, "Opening the picker must not change clock ownership")
            XCTAssertFalse(group.hasMultipleCameras, "One camera keeps its controls and hides its label")
            XCTAssertFalse(session.playback.externallyClocked)
            XCTAssertTrue(group.sessions[0] === session)
            XCTAssertTrue(session.playback.renderer === renderer)
            XCTAssertTrue(session.playback.isPaused)
            XCTAssertEqual(session.playback.history.position, 500)
            XCTAssertEqual(session.quality, .high)
            XCTAssertEqual(session.playback.history.buffer.batches.map(\.batch.id), batches)
        }
    }

    func testAddingSecondCameraStartsSharedClockAndRemovingEitherRestoresSingleCamera() async throws {
        for removeOriginal in [false, true] {
            let client = try makeClient(), a = try camera("A"), b = try camera("B")
            let original = CameraGroupSession(camera: a, client: client, quality: .medium)
            let group = CameraGroupPlayback(client: client, initialSession: original)
            defer { group.deactivate() }
            original.playback.setNVRHistoryAvailable(true)
            original.playback.history.configure(cameraID: "A", transport: GroupHistoryFetcher())
            original.playback.seek(to: Date(timeIntervalSince1970: 500), paused: true)
            try await settled(original.playback.history)
            original.playback.setPlaybackSpeed(.double)
            group.toggle(b)
            XCTAssertTrue(group.active)
            XCTAssertTrue(group.hasMultipleCameras)
            XCTAssertEqual(group.cursor, 500)
            XCTAssertTrue(group.isPaused)
            XCTAssertEqual(group.sessions.map(\.quality), [.medium, .medium])
            let survivor = group.sessions[removeOriginal ? 1 : 0]
            survivor.playback.history.configure(cameraID: survivor.id, transport: GroupHistoryFetcher())
            try await settled(survivor.playback.history)
            let renderer = survivor.playback.renderer
            let batches = survivor.playback.history.buffer.batches.map(\.batch.id)
            group.toggle(removeOriginal ? a : b)
            XCTAssertTrue(group.multipleSelectionEnabled)
            XCTAssertFalse(group.hasMultipleCameras)
            XCTAssertFalse(group.active)
            XCTAssertTrue(group.sessions[0] === survivor)
            XCTAssertTrue(survivor.playback.renderer === renderer)
            XCTAssertFalse(survivor.playback.externallyClocked)
            XCTAssertTrue(survivor.playback.isPaused)
            XCTAssertEqual(survivor.playback.history.position, 500)
            XCTAssertEqual(survivor.playback.playbackSpeed, .double)
            XCTAssertEqual(survivor.playback.history.buffer.batches.map(\.batch.id), batches)
            XCTAssertTrue(CameraPlayerPanelAvailability(historyAvailable: true, ptzSupported: true,
                isLive: true, isMultiple: group.hasMultipleCameras).showsPTZ)
        }
    }

    func testPickerCanCollapseAGroupAndReopenWithoutRestartingItsSurvivor() async throws {
        let client = try makeClient(), a = try camera("A"), b = try camera("B")
        let original = CameraGroupSession(camera: a, client: client)
        let group = CameraGroupPlayback(client: client, initialSession: original)
        defer { group.deactivate() }
        group.toggle(b)
        XCTAssertTrue(group.active)
        group.setMultipleSelection(false)
        XCTAssertFalse(group.multipleSelectionEnabled)
        XCTAssertFalse(group.active)
        XCTAssertEqual(group.sessions.map(\.id), [a.id])
        group.beginCameraSelection()
        XCTAssertTrue(group.multipleSelectionEnabled)
        XCTAssertFalse(group.active)
        XCTAssertTrue(group.sessions[0] === original)
        group.toggle(a)
        XCTAssertEqual(group.sessions.count, 1, "The final camera cannot be deselected")
        let unsupported = CameraVideoDevice(device: b.device, capability: .init(qualities: [.low]))
        group.toggle(unsupported)
        XCTAssertFalse(group.active, "A rejected selection must not start a shared clock")
        XCTAssertEqual(group.sessions.count, 1)
        XCTAssertNotNil(group.error)
    }

    func testHistorySourceFallsForwardToFirstSelectedCameraWithHistory() throws {
        let client = try makeClient()
        let noHistory = try camera("No History", history: false)
        let firstHistory = try camera("First History")
        let secondHistory = try camera("Second History")
        let initial = CameraGroupSession(camera: noHistory, client: client)
        let group = CameraGroupPlayback(client: client, initialSession: initial)
        defer { group.deactivate() }

        XCTAssertNil(group.historySourceSession)
        group.toggle(firstHistory)
        group.toggle(secondHistory)
        XCTAssertEqual(group.historySourceSession?.id, firstHistory.id)

        group.toggle(firstHistory)
        XCTAssertEqual(group.historySourceSession?.id, secondHistory.id)
    }

    func testSharedSpeedKeepsEveryHistoryPaneInLockstepAndSurvivesMultipleToggle() async throws {
        var now = 100.0
        let group = try makeGroup(clock: { now })
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: false))
        group.toggle(try camera("B"))
        for session in group.sessions {
            session.playback.history.configure(cameraID: session.id, transport: GroupHistoryFetcher())
            try await settled(session.playback.history)
        }
        group.setPlaybackSpeed(.quadruple)
        now += 1; group.tick()
        XCTAssertEqual(group.cursor, 504)
        XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [504, 504])
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.playbackSpeed == .quadruple })
        group.togglePause(); group.setPlaybackSpeed(.double)
        now += 5; group.tick()
        XCTAssertEqual(group.cursor, 504)
        XCTAssertTrue(group.isPaused)
        group.toggle(try camera("C"))
        XCTAssertEqual(group.sessions.last?.playback.playbackSpeed, .double)
        group.setMultiple(false)
        XCTAssertEqual(group.sessions[0].playback.playbackSpeed, .double)
        XCTAssertTrue(group.sessions[0].playback.isPaused)
        group.setMultiple(true)
        XCTAssertEqual(group.playbackSpeed, .double)
        XCTAssertTrue(group.isPaused)
        group.goLive()
        XCTAssertEqual(group.playbackSpeed, .normal)
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.playbackSpeed == .normal })
    }

    func testHistoryGroupSlowsAtLiveEdgeWithoutLeavingHistory() async throws {
        var now = 100.0
        let group = try makeGroup(clock: { now })
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(995, paused: false))
        group.toggle(try camera("B"))
        for session in group.sessions {
            session.playback.history.configure(cameraID: session.id, transport: GroupHistoryFetcher())
            try await settled(session.playback.history)
        }
        group.setPlaybackSpeed(.quadruple)
        for _ in 0..<25 {
            now += 0.1; group.tick()
            for session in group.sessions { try await settled(session.playback.history) }
        }
        XCTAssertEqual(group.playbackSpeed, .normal)
        XCTAssertEqual(group.source, .history)
        XCTAssertFalse(group.isPaused)
        XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [group.cursor, group.cursor])
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isUsingHistory && $0.playback.playbackSpeed == .normal })
        let position = try XCTUnwrap(group.cursor)
        now += 0.1; group.tick()
        XCTAssertLessThanOrEqual(try XCTUnwrap(group.cursor) - position, 0.100_001)
    }

    func testGroupDoesNotResetSpeedAtAnUnloadedHistoryBoundary() async throws {
        var now = 100.0
        let group = try makeGroup(clock: { now })
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: false))
        group.sessions[0].playback.history.configure(cameraID: "A", transport: GroupHistoryFetcher())
        try await settled(group.sessions[0].playback.history)
        group.setPlaybackSpeed(.quadruple)
        now += 10; group.tick()
        XCTAssertEqual(group.cursor, 530)
        XCTAssertEqual(group.playbackSpeed, .quadruple)
        XCTAssertEqual(group.source, .history)
    }

    func testBackgroundFreezesWholeHistoryGroupUntilExplicitPlay() async throws {
        var now = 100.0
        let group = try makeGroup(clock: { now })
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: false))
        group.toggle(try camera("B"))
        for session in group.sessions {
            session.playback.history.configure(cameraID: session.id, transport: GroupHistoryFetcher())
            try await settled(session.playback.history)
        }
        now += 1; group.tick()
        let cursor = group.cursor
        group.suspend(); group.suspend()
        XCTAssertTrue(group.isPaused)
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isPaused })
        now += 600; group.tick()
        XCTAssertEqual(group.cursor, cursor)
        group.resume()
        for session in group.sessions {
            session.playback.history.configure(cameraID: session.id, transport: GroupHistoryFetcher())
            try await settled(session.playback.history)
        }
        now += 1; group.tick()
        XCTAssertEqual(group.cursor, cursor)
        XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [cursor, cursor])
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isPaused })
        group.togglePause(); now += 1; group.tick()
        XCTAssertEqual(group.cursor, try XCTUnwrap(cursor) + 1)
    }

    func testOneInterruptedPanePausesWholeGroupButRemovedPaneDoesNot() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        let secondCamera = try camera("B")
        group.activate(camera: try camera("A"), position: .canonical(500, paused: false))
        group.toggle(secondCamera)
        let second = group.sessions[1]
        second.playback.streamDidStop?()
        XCTAssertTrue(group.isPaused)
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isPaused })
        group.togglePause()
        XCTAssertFalse(group.isPaused)
        group.toggle(secondCamera)
        second.playback.streamDidStop?()
        XCTAssertFalse(group.isPaused)
        group.goLive()
        group.sessions[0].playback.streamDidStop?()
        group.suspend(); group.resume(); group.tick()
        XCTAssertTrue(group.isLive)
        XCTAssertFalse(group.isPaused)
        XCTAssertTrue(group.sessions[0].playback.isLive)
    }

    func testSingleCameraSessionAlsoPausesHistoryOnGroupSuspension() async throws {
        let client = try makeClient()
        let session = CameraGroupSession(camera: try camera("A"), client: client)
        let group = CameraGroupPlayback(client: client, initialSession: session)
        defer { group.deactivate() }
        session.playback.setNVRHistoryAvailable(true)
        session.playback.seek(to: Date(timeIntervalSince1970: 500), paused: false)
        XCTAssertFalse(group.active)
        group.suspend(); group.resume()
        XCTAssertTrue(session.playback.isPaused)
        XCTAssertEqual(session.playback.history.position, 500)
    }

    func testCameraResourcesSerializeRapidSuspendAndResume() async throws {
        let spy = CameraSessionResourceSpy()
        let coordinator = CameraSessionResourceCoordinator(
            startLiveVideo: { _ in await spy.start("video") },
            stopLiveVideo: { immediately in
                spy.stop("video", immediately: immediately)
            },
            startControls: { await spy.start("controls") },
            stopControls: { spy.stop("controls") }
        )

        coordinator.setActive(true, access: nil)
        for _ in 0..<100 {
            if spy.startCount["video"] == 1,
               spy.startCount["controls"] == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(spy.startCount["video"], 1)
        XCTAssertEqual(spy.startCount["controls"], 1)

        // The second activation arrives before the suspended generation has
        // finished tearing down. The final start must nevertheless be last.
        coordinator.setActive(false, access: nil, stopImmediately: true)
        coordinator.setActive(true, access: nil)
        await coordinator.waitForTransitions()

        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(spy.startCount["video"], 2)
        XCTAssertEqual(spy.startCount["controls"], 2)
        XCTAssertEqual(spy.events.filter { $0.hasPrefix("video.") }.last, "video.start.2")
        XCTAssertEqual(spy.events.filter { $0.hasPrefix("controls.") }.last, "controls.start.2")
        XCTAssertTrue(
            spy.events.contains("video.stop.immediately"),
            "Access/background teardown must reach the running stream before cancellation cleanup"
        )

        let settledEvents = spy.events
        coordinator.setActive(true, access: nil)
        await coordinator.waitForTransitions()
        XCTAssertEqual(spy.events, settledEvents, "Duplicate activation is a lifecycle no-op")

        coordinator.close(stopImmediately: true)
        await coordinator.waitForTransitions()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(
            spy.events.filter { $0.hasPrefix("video.") }.last,
            "video.stop.immediately"
        )
        XCTAssertEqual(spy.events.filter { $0.hasPrefix("controls.") }.last, "controls.stop")
    }

    func testFailedControlsCanRestartWithoutTogglingCameraLifecycle() async {
        var videoStarts = 0
        var controlsStarts = 0
        let coordinator = CameraSessionResourceCoordinator(
            startLiveVideo: { _ in videoStarts += 1 },
            stopLiveVideo: { _ in },
            startControls: { controlsStarts += 1 },
            stopControls: {}
        )

        coordinator.setActive(true, access: nil)
        await coordinator.waitForTransitions()
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(videoStarts, 1)
        XCTAssertEqual(controlsStarts, 1)

        // A failed monitor is restarted in place. The camera session remains
        // active and its live stream is not used as a recovery side effect.
        coordinator.restartControls()
        await coordinator.waitForTransitions()
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(videoStarts, 1)
        XCTAssertEqual(controlsStarts, 2)

        coordinator.close()
        await coordinator.waitForTransitions()
    }

    func testHistoryCredentialRefreshCannotReactivateSuspendedResources() throws {
        let client = try makeClient()
        let session = CameraGroupSession(
            camera: try camera("A"),
            client: client
        )
        let group = CameraGroupPlayback(
            client: client,
            initialSession: session
        )
        defer { group.deactivate() }

        XCTAssertFalse(session.resourcesActive)
        group.refreshHistoryAccess(nil)
        XCTAssertFalse(
            session.resourcesActive,
            "A late credential result must not restart background resources"
        )
    }

    func testMultipleToggleRetainsSessionRendererQualityAndHistoryCache() async throws {
        let client = try makeClient()
        let session = CameraGroupSession(camera: try camera("A"), client: client, quality: .high)
        let group = CameraGroupPlayback(client: client, initialSession: session)
        defer { group.deactivate() }
        let transport = GroupHistoryFetcher()
        session.playback.setNVRHistoryAvailable(true)
        session.playback.history.configure(cameraID: "A", transport: transport)
        session.playback.seek(to: Date(timeIntervalSince1970: 500), paused: true)
        try await settled(session.playback.history)
        let batches = session.playback.history.buffer.batches.map(\.batch.id)
        let renderer = session.playback.renderer
        for _ in 0..<3 {
            group.setMultiple(true)
            XCTAssertTrue(group.active)
            XCTAssertTrue(group.sessions[0] === session)
            XCTAssertTrue(session.playback.renderer === renderer)
            XCTAssertEqual(group.cursor, 500)
            group.tick()
            group.setMultiple(false)
            XCTAssertFalse(group.active)
            XCTAssertTrue(group.sessions[0] === session)
            XCTAssertEqual(session.quality, .high)
            XCTAssertEqual(session.playback.playbackDate, Date(timeIntervalSince1970: 500))
            XCTAssertTrue(session.playback.isPaused)
            XCTAssertFalse(session.playback.externallyClocked)
            XCTAssertEqual(session.playback.history.buffer.batches.map(\.batch.id), batches)
        }
    }

    func testExitingMultipleRetainsSurvivorEvenAfterOriginalWasRemoved() async throws {
        let client = try makeClient(), a = try camera("A"), b = try camera("B")
        let original = CameraGroupSession(camera: a, client: client)
        let group = CameraGroupPlayback(client: client, initialSession: original)
        defer { group.deactivate() }
        group.setMultiple(true); group.toggle(b)
        let survivor = group.sessions[1]
        group.toggle(a)
        group.setMultiple(false)
        XCTAssertTrue(group.sessions[0] === survivor)
        XCTAssertEqual(group.sessions.map(\.id), [b.id])
        XCTAssertFalse(survivor.playback.externallyClocked)
        group.setMultiple(true)
        XCTAssertTrue(group.sessions[0] === survivor)
        XCTAssertEqual(group.selection?.ids, [b.id])
        group.toggle(a)
        XCTAssertFalse(group.sessions[1] === original, "Removed cameras alone get new sessions")
    }

    func testExitingMultipleClosesOnlyRemovedReaders() async throws {
        let client = try makeClient()
        let first = CameraGroupSession(camera: try camera("A"), client: client)
        let group = CameraGroupPlayback(client: client, initialSession: first)
        defer { group.deactivate() }
        group.setMultiple(true); group.toggle(try camera("B"))
        let second = group.sessions[1]
        let transport = GroupHistoryFetcher()
        second.playback.history.configure(cameraID: "B", transport: transport)
        group.seek(to: Date(timeIntervalSince1970: 500))
        try await settled(second.playback.history)
        group.setMultiple(false)
        XCTAssertTrue(first.playback.isUsingHistory)
        XCTAssertFalse(second.playback.isUsingHistory)
        XCTAssertTrue(second.playback.history.buffer.batches.isEmpty)
    }
    func testSelectionKeepsOneToFourCamerasInSelectionOrder() async {
        var selection = CameraMultipleSelection(first: "a")
        selection.toggle("a")
        XCTAssertEqual(selection.ids, ["a"])
        for id in ["b", "c", "d", "e"] { selection.toggle(id) }
        XCTAssertEqual(selection.ids, ["a", "b", "c", "d"])
        XCTAssertFalse(selection.canToggle("e"))
        selection.toggle("a"); selection.toggle("e")
        XCTAssertEqual(selection.ids, ["b", "c", "d", "e"])
    }

    func testGridFillsWidthWithoutOverscanAndLeavesFourthCellEmpty() async {
        let size = CGSize(width: 852, height: 393)
        for count in 1...4 {
            let cells = CameraGroupLayout.cells(count: count, in: size)
            XCTAssertEqual(cells.count, count)
            XCTAssertTrue(cells.allSatisfy { CGRect(origin: .zero, size: size).contains($0) })
            XCTAssertEqual(cells.first?.minX, 0)
            if count > 1 { XCTAssertEqual(cells[1].maxX, size.width) }
            if count == 2 { XCTAssertEqual(cells[0].height, size.height) }
            if count >= 3 { XCTAssertEqual(cells[2].minY, size.height / 2) }
        }
        XCTAssertTrue(CameraGroupLayout.cells(count: 2, in: .zero).isEmpty)
    }

    func testLandscapeGridVideoFramesGravitateTowardCenterSeams() {
        let size = CGSize(width: 852, height: 393)
        for count in 2...4 {
            let cells = CameraGroupLayout.cells(count: count, in: size)
            let videos = cells.enumerated().map { index, cell in
                CameraGroupLayout.videoFrame(
                    in: cell,
                    aspectRatio: 16 / 9,
                    gravity: CameraGroupLayout.videoGravity(
                        index: index,
                        count: count,
                        arrangement: .grid
                    )
                )
            }

            XCTAssertEqual(videos[0].maxX, size.width / 2, accuracy: 0.0001)
            XCTAssertEqual(videos[1].minX, size.width / 2, accuracy: 0.0001)
            if count > 2 {
                XCTAssertEqual(videos[0].maxY, size.height / 2, accuracy: 0.0001)
                XCTAssertEqual(videos[2].minY, size.height / 2, accuracy: 0.0001)
                XCTAssertEqual(videos[2].maxX, size.width / 2, accuracy: 0.0001)
            }
        }
    }

    func testVerticalDivisionUsesFoldAsGutterAndFillsRowsInCameraOrder() {
        let size = CGSize(width: 1_000, height: 800)
        let division = CameraGroupLayout.Division(
            frame: CGRect(x: 490, y: 0, width: 20, height: 800),
            margins: EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        )
        XCTAssertEqual(division.axis, .vertical)
        XCTAssertEqual(
            CameraGroupLayout.cells(count: 1, in: size, division: division),
            [CGRect(x: 0, y: 0, width: 480, height: 800)]
        )
        XCTAssertEqual(
            CameraGroupLayout.cells(count: 2, in: size, division: division),
            [
                CGRect(x: 0, y: 0, width: 480, height: 800),
                CGRect(x: 520, y: 0, width: 480, height: 800),
            ]
        )
        XCTAssertEqual(
            CameraGroupLayout.cells(count: 4, in: size, division: division),
            [
                CGRect(x: 0, y: 0, width: 480, height: 400),
                CGRect(x: 520, y: 0, width: 480, height: 400),
                CGRect(x: 0, y: 400, width: 480, height: 400),
                CGRect(x: 520, y: 400, width: 480, height: 400),
            ]
        )
        XCTAssertEqual(
            CameraGroupLayout.cells(count: 3, in: size, division: division),
            Array(CameraGroupLayout.cells(count: 4, in: size, division: division).prefix(3))
        )
    }

    func testHorizontalDivisionTransposesFoldLayout() {
        let size = CGSize(width: 800, height: 1_000)
        let division = CameraGroupLayout.Division(
            frame: CGRect(x: 0, y: 490, width: 800, height: 20),
            margins: EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        )
        XCTAssertEqual(division.axis, .horizontal)
        XCTAssertEqual(
            CameraGroupLayout.cells(count: 2, in: size, division: division),
            [
                CGRect(x: 0, y: 0, width: 800, height: 480),
                CGRect(x: 0, y: 520, width: 800, height: 480),
            ]
        )
        XCTAssertEqual(
            CameraGroupLayout.cells(count: 4, in: size, division: division),
            [
                CGRect(x: 0, y: 0, width: 400, height: 480),
                CGRect(x: 0, y: 520, width: 400, height: 480),
                CGRect(x: 400, y: 0, width: 400, height: 480),
                CGRect(x: 400, y: 520, width: 400, height: 480),
            ]
        )
    }

    func testFoldPaneVideosTouchWithoutClosingTheReservedDivision() {
        // Both canvases leave spare space between aspect-fitted videos when
        // centered individually, including the less common horizontal case.
        let scenarios: [(CGSize, CameraGroupLayout.Division)] = [
            (CGSize(width: 1_000, height: 800), .init(
                frame: CGRect(x: 490, y: 0, width: 20, height: 800),
                margins: EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            )),
            (CGSize(width: 1_600, height: 800), .init(
                frame: CGRect(x: 0, y: 390, width: 1_600, height: 20),
                margins: EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            )),
        ]
        for (size, division) in scenarios {
            for count in 1...4 {
                let cells = CameraGroupLayout.cells(count: count, in: size, division: division)
                let videos = cells.enumerated().map { index, cell in
                    CameraGroupLayout.videoFrame(
                        in: cell,
                        aspectRatio: 16 / 9,
                        gravity: CameraGroupLayout.videoGravity(
                            index: index, count: count, divisionAxis: division.axis
                        )
                    )
                }
                for index in videos.indices {
                    XCTAssertTrue(cells[index].contains(videos[index]))
                    XCTAssertFalse(videos[index].intersects(division.reservedFrame))
                    if count <= 2 {
                        XCTAssertEqual(videos[index].midX, cells[index].midX, accuracy: 0.0001)
                        XCTAssertEqual(videos[index].midY, cells[index].midY, accuracy: 0.0001)
                    } else if index >= 2 {
                        switch division.axis {
                        case .vertical:
                            XCTAssertEqual(videos[index - 2].maxY, videos[index].minY, accuracy: 0.0001)
                        case .horizontal:
                            XCTAssertEqual(videos[index - 2].maxX, videos[index].minX, accuracy: 0.0001)
                        }
                    }
                }
            }
        }
    }

    func testDivisionLabelsFollowOutsideEdgesOfSideBySidePanes() {
        for index in 0..<4 {
            XCTAssertEqual(
                CameraGroupLayout.labelAnchor(index: index, count: 4, divisionAxis: .vertical),
                index.isMultiple(of: 2) ? .leading : .trailing
            )
            XCTAssertEqual(
                CameraGroupLayout.labelAnchor(index: index, count: 4, divisionAxis: .horizontal),
                index < 2 ? .leading : .trailing
            )
        }
        XCTAssertEqual(
            CameraGroupLayout.labelAnchor(index: 1, count: 2, divisionAxis: .horizontal),
            .leading
        )
        XCTAssertTrue(CameraGroupLayout.labelsBelowVideo(count: 2, divisionAxis: .vertical))
        XCTAssertFalse(CameraGroupLayout.labelsBelowVideo(count: 2, divisionAxis: .horizontal))
    }

    func testGridLabelsAnchorTowardOutsideEdgesAndColumnLabelsStayLeading() {
        let cell = CGRect(x: 0, y: 0, width: 320, height: 180)
        let labelSize = CGSize(width: 100, height: 24)

        for index in 0..<4 {
            let anchor = CameraGroupLayout.labelAnchor(
                index: index,
                arrangement: .grid
            )
            let frame = CameraGroupLayout.labelFrame(
                in: cell,
                safeBounds: cell,
                aspectRatio: 16 / 9,
                labelSize: labelSize,
                belowVideo: false,
                anchor: anchor
            )
            if index.isMultiple(of: 2) {
                XCTAssertEqual(anchor, .leading)
                XCTAssertEqual(frame.minX, cell.minX)
            } else {
                XCTAssertEqual(anchor, .trailing)
                XCTAssertEqual(frame.maxX, cell.maxX)
            }
            XCTAssertEqual(
                CameraGroupLayout.labelAnchor(
                    index: index,
                    arrangement: .column
                ),
                .leading
            )
        }
    }

    func testArrangementMaximizesDisplayedVideoAreaForEachCameraCount() {
        let portrait = CGSize(width: 393, height: 852)
        let landscape = CGSize(width: 852, height: 393)
        for count in 2...4 {
            XCTAssertEqual(CameraGroupLayout.arrangement(count: count, in: portrait), .column)
            XCTAssertEqual(CameraGroupLayout.arrangement(count: count, in: landscape), .grid)
        }

        let square = CGSize(width: 600, height: 600)
        XCTAssertEqual(CameraGroupLayout.arrangement(count: 1, in: square), .grid)
        XCTAssertEqual(CameraGroupLayout.arrangement(count: 2, in: square), .column)
        XCTAssertEqual(CameraGroupLayout.arrangement(count: 3, in: square), .column)
        XCTAssertEqual(CameraGroupLayout.arrangement(count: 4, in: square), .grid)

        XCTAssertEqual(
            CameraGroupLayout.arrangement(
                count: 3,
                in: square,
                aspectRatios: Array(repeating: 4 / 3, count: 3)
            ),
            .grid,
            "Actual camera ratios, rather than a generic 16:9 feed, decide which layout shows more picture"
        )
    }

    func testSafeAreaPolicyLimitsCompactWidthExemptionToDevicesWithHinges() {
        let classes: [UserInterfaceSizeClass?] = [nil, .compact, .regular]
        for horizontal in classes {
            for vertical in classes {
                for controlsVisible in [true, false] {
                    for hasDeviceHinge in [true, false] {
                        XCTAssertEqual(
                            CameraGroupLayout.ignoresSafeArea(
                                horizontal: horizontal,
                                vertical: vertical,
                                controlsVisible: controlsVisible,
                                hasDeviceHinge: hasDeviceHinge
                            ),
                            !controlsVisible || vertical == .compact
                                || (hasDeviceHinge && horizontal == .compact)
                        )
                    }
                }
            }
        }
    }

    func testOcclusionPolicyOnlyExemptsClosedHingedDevicesInCompactWidth() {
        let classes: [UserInterfaceSizeClass?] = [nil, .regular, .compact]
        for horizontal in classes {
            for hinge in [CameraDeviceHingeState(),
                          CameraDeviceHingeState(isPresent: true, isClosed: false),
                          CameraDeviceHingeState(isPresent: true, isClosed: true)] {
                XCTAssertEqual(CameraGroupLayout.avoidsOcclusions(horizontal: horizontal, hinge: hinge),
                    horizontal == .compact && !(hinge.isPresent && hinge.isClosed))
                // Hiding controls may expand the canvas, but must not weaken
                // the independent hardware-occlusion policy.
                XCTAssertTrue(CameraGroupLayout.ignoresSafeArea(horizontal: horizontal, vertical: .regular,
                    controlsVisible: false, hasDeviceHinge: hinge.isPresent))
            }
        }
    }

    func testOcclusionsTrimPortraitTopAndEitherLandscapeSide() {
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(
            in: CGSize(width: 400, height: 800),
            occlusions: [CGRect(x: 140, y: 10, width: 120, height: 40)]),
            CGRect(x: 0, y: 50, width: 400, height: 700))
        for left in [true, false] {
            XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(
                in: CGSize(width: 800, height: 400),
                occlusions: [CGRect(x: left ? 10 : 750, y: 140, width: 40, height: 120)]),
                CGRect(x: left ? 50 : 0, y: 0, width: 750, height: 400))
        }
    }

    func testLegacyOcclusionFallbackReservesSixtyFourPointsAtTopAndBottom() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 402, height: 874)] {
            let regions = CameraGroupLayout.legacyOcclusionFrames(in: size, isPhone: true,
                ignoresSafeArea: true, vertical: .regular)
            let frame = CameraGroupLayout.unobscuredContentRect(in: size, occlusions: regions)
            XCTAssertEqual(frame, CGRect(x: 0, y: 64, width: size.width, height: size.height - 128))
            XCTAssertEqual(frame.midY, size.height / 2)
            XCTAssertTrue(regions.allSatisfy { frame.intersection($0).isEmpty })
        }
    }

    func testLegacyOcclusionFallbackDoesNotInsetCompactHeightEvenWithCompactWidth() {
        XCTAssertTrue(CameraGroupLayout.avoidsOcclusions(horizontal: .compact, hinge: CameraDeviceHingeState()))
        let classes: [UserInterfaceSizeClass?] = [.compact, nil]
        for vertical in classes {
            let size = CGSize(width: 852, height: 393)
            let regions = CameraGroupLayout.legacyOcclusionFrames(in: size, isPhone: true,
                ignoresSafeArea: true, vertical: vertical)
            XCTAssertTrue(regions.isEmpty)
            XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: size, occlusions: regions),
                CGRect(origin: .zero, size: size))
        }
    }

    func testLegacyOcclusionFallbackDoesNotDoubleInsetSafeAreasOrAffectOtherDevices() {
        let size = CGSize(width: 393, height: 852)
        for (isPhone, ignoresSafeArea) in [(true, false), (false, false), (false, true)] {
            XCTAssertTrue(CameraGroupLayout.legacyOcclusionFrames(in: size,
                isPhone: isPhone, ignoresSafeArea: ignoresSafeArea, vertical: .regular).isEmpty)
        }
        XCTAssertTrue(CameraGroupLayout.legacyOcclusionFrames(in: .zero,
            isPhone: true, ignoresSafeArea: true, vertical: .regular).isEmpty)
        let tiny = CGSize(width: 200, height: 100)
        let regions = CameraGroupLayout.legacyOcclusionFrames(in: tiny, isPhone: true,
            ignoresSafeArea: true, vertical: .regular)
        XCTAssertTrue(regions.allSatisfy { CGRect(origin: .zero, size: tiny).contains($0) })
        XCTAssertTrue(CameraGroupLayout.unobscuredContentRect(in: tiny, occlusions: regions).isEmpty)
    }

    func testTopQuarterOcclusionsBalanceAtBoundaryButNotBelowIt() {
        let size = CGSize(width: 400, height: 800)
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: size,
            occlusions: [CGRect(x: 0, y: 100, width: 400, height: 100)]),
            CGRect(x: 0, y: 200, width: 400, height: 400),
            "The complete occlusion must fit within the top quarter, including its boundary")
        let belowQuarter = CameraGroupLayout.unobscuredContentRect(in: size,
            occlusions: [CGRect(x: 0, y: 100, width: 400, height: 101)])
        XCTAssertEqual(belowQuarter, CGRect(x: 0, y: 201, width: 400, height: 599))
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: size,
            occlusions: [CGRect(x: 140, y: 750, width: 120, height: 40)]),
            CGRect(x: 0, y: 0, width: 400, height: 750),
            "A bottom-only obstruction does not enable the top-cutout heuristic")
    }

    func testTopOcclusionBalancesAgainstLargerBottomObstruction() {
        let size = CGSize(width: 400, height: 800)
        let obstacles = [CGRect(x: 140, y: -10, width: 120, height: 60),
                         CGRect(x: 100, y: 720, width: 200, height: 80)]
        for regions in [obstacles, Array(obstacles.reversed())] {
            let actual = CameraGroupLayout.unobscuredContentRect(in: size, occlusions: regions)
            XCTAssertEqual(actual, CGRect(x: 0, y: 80, width: 400, height: 640))
            XCTAssertEqual(actual.midY, size.height / 2)
            XCTAssertTrue(regions.allSatisfy { actual.intersection($0).isEmpty })
        }
    }

    func testTopCornerOcclusionCanKeepFullHeightWhenSideAvoidanceIsLarger() {
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: CGSize(width: 400, height: 800),
            occlusions: [CGRect(x: 0, y: 10, width: 20, height: 40)]),
            CGRect(x: 20, y: 0, width: 380, height: 800),
            "Balance is vertical; don't force top/bottom padding if the best rectangle already avoids the cutout")
    }

    func testBalancedRectangleNeverExpandsAGapThatDoesNotCrossTheCenter() {
        XCTAssertTrue(CameraGroupLayout.unobscuredContentRect(in: CGSize(width: 400, height: 800),
            occlusions: [CGRect(x: 140, y: 0, width: 120, height: 40),
                         CGRect(x: 0, y: 350, width: 400, height: 100)]).isEmpty,
            "If no centered rectangle is possible, don't turn negative height into an overlapping rectangle")
    }

    func testUnobscuredRectangleAvoidsEveryRegionRegardlessOfEnumerationOrder() {
        let size = CGSize(width: 400, height: 800)
        let obstacles = [CGRect(x: 140, y: -10, width: 120, height: 60),
                         CGRect(x: 0, y: 300, width: 30, height: 100),
                         CGRect(x: 380, y: 500, width: 40, height: 80),
                         CGRect(x: 80, y: 780, width: 100, height: 40)]
        let expected = CGRect(x: 30, y: 50, width: 350, height: 700)
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: size, occlusions: obstacles), expected)
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: size, occlusions: obstacles.reversed()), expected)
        for count in 1...4 {
            let arrangement = CameraGroupLayout.arrangement(count: count, in: expected.size)
            for cell in CameraGroupLayout.cells(count: count, in: expected.size, arrangement: arrangement) {
                let global = cell.offsetBy(dx: expected.minX, dy: expected.minY)
                XCTAssertTrue(expected.contains(global))
                XCTAssertTrue(obstacles.allSatisfy { global.intersection($0).isEmpty })
            }
        }
    }

    func testOcclusionsOutsideCanvasOrAlreadyAboveSafeAreaDoNotReserveExtraSpace() {
        let size = CGSize(width: 400, height: 700)
        let bounds = CGRect(origin: .zero, size: size)
        for obstacles in [[], [.zero], [.null],
                          [CGRect(x: 100, y: -50, width: 120, height: 40)],
                          [CGRect(x: 400, y: 200, width: 30, height: 40)]] as [[CGRect]] {
            XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: size, occlusions: obstacles), bounds)
        }
        XCTAssertEqual(CameraGroupLayout.unobscuredContentRect(in: .zero, occlusions: []), .zero)
        XCTAssertTrue(CameraGroupLayout.unobscuredContentRect(in: size, occlusions: [bounds]).isEmpty)
    }

    func testOcclusionPlacementTranslatesSafeLabelBoundsAndFoldIntoNewCanvas() {
        let placement = CameraGroupLayout.CanvasPlacement(
            size: CGSize(width: 1_000, height: 800),
            safeBounds: CGRect(x: 10, y: 70, width: 940, height: 660),
            division: .init(frame: CGRect(x: 490, y: 0, width: 20, height: 800), margins: .init()),
            occlusions: [CGRect(x: 0, y: 350, width: 40, height: 100),
                         CGRect(x: 100, y: 0, width: 100, height: 50)]
        )
        XCTAssertEqual(placement.frame, CGRect(x: 40, y: 50, width: 960, height: 700))
        XCTAssertEqual(placement.safeBounds, CGRect(x: -30, y: 20, width: 940, height: 660))
        XCTAssertEqual(placement.division?.frame, CGRect(x: 450, y: -50, width: 20, height: 800))
        guard let division = placement.division else { return XCTFail("Lost the fold") }
        for cell in CameraGroupLayout.cells(count: 4, in: placement.frame.size, division: division) {
            let global = cell.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)
            XCTAssertTrue(placement.frame.contains(global))
            XCTAssertTrue(global.intersection(CGRect(x: 490, y: 0, width: 20, height: 800)).isEmpty)
        }
    }

    func testUnobscuredRectangleFindsGlobalMaximumRatherThanGreedilyTrimmingEachRegion() {
        let size = CGSize(width: 8, height: 8)
        for seed in 0..<20 {
            let obstacles = (0..<3).map { index in
                CGRect(x: (seed + index * 3) % 7, y: (seed * 3 + index * 2) % 7, width: 2, height: 2)
            }
            let balancesVertically = obstacles.contains { $0.maxY <= size.height / 4 }
            var largestArea = 0
            for x in 0..<8 {
                for y in 0..<8 {
                    for right in (x + 1)...8 {
                        for bottom in (y + 1)...8 {
                            let candidate = CGRect(x: x, y: y, width: right - x, height: bottom - y)
                            if (!balancesVertically || candidate.midY == size.height / 2),
                               obstacles.allSatisfy({ candidate.intersection($0).isEmpty }) {
                                largestArea = max(largestArea, (right - x) * (bottom - y))
                            }
                        }
                    }
                }
            }
            let actual = CameraGroupLayout.unobscuredContentRect(in: size, occlusions: obstacles)
            XCTAssertEqual(actual.width * actual.height, CGFloat(largestArea), "Obstacle set \(seed)")
            XCTAssertTrue(obstacles.allSatisfy { actual.intersection($0).isEmpty })
            if balancesVertically, !actual.isEmpty { XCTAssertEqual(actual.midY, size.height / 2) }
        }
    }

    func testColumnFitsAllPanesAsACenteredContiguousGroup() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 375, height: 667),
                     CGSize(width: 440, height: 956), CGSize(width: 852, height: 393)] {
            for count in 2...4 {
                let cells = CameraGroupLayout.cells(count: count, in: size, arrangement: .column)
                XCTAssertEqual(cells.count, count)
                for (index, cell) in cells.enumerated() {
                    XCTAssertEqual(cell.width / cell.height, 16 / 9, accuracy: 0.0001)
                    XCTAssertEqual(cell.midX, size.width / 2, accuracy: 0.0001)
                    XCTAssertGreaterThanOrEqual(cell.minY, -0.0001)
                    XCTAssertLessThanOrEqual(cell.maxY, size.height + 0.0001)
                    XCTAssertGreaterThanOrEqual(cell.minX, -0.0001)
                    XCTAssertLessThanOrEqual(cell.maxX, size.width + 0.0001)
                    if index > 0 { XCTAssertEqual(cell.minY, cells[index - 1].maxY, accuracy: 0.0001) }
                }
                XCTAssertEqual(cells[0].minY, size.height - cells[count - 1].maxY, accuracy: 0.0001)
                if size.width * 9 / 16 * CGFloat(count) > size.height {
                    XCTAssertGreaterThan(cells[0].minX, 0, "Height-limited columns leave side bars")
                    XCTAssertEqual(cells[0].minY, 0, accuracy: 0.0001)
                } else {
                    XCTAssertEqual(cells[0].width, size.width, accuracy: 0.0001)
                }
                // A 4:3 camera is still fitted, not stretched to the pane.
                let video = CameraGroupLayout.videoFrame(in: cells[0], aspectRatio: 4 / 3)
                XCTAssertEqual(video.width / video.height, 4 / 3, accuracy: 0.0001)
                XCTAssertTrue(cells[0].insetBy(dx: -0.001, dy: -0.001).contains(video))
            }
        }
        let size = CGSize(width: 393, height: 852)
        XCTAssertEqual(CameraGroupLayout.cells(count: 1, in: size, arrangement: .column),
            [CGRect(origin: .zero, size: size)], "Single-camera layout is unchanged")
        XCTAssertTrue(CameraGroupLayout.cells(count: 0, in: size, arrangement: .column).isEmpty)
        XCTAssertTrue(CameraGroupLayout.cells(count: 5, in: size, arrangement: .column).isEmpty)
        XCTAssertTrue(CameraGroupLayout.cells(count: 4, in: .zero, arrangement: .column).isEmpty)
    }

    func testColumnLabelsStayInsideTheirOwnPaneAndSafeArea() {
        let size = CGSize(width: 393, height: 852)
        let safe = CGRect(x: 0, y: 62, width: 393, height: 756)
        for count in 2...4 {
            XCTAssertFalse(CameraGroupLayout.labelsBelowVideo(count: count, arrangement: .column))
            for cell in CameraGroupLayout.cells(count: count, in: size, arrangement: .column) {
                let label = CameraGroupLayout.labelFrame(in: cell, safeBounds: safe, aspectRatio: 16 / 9,
                    labelSize: CGSize(width: 120, height: 24), belowVideo: false)
                XCTAssertTrue(cell.contains(label))
                XCTAssertTrue(safe.contains(label))
            }
        }
        XCTAssertTrue(CameraGroupLayout.labelsBelowVideo(count: 2, arrangement: .grid))
        XCTAssertFalse(CameraGroupLayout.labelsBelowVideo(count: 4, arrangement: .grid))
    }

    func testAllSessionsStartWithDefaultQualityAndSelectionPreservesSharedCursorAndPause() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: true))
        group.toggle(try camera("B")); group.toggle(try camera("C", history: false))
        XCTAssertEqual(group.sessions.map(\.quality), [.automatic, .automatic, .automatic])
        XCTAssertTrue(group.sessions.allSatisfy { $0.playback.externallyClocked })
        XCTAssertEqual(group.cursor, 500)
        XCTAssertTrue(group.isPaused)
        XCTAssertEqual(group.sessions[0].playback.history.position, 500)
        XCTAssertEqual(group.sessions[1].playback.history.position, 500)
        XCTAssertFalse(group.showsVideo(group.sessions[2]), "No NVR must not silently display live alongside history")
        let old = group.sessions[0]
        group.toggle(try camera("A"))
        XCTAssertEqual(group.cursor, 500)
        XCTAssertEqual(group.sessions.map(\.id), ["B", "C"])
        XCTAssertEqual(old.playback.timeline.retainedBytes, 0)
    }

    func testExplicitQualityChangeAppliesToExistingAndNewCamerasAndSurvivesToggles() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .live)
        group.toggle(try camera("B"))
        XCTAssertEqual(group.quality, .automatic)
        let first = group.sessions[0]
        group.setQuality(.medium)
        XCTAssertEqual(group.sessions.map(\.quality), [.medium, .medium])
        group.toggle(try camera("C"))
        XCTAssertEqual(group.sessions.map(\.quality), [.medium, .medium, .medium])
        group.setMultiple(false); group.setMultiple(true)
        XCTAssertTrue(group.sessions[0] === first)
        XCTAssertEqual(group.quality, .medium)
        group.toggle(try camera("B"))
        XCTAssertEqual(group.sessions.map(\.quality), [.medium, .medium])
        group.setQuality(.high)
        XCTAssertEqual(group.sessions.map(\.quality), [.high, .high])
    }

    func testUnsupportedNewCameraDoesNotSilentlyChangeSharedQuality() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .live)
        group.setQuality(.high)
        let low = CameraVideoDevice(device: try camera("Low-only").device,
            capability: CameraLiveVideoCapability(qualities: [.low]))
        group.toggle(low)
        XCTAssertEqual(group.sessions.count, 1)
        XCTAssertEqual(group.selection?.ids, ["A"])
        XCTAssertEqual(group.quality, .high)
        XCTAssertNotNil(group.error)
    }

    func testLabelsRespectOuterSafeAreaWithoutInsettingInteriorCellEdges() async {
        let size = CGSize(width: 852, height: 393)
        let safe = CGRect(x: 62, y: 50, width: 728, height: 322)
        for count in 1...4 {
            let cells = CameraGroupLayout.cells(count: count, in: size)
            for (index, cell) in cells.enumerated() {
                let anchor = CameraGroupLayout.labelAnchor(
                    index: index,
                    arrangement: .grid
                )
                let label = CameraGroupLayout.labelFrame(in: cell, safeBounds: safe, aspectRatio: 16 / 9,
                    labelSize: CGSize(width: 120, height: 24), belowVideo: count == 2,
                    anchor: anchor)
                let video = CameraGroupLayout.videoFrame(in: cell, aspectRatio: 16 / 9)
                XCTAssertTrue(safe.contains(label))
                XCTAssertTrue(cell.contains(label))
                if anchor == .leading {
                    XCTAssertEqual(label.minX, max(video.minX, safe.minX))
                } else {
                    XCTAssertEqual(label.maxX, min(video.maxX, safe.maxX))
                }
                if count == 2 { XCTAssertEqual(label.minY, video.maxY) }
                else { XCTAssertLessThanOrEqual(label.maxY, video.maxY) }
            }
            if count >= 2 {
                XCTAssertEqual(CameraGroupLayout.labelArea(in: cells[1], safeBounds: safe, aspectRatio: 16 / 9).minX,
                    CameraGroupLayout.videoFrame(in: cells[1], aspectRatio: 16 / 9).minX)
            }
        }
    }

    func testTwoUpLabelsFallBackInsideWhenThereIsNoLetterboxSpace() async {
        let cell = CGRect(x: 0, y: 0, width: 320, height: 180)
        let safe = CGRect(x: 20, y: 0, width: 300, height: 160)
        let label = CameraGroupLayout.labelFrame(in: cell, safeBounds: safe, aspectRatio: 16 / 9,
            labelSize: CGSize(width: 140, height: 24), belowVideo: true)
        XCTAssertTrue(safe.contains(label))
        XCTAssertEqual(label.maxY, safe.maxY)
    }

    func testOneClockWaitsForEveryReaderAndGapJumpMovesEveryone() async throws {
        var now = 100.0
        let group = try makeGroup(clock: { now })
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: false))
        group.toggle(try camera("B"))
        group.sessions[0].playback.history.configure(cameraID: "A", transport: GroupHistoryFetcher())
        try await settled(group.sessions[0].playback.history)
        now += 1; group.tick()
        XCTAssertEqual(group.cursor, 500, "A reader that is not ready holds the shared clock")
        group.sessions[1].playback.history.configure(cameraID: "B", transport: GroupHistoryFetcher())
        try await settled(group.sessions[1].playback.history)
        now += 1; group.tick()
        XCTAssertEqual(group.cursor, 501, "Confirmed gaps can advance without waiting forever")
        XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [501, 501])
        group.togglePause()
        try await settled(group.sessions[1].playback.history)
        now += 10; group.tick()
        XCTAssertEqual(group.cursor, 501)
        group.jump(from: group.sessions[1], previous: false)
        XCTAssertEqual(group.cursor, 800)
        XCTAssertTrue(group.isPaused)
        XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [800, 800])
        group.seek(by: 500)
        XCTAssertFalse(group.isLive, "A paused forward jump never starts live playback")
        XCTAssertTrue(group.isPaused)
        group.togglePause(); group.seek(by: 500)
        XCTAssertTrue(group.isLive)
        XCTAssertFalse(group.isPaused)
    }

    func testStoppedCameraDoesNotClampSharedCanonicalCursorToItsOlderAnchor() async throws {
        let playback = CameraLivePlaybackController()
        defer { playback.close() }
        playback.useGroupClock()
        playback.history.configure(cameraID: "old", transport: GroupHistoryFetcher(anchor: 100))
        playback.followGroupHistory(time: 500, liveEdge: nil, paused: true, seeking: true)
        try await settled(playback.history)
        XCTAssertEqual(playback.history.position, 500)
        XCTAssertEqual(playback.history.state, .gap)
        playback.followGroupHistory(time: 510, liveEdge: 1000, paused: true, seeking: true)
        XCTAssertEqual(playback.history.position, 510)
    }

    func testFresherCameraExtendsLiveBoundaryEvenWhenOlderCameraConnectsFirst() async throws {
        let group = try makeGroup(clock: { 100 })
        defer { group.deactivate() }
        group.activate(camera: try camera("Older"), position: .canonical(50, paused: true))
        group.toggle(try camera("Current"))
        group.sessions[0].playback.history.configure(cameraID: "old", transport: GroupHistoryFetcher(anchor: 100))
        try await settled(group.sessions[0].playback.history)
        group.tick()
        XCTAssertEqual(group.liveEdge, 100)
        group.sessions[1].playback.history.configure(cameraID: "fresh", transport: GroupHistoryFetcher(anchor: 1000))
        try await settled(group.sessions[1].playback.history)
        group.tick()
        XCTAssertEqual(group.liveEdge, 1000)
        XCTAssertEqual(group.cursor, 50)
        XCTAssertTrue(group.isPaused)
    }

    func testCommonControlsDisplayFirstStateWithoutWritingAndTranslateExplicitChanges() async throws {
        let client = try makeClient()
        let a = LiveDeviceControlsModel(device: nil, client: client)
        let b = LiveDeviceControlsModel(device: nil, client: client)
        var aWrites: [HBJSONValue] = [], bWrites: [HBJSONValue] = []
        a.installWriteRouting(value: { value, _, _ in aWrites.append(value) }, canonical: { _, _ in })
        b.installWriteRouting(value: { value, _, _ in bWrites.append(value) }, canonical: { _, _ in })
        a.installAggregatePresentation([control("A", "Privacy", value: .bool(false)), dayNight("A", values: [.integer(0), .integer(1)], current: .integer(0))])
        b.installAggregatePresentation([control("B", "Privacy", value: .integer(1)), dayNight("B", values: [.string("DAY"), .string("NIGHT")], current: .string("NIGHT"))])
        let snapshot = CameraGroupControlSnapshot(models: [a, b])
        XCTAssertTrue(aWrites.isEmpty && bWrites.isEmpty)
        let privacy = try XCTUnwrap(CameraDetailControlSet(controls: snapshot.controls).privacy)
        XCTAssertEqual(privacy.value, .bool(false))
        try await CameraGroupControlSnapshot.perform(snapshot.writes(value: .bool(true), control: privacy))
        XCTAssertEqual(aWrites, [.bool(true)])
        XCTAssertEqual(bWrites, [.integer(1)])
        let day = try XCTUnwrap(CameraDayNightModeTarget(controls: snapshot.controls))
        XCTAssertEqual(day.selectedMode, .day)
        try await CameraGroupControlSnapshot.perform(snapshot.writes(value: .integer(0), control: day.control))
        XCTAssertEqual(aWrites.last, .integer(0), "Selecting the displayed mode again still aligns every camera")
        XCTAssertEqual(bWrites.last, .string("DAY"))
        b.installAggregatePresentation([])
        XCTAssertTrue(CameraGroupControlSnapshot(models: [a, b]).controls.isEmpty)
    }

    func testCommonControlsHideInvalidPeersAndUpdatingStateClears() async throws {
        let client = try makeClient()
        let a = LiveDeviceControlsModel(device: nil, client: client)
        let b = LiveDeviceControlsModel(device: nil, client: client)
        let aggregate = LiveDeviceControlsModel(device: nil, client: client)
        var item = control("A", "Privacy", value: .bool(false))
        a.installAggregatePresentation([item]); b.installAggregatePresentation([item])
        item.isUpdating = true; a.installAggregatePresentation([item])
        aggregate.installAggregatePresentation(CameraGroupControlSnapshot(models: [a, b]).controls)
        XCTAssertTrue(aggregate.controls[0].isUpdating)
        item.isUpdating = false; a.installAggregatePresentation([item])
        aggregate.installAggregatePresentation(CameraGroupControlSnapshot(models: [a, b]).controls)
        XCTAssertFalse(aggregate.controls[0].isUpdating)
        item.valid = false; b.installAggregatePresentation([item])
        XCTAssertTrue(CameraGroupControlSnapshot(models: [a, b]).controls.isEmpty)
    }

    func testPartialControlFailureStillAttemptsEveryCameraAndReportsError() async throws {
        let client = try makeClient()
        let a = LiveDeviceControlsModel(device: nil, client: client)
        let b = LiveDeviceControlsModel(device: nil, client: client)
        var attempted: Set<String> = []
        a.installWriteRouting(value: { _, _, _ in attempted.insert("A"); throw CameraHistoryError.unavailable }, canonical: { _, _ in })
        b.installWriteRouting(value: { _, _, _ in attempted.insert("B") }, canonical: { _, _ in })
        a.installAggregatePresentation([control("A", "Privacy", value: .bool(false))])
        b.installAggregatePresentation([control("B", "Privacy", value: .bool(false))])
        let snapshot = CameraGroupControlSnapshot(models: [a, b])
        do {
            try await CameraGroupControlSnapshot.perform(snapshot.writes(value: .bool(true), control: snapshot.controls[0]))
            XCTFail("Partial failure must not be silently successful")
        } catch { XCTAssertTrue(error.localizedDescription.contains("A")) }
        XCTAssertEqual(attempted, ["A", "B"])
        XCTAssertFalse(a.controls[0].isUpdating || b.controls[0].isUpdating)
    }

    func testSharedToolbarDoesNotExposePanTiltOrZoomEvenWhenAllCamerasSupportThem() async throws {
        let client = try makeClient()
        let a = LiveDeviceControlsModel(device: nil, client: client)
        let b = LiveDeviceControlsModel(device: nil, client: client)
        var payloads: [String: HBJSONValue] = [:]
        for (name, model, zoom, range) in [("A", a, 0.2, 1.0), ("B", b, 0.8, 0.5)] {
            model.installWriteRouting(value: { _, _, _ in }, canonical: { value, _ in payloads[name] = value })
            model.installAggregatePresentation(zip(["PanTilt[0]", "PanTilt[1]", "Zoom[0]"], [0.0, 0.0, zoom]).map { axis, value in
                control(name, axis, value: .number(value), metadata: ["canonicalControl": .string("PTZ.Position"),
                    "canonicalComponent": .string(axis), "minimum": .number(-range), "maximum": .number(range)])
            })
        }
        let snapshot = CameraGroupControlSnapshot(models: [a, b])
        XCTAssertNil(CameraPanTiltGestureTarget(controls: snapshot.controls))
        XCTAssertNil(CameraZoomGestureTarget(controls: snapshot.controls))
        XCTAssertTrue(snapshot.controls.isEmpty)
        XCTAssertTrue(payloads.isEmpty, "Entry must not recenter or align settings")
    }

    func testPaneGesturesOnlyWriteTouchedCameraAndKeepIndependentRecenterPositions() async throws {
        let client = try makeClient()
        var writes: [(String, HBJSONValue)] = []
        let models = (0..<4).map { _ in LiveDeviceControlsModel(device: nil, client: client) }
        func axes(_ name: String, pan: Double, zoom: Double) -> [LiveDeviceControl] {
            zip(["PanTilt[0]", "PanTilt[1]", "Zoom[0]"], [pan, 0, zoom]).map { axis, value in
                control(name, axis, value: .number(value), metadata: ["canonicalControl": .string("PTZ.Position"),
                    "canonicalComponent": .string(axis), "minimum": .number(axis == "Zoom[0]" ? 0 : -1), "maximum": .number(1)])
            }
        }
        for (index, model) in models.enumerated() {
            let name = "Camera \(index)"
            model.installWriteRouting(value: { value, _, _ in writes.append((name, value)) },
                canonical: { value, _ in writes.append((name, value)) })
            model.installAggregatePresentation(index < 3 ? axes(name, pan: Double(index) / 10, zoom: 0.2) : [])
        }
        let panes = models.map(CameraPaneGestures.init(model:))
        defer { panes.forEach { $0.update(enabled: false) } }
        panes.forEach { $0.update(enabled: true) }
        XCTAssertTrue(writes.isEmpty, "Entering Multiple must not align or recenter cameras")
        XCTAssertNotNil(panes[0].panTiltTarget, "Another camera's missing PTZ must not disable this pane")
        XCTAssertNil(panes[3].panTiltTarget)
        let viewport = CGSize(width: 400, height: 200)
        panes[0].pan(.began, translation: .zero, viewport: viewport)
        panes[0].pan(.ended, translation: CGSize(width: 40, height: 0), viewport: viewport)
        try await waitForWrites(1, count: { writes.count })
        XCTAssertEqual(writes.map(\.0), ["Camera 0"])
        XCTAssertEqual(writes[0].1.objectValue?["Zoom"], .array([.number(0.2)]))

        panes[1].magnify(.began, scale: 1)
        panes[1].magnify(.ended, scale: 2)
        try await waitForWrites(2, count: { writes.count })
        XCTAssertEqual(writes.map(\.0), ["Camera 0", "Camera 1"])

        models[1].installAggregatePresentation(axes("Camera 1", pan: 0.8, zoom: 0.6))
        panes[1].update(enabled: true)
        panes[1].recenter()
        try await waitForWrites(3, count: { writes.count })
        XCTAssertEqual(writes.last?.0, "Camera 1")
        XCTAssertEqual(writes.last?.1.objectValue?["PanTilt"], .array([.number(0.1), .number(0)]))
        XCTAssertEqual(writes.last?.1.objectValue?["Zoom"], .array([.number(0.6)]))

        panes[0].recenter()
        try await waitForWrites(4, count: { writes.count })
        XCTAssertEqual(writes.last?.0, "Camera 0")
        XCTAssertEqual(writes.last?.1.objectValue?["PanTilt"], .array([.number(0), .number(0)]))
        XCTAssertFalse(writes.contains { $0.0 == "Camera 2" || $0.0 == "Camera 3" })

        // A pane leaving Live/removing itself cancels pending gesture work and
        // cannot dispatch late callbacks. It does not cancel a different pane.
        panes[0].pan(.began, translation: .zero, viewport: viewport)
        panes[0].pan(.changed, translation: CGSize(width: 20, height: 0), viewport: viewport)
        panes[0].update(enabled: false)
        panes[0].pan(.ended, translation: CGSize(width: 20, height: 0), viewport: viewport)
        panes[0].recenter(); panes[0].magnify(.began, scale: 1); panes[0].magnify(.ended, scale: 2)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes.count, 4)
        XCTAssertNotNil(panes[1].panTiltTarget)
    }

    private func waitForWrites(_ expected: Int, count: () -> Int) async throws {
        for _ in 0..<100 {
            if count() >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Gesture write did not arrive")
        throw CameraHistoryError.unavailable
    }

    private func makeClient() throws -> HomeBaseWebSocketClient {
        HomeBaseWebSocketClient(endpoint: try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1")))
    }
    private func makeGroup(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws -> CameraGroupPlayback {
        CameraGroupPlayback(client: try makeClient(), clock: clock)
    }
    private func camera(_ name: String, history: Bool = true) throws -> CameraVideoDevice {
        var metadata: [String: HBJSONValue] = [CameraLiveVideoCapability.availableMetadataKey: .bool(true),
            CameraLiveVideoCapability.qualitiesMetadataKey: .array([.string("medium"), .string("high")]),
            CameraLiveVideoCapability.streamPolicyMetadataKey: .object(["version": .integer(1)])]
        if history { metadata[HBDeviceMetadataKeys.cameraPlayback] = try HBJSONValue(encoding:
            HBCameraPlaybackMetadata(nvrInstanceID: "nvr", cameraID: UUID().uuidString, stores: [.init(id: "local", name: "Local")])) }
        return try XCTUnwrap(CameraVideoCatalog.cameras(in: [.init(identifier: name, addressableName: name, displayName: name, metadata: metadata)]).first)
    }
    private func control(_ device: String, _ id: String, value: HBJSONValue, metadata: [String: HBJSONValue] = [:]) -> LiveDeviceControl {
        var metadata = metadata.merging(["readable": .bool(true), "writable": .bool(true), "structured": .bool(false), "valid": .bool(true)]) { a, _ in a }
        if id == "Privacy" { metadata["cameraPrivacy"] = .bool(true) }
        return LiveDeviceControl(descriptor: .init(control: "\(device):\(id)", deviceIdentifier: device, controlIdentifier: id, displayName: id, kind: id, metadata: metadata),
            details: .init(identifier: id, name: id, kind: id, value: value, metadata: metadata), value: value, valid: true)
    }
    private func dayNight(_ device: String, values: [HBJSONValue], current: HBJSONValue) -> LiveDeviceControl {
        control(device, "Tapo.Image.DayNightMode", value: current, metadata: ["choices": .array(zip(["day", "night"], values).map { .object(["label": .string($0.0), "value": $0.1]) })])
    }
    private func settled(_ history: CameraHistoryPlayback) async throws {
        for _ in 0..<200 {
            if !history.fetching, history.state == .gap, case .ready = history.navigation { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("History did not settle: \(history.state)")
    }
}

@MainActor
private final class CameraSessionResourceSpy {
    var events: [String] = []
    var startCount: [String: Int] = [:]

    func start(_ resource: String) async {
        let count = (startCount[resource] ?? 0) + 1
        startCount[resource] = count
        events.append("\(resource).start.\(count)")
        guard count == 1 else { return }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {}
        events.append("\(resource).end.\(count)")
    }

    func stop(_ resource: String) {
        events.append("\(resource).stop")
    }

    func stop(_ resource: String, immediately: Bool) {
        events.append("\(resource).stop\(immediately ? ".immediately" : "")")
    }
}

private actor GroupHistoryFetcher: CameraHistoryFetching {
    let anchor: Double
    init(anchor: Double = 1000) { self.anchor = anchor }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        let relative = request.relativeTo == nil ? 0 : anchor
        let range = CameraHistoryRange(start: request.range.start + relative, end: request.range.end + relative)
        let neighbors = CameraHistoryNeighbors(
            previous: range.start >= 160 ? .init(start: 100, end: 160) : nil,
            next: range.end <= 800 ? .init(start: 800, end: 860) : nil)
        return CameraHistoryBatch(id: UUID(), range: range, anchor: request.relativeTo == nil ? nil : anchor,
            pieces: [], gaps: request.operation == "neighbors" ? [] : [range],
            neighbors: request.operation == "neighbors" ? neighbors : nil)
    }
}
