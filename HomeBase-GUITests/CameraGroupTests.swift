import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraGroupTests: XCTestCase {
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

    func testColumnSelectionDependsOnBothSizeClassesNotOrientation() {
        let classes: [UserInterfaceSizeClass?] = [nil, .compact, .regular]
        for horizontal in classes {
            for vertical in classes {
                XCTAssertEqual(CameraGroupLayout.arrangement(horizontal: horizontal, vertical: vertical),
                    horizontal == .compact && vertical != .compact ? .column : .grid)
            }
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

    func testAllSessionsStartHighAndSelectionPreservesSharedCursorAndPause() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        group.activate(camera: try camera("A"), position: .canonical(500, paused: true))
        group.toggle(try camera("B")); group.toggle(try camera("C", history: false))
        XCTAssertEqual(group.sessions.map(\.quality), [.high, .high, .high])
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
        XCTAssertEqual(group.quality, .high)
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
            for cell in cells {
                let label = CameraGroupLayout.labelFrame(in: cell, safeBounds: safe, aspectRatio: 16 / 9,
                    labelSize: CGSize(width: 120, height: 24), belowVideo: count == 2)
                let video = CameraGroupLayout.videoFrame(in: cell, aspectRatio: 16 / 9)
                XCTAssertTrue(safe.contains(label))
                XCTAssertTrue(cell.contains(label))
                XCTAssertEqual(label.minX, max(video.minX, safe.minX))
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
            CameraLiveVideoCapability.qualitiesMetadataKey: .array([.string("medium"), .string("high")])]
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
