import AVFoundation
import Combine
import HomeBaseProtocol
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import HomeBase_GUI

/// Explicit opt-in: consumes live camera video but never changes camera controls,
/// recording intent, pairing, or server configuration, and never saves footage.
@MainActor
final class CameraLivePlaybackSmokeTests: XCTestCase {
    func testStreamArbiterQualityHandoffKeepsPlayingThroughRealServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_LIVE_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit live camera smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        guard let camera = CameraVideoCatalog.cameras(in: try await client.listTopology().devices)
            .first(where: { $0.capability.qualities.contains(.low) && $0.capability.qualities.contains(.high) }) else {
            await client.disconnect(); throw XCTSkip("A camera with low and high streams is required")
        }
        let playback = CameraLivePlaybackController()
        let model = CameraLiveVideoModel(deviceIdentifier: camera.device.addressableName, quality: .low,
                                        client: client, playbackController: playback)
        let stream = Task { await model.run() }
        let preview = CameraLiveVideoModel(deviceIdentifier: camera.device.addressableName, quality: .low, client: client)
        var previewTask: Task<Void, Never>?
        var observer: AnyCancellable?
        var interruptions: [CameraLiveVideoModel.State] = []
        do {
            try await eventually("Low-quality live stream becomes playable") {
                model.state == .playing && playback.timeline.entries.count > 10
            }
            observer = model.$state.sink { if $0 != .playing { interruptions.append($0) } }
            for quality in [CameraLiveQualitySelection.high, .low] {
                let epoch = playback.timeline.sourceEpoch
                let bytes = playback.timeline.retainedBytes
                await model.setQuality(quality)
                try await eventually("Replacement quality reaches a keyframe") {
                    playback.timeline.sourceEpoch > epoch && model.state == .playing && model.qualityWarning == nil
                }
                XCTAssertGreaterThan(playback.timeline.retainedBytes, bytes)
                XCTAssertEqual(interruptions, [], "Quality switches must not show connecting/loading/black states")
                XCTAssertNil(playback.errorMessage)
            }
            // Closing full screen then returning to a preview uses the warm
            // subscription, not a second independently owned camera stream.
            observer?.cancel(); observer = nil
            stream.cancel(); await model.stop(); await stream.value
            previewTask = Task { await preview.run() }
            try await eventually("Preview joins the warm feed") { preview.state == .playing }
            XCTAssertNotEqual(preview.renderer.layer.sampleBufferRenderer.status, .failed)
            print("Stream arbiter smoke passed: low → high → low without playback interruption; warm preview handoff")
        } catch {
            print("Arbiter smoke diagnostics: state=\(model.state), warning=\(model.qualityWarning ?? "none"), frames=\(playback.timeline.entries.count), epoch=\(playback.timeline.sourceEpoch)")
            observer?.cancel(); stream.cancel(); previewTask?.cancel()
            await model.stop(); await preview.stop(); await stream.value; await previewTask?.value
            playback.close(); await client.disconnect(); throw error
        }
        observer?.cancel(); stream.cancel(); previewTask?.cancel()
        await model.stop(); await preview.stop(); await stream.value; await previewTask?.value
        playback.close(); await client.disconnect()
    }

    func testRealCameraFastPlaybackCatchesUpAtOneTimesWithoutGoingLive() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_LIVE_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit live camera smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        guard let camera = CameraVideoCatalog.cameras(in: try await client.listTopology().devices).first else {
            await client.disconnect(); throw XCTSkip("A live camera is required")
        }
        let playback = CameraLivePlaybackController()
        let model = CameraLiveVideoModel(deviceIdentifier: camera.device.addressableName,
            quality: .automatic, client: client, playbackController: playback)
        let stream = Task { await model.run() }
        do {
            try await eventually("Live footage collected for speed smoke") { (playback.timeline.head ?? 0) >= 6 }
            playback.seek(by: -5)
            playback.setPlaybackSpeed(.quadruple)
            let position = try XCTUnwrap(playback.timeline.position)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertGreaterThan(try XCTUnwrap(playback.timeline.position) - position, 0.6)
            XCTAssertEqual(playback.playbackSpeed, .quadruple)
            try await eventually("4× catches the growing live buffer and becomes 1×") { playback.playbackSpeed == .normal }
            XCTAssertFalse(playback.isLive)
            XCTAssertFalse(playback.isPaused)
            let caughtUp = try XCTUnwrap(playback.timeline.position)
            try await eventually("Buffered 1× continues receiving and playing new video") {
                (playback.timeline.position ?? 0) > caughtUp + 0.5 && playback.renderer.layer.isReadyForDisplay
            }
            XCTAssertNil(playback.errorMessage)
            XCTAssertNotEqual(playback.renderer.layer.sampleBufferRenderer.status, .failed)
            print("Playback speed smoke passed: \(camera.device.displayName), 4× to 1× without leaving buffered playback")
        } catch {
            stream.cancel(); await model.stop(); await stream.value; playback.close()
            await client.disconnect(); throw error
        }
        stream.cancel(); await model.stop(); await stream.value; playback.close()
        await client.disconnect()
    }

#if os(macOS)
    func testMountedPreviewsReleaseStreamsWhileFullScreenPlayerStaysLive() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_LIVE_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit camera smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        let cameras = Array(CameraVideoCatalog.cameras(in: try await client.listTopology().devices).prefix(2))
        guard let fullScreenCamera = cameras.first else {
            await client.disconnect()
            throw XCTSkip("At least one live camera required")
        }
        let playback = CameraLivePlaybackController()
        var states: [String: CameraLiveVideoModel.State] = [:]
        func previewsConnected() -> Bool {
            cameras.allSatisfy {
                // A server status also proves the media socket is connected.
                // Camera transport startup/recovery need not produce video yet.
                switch states[$0.id] {
                case .waiting, .playing: true
                default: false
                }
            }
        }
        func content(previewsEnabled: Bool, phase: ScenePhase = .active) -> some View {
            VStack {
                ForEach(cameras) { camera in
                    CameraLiveVideoPlayer(deviceIdentifier: camera.device.addressableName,
                        quality: CameraLiveQualitySelection(camera.capability.previewQuality), client: client, allowsRetry: false,
                        isStreamEnabled: previewsEnabled,
                        onStateChanged: {
                            states[camera.id] = $0
                            print("Preview visibility smoke: \(camera.device.displayName): \($0)")
                        })
                }
                // Independent subscription: suspending previews must not suspend this player.
                CameraLiveVideoPlayer(deviceIdentifier: fullScreenCamera.device.addressableName,
                    quality: .automatic, client: client,
                    allowsRetry: false, playbackController: playback,
                    onStateChanged: { print("Preview visibility smoke: independent player: \($0)") })
            }
            .environment(\.scenePhase, phase)
        }
        let host = NSHostingView(rootView: content(previewsEnabled: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 852, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        do {
            try await eventually("Preview streams connect and the independent player receives video") {
                previewsConnected() && playback.timeline.entries.count > 10
            }
            let epoch = playback.timeline.sourceEpoch
            for _ in 0..<2 {
                host.rootView = content(previewsEnabled: false)
                try await eventually("Covered previews stop") { cameras.allSatisfy { states[$0.id] == .idle } }
                let head = playback.timeline.head ?? 0
                try await eventually("Full-screen stream continues while previews are covered") {
                    (playback.timeline.head ?? 0) > head + 0.5
                }
                XCTAssertTrue(cameras.allSatisfy { states[$0.id] == .idle })
                XCTAssertEqual(playback.timeline.sourceEpoch, epoch)
                host.rootView = content(previewsEnabled: true)
                try await eventually("Dismissal reconnects previews") { previewsConnected() }
                XCTAssertEqual(playback.timeline.sourceEpoch, epoch)
            }
            host.rootView = content(previewsEnabled: false, phase: .background)
            try await eventually("Backgrounded previews stop") { cameras.allSatisfy { states[$0.id] == .idle } }
            host.rootView = content(previewsEnabled: true, phase: .background)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(cameras.allSatisfy { states[$0.id] == .idle }, "Dismissal in the background must not reconnect previews")
            host.rootView = content(previewsEnabled: true)
            try await eventually("Foreground restores previews") { previewsConnected() }
            // Exercise dismissal/reopening while requests are still in flight.
            for enabled in [false, true, false, true, false] {
                host.rootView = content(previewsEnabled: enabled)
                try await Task.sleep(for: .milliseconds(50))
            }
            try await eventually("Rapid cover changes leave every preview stopped") { cameras.allSatisfy { states[$0.id] == .idle } }
            host.rootView = content(previewsEnabled: true)
            try await eventually("Rapid cover changes still allow previews to resume") { previewsConnected() }
            print("Preview visibility smoke passed: all covered previews stop; full-screen lease remains live; dismissal and foreground reconnect")
        } catch {
            window.orderOut(nil); window.contentView = nil; playback.close()
            await client.disconnect(); throw error
        }
        window.orderOut(nil); window.contentView = nil; playback.close()
        await client.disconnect()
    }

    func testMountedPlaybackBackgroundsAndReconnectsWithoutResumingHistory() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit camera smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        let cameras = CameraVideoCatalog.cameras(in: try await client.listTopology().devices).filter {
            CameraPlaybackHistoryAvailability.isAvailable(in: $0.device.metadata)
        }
        guard cameras.count >= 2 else { await client.disconnect(); throw XCTSkip("Two NVR cameras required") }
        let first = CameraGroupSession(camera: cameras[0], client: client)
        let group = CameraGroupPlayback(client: client, initialSession: first)
        let host = NSHostingView(rootView: CameraGroupVideo(group: group,
            cameraControlsEnabled: false, controlsVisible: true, onSingleTap: {}).environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 852, height: 393),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        func background() async throws {
            group.suspend()
            host.rootView = CameraGroupVideo(group: group, cameraControlsEnabled: false,
                controlsVisible: true, onSingleTap: {}).environment(\.scenePhase, .background)
            try await eventually("Background unloads mounted streams") { group.sessions.allSatisfy { $0.liveState == .idle } }
        }
        func foreground() async throws {
            let epochs = group.sessions.map { $0.playback.timeline.sourceEpoch }
            group.resume()
            host.rootView = CameraGroupVideo(group: group, cameraControlsEnabled: false,
                controlsVisible: true, onSingleTap: {}).environment(\.scenePhase, .active)
            try await eventually("Foreground reconnects mounted streams") {
                zip(group.sessions, epochs).allSatisfy { $0.0.liveState.displaysVideo && $0.0.playback.timeline.sourceEpoch > $0.1 }
            }
        }
        do {
            try await eventually("Initial live buffer ready") { first.liveState.displaysVideo && (first.playback.timeline.head ?? 0) > 2 }
            try await background()
            XCTAssertTrue(first.playback.isLive)
            try await foreground()
            XCTAssertTrue(first.playback.isLive)
            first.playback.seek(by: -1)
            XCTAssertFalse(first.playback.isPaused)
            let singleCursor = first.playback.timeline.position
            try await background(); try await foreground()
            XCTAssertTrue(first.playback.isPaused)
            XCTAssertEqual(first.playback.timeline.position, singleCursor)

            first.playback.goLive(); group.setMultiple(true); group.toggle(cameras[1])
            try await eventually("Both cameras have overlapping live buffers") {
                let heads = group.sessions.compactMap(\.hostHead), tails = group.sessions.compactMap(\.hostTail)
                return heads.count == 2 && tails.count == 2 && heads.min()! > tails.max()! + 2
            }
            group.seek(by: -1)
            XCTAssertEqual(group.source, .buffer)
            let sharedCursor = group.cursor
            try await background(); try await foreground()
            XCTAssertTrue(group.isPaused)
            XCTAssertEqual(group.cursor, sharedCursor)
            XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isPaused })

            group.seek(to: Date().addingTimeInterval(-90)); group.togglePause()
            try await eventually("Group history ready before background") {
                group.sessions.allSatisfy { $0.playback.historyState == .ready && !$0.playback.history.fetching }
            }
            XCTAssertFalse(group.isPaused)
            let historyCursor = group.cursor
            try await background(); try await foreground()
            try await eventually("History restored while paused") { group.sessions.allSatisfy { $0.playback.historyState == .ready } }
            XCTAssertTrue(group.isPaused)
            XCTAssertEqual(group.cursor, historyCursor)
            XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isPaused })
            print("Background smoke passed: Live reconnects Live; single/multiple buffer and NVR history reconnect paused at the same cursor")
        } catch {
            window.orderOut(nil); window.contentView = nil; group.deactivate()
            await client.disconnect(); throw error
        }
        window.orderOut(nil); window.contentView = nil; group.deactivate()
        await client.disconnect()
    }

    func testMountedCameraPaneKeepsLiveLeaseAcrossMultipleLayoutChanges() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit camera smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        let cameras = CameraVideoCatalog.cameras(in: try await client.listTopology().devices)
        guard cameras.count >= 2 else { await client.disconnect(); throw XCTSkip("Two cameras required") }
        let original = CameraGroupSession(camera: cameras[0], client: client, quality: .medium)
        let group = CameraGroupPlayback(client: client, initialSession: original)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 852, height: 393),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: CameraGroupVideo(group: group,
            cameraControlsEnabled: false, controlsVisible: true, onSingleTap: {}).environment(\.scenePhase, .active))
        window.orderFront(nil)
        do {
            try await eventually("Mounted original camera has video") { original.liveState.displaysVideo && original.playback.timeline.entries.count > 10 }
            let epoch = original.playback.timeline.sourceEpoch
            let renderer = original.playback.renderer
            for enabled in [true, false, true, false] {
                let head = original.playback.timeline.head ?? 0
                group.setMultiple(enabled)
                try await eventually("Original camera keeps receiving across toggle") { (original.playback.timeline.head ?? 0) > head + 0.5 }
                XCTAssertTrue(group.sessions[0] === original)
                XCTAssertTrue(original.playback.renderer === renderer)
                XCTAssertEqual(original.playback.timeline.sourceEpoch, epoch, "A remounted player would configure another lease/epoch")
            }
            original.playback.togglePause()
            let frozen = original.playback.timeline.position
            let entries = original.playback.timeline.entries.count
            group.setMultiple(true)
            try await Task.sleep(for: .milliseconds(100))
            group.setMultiple(false)
            XCTAssertTrue(original.playback.isPaused)
            XCTAssertEqual(try XCTUnwrap(original.playback.timeline.position), try XCTUnwrap(frozen), accuracy: 0.000_001)
            XCTAssertGreaterThanOrEqual(original.playback.timeline.entries.count, entries)
            XCTAssertEqual(original.playback.timeline.sourceEpoch, epoch)
            original.playback.goLive()
            group.setMultiple(true); group.toggle(cameras[1])
            let second = group.sessions[1]
            try await eventually("Second camera ready in two-up") { second.liveState.displaysVideo && second.playback.timeline.entries.count > 10 }
            XCTAssertEqual(original.playback.timeline.sourceEpoch, epoch)
            let previousSecondEpoch = second.playback.timeline.sourceEpoch
            group.setQuality(.high)
            try await eventually("Explicit quality change replaces both profiles") {
                original.playback.timeline.sourceEpoch > epoch && second.playback.timeline.sourceEpoch > previousSecondEpoch
                    && original.liveState.displaysVideo && second.liveState.displaysVideo
            }
            XCTAssertEqual(group.sessions.map(\.quality), [.high, .high])
            XCTAssertGreaterThanOrEqual(original.playback.timeline.entries.count, entries, "A quality change retains the accumulated live buffer")
            let secondEpoch = second.playback.timeline.sourceEpoch
            group.toggle(cameras[0])
            group.setMultiple(false)
            let head = second.playback.timeline.head ?? 0
            try await eventually("Surviving camera keeps its lease while expanding") { (second.playback.timeline.head ?? 0) > head + 1 }
            XCTAssertTrue(group.sessions[0] === second)
            XCTAssertEqual(second.playback.timeline.sourceEpoch, secondEpoch)
            print("Mounted layout smoke passed: toggles and surviving panes retain live epochs; explicit quality change updates both cameras without dropping their buffers")
        } catch {
            window.orderOut(nil); window.contentView = nil; group.deactivate()
            await client.disconnect(); throw error
        }
        window.orderOut(nil); window.contentView = nil; group.deactivate()
        await client.disconnect()
    }
#endif

    func testMultipleCamerasLiveBufferedAndHistoryThroughRealServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit history smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        let group = CameraGroupPlayback(client: client)
        var streams: [(CameraLiveVideoModel, Task<Void, Never>)] = []
        do {
            try await client.connect()
            let cameras = CameraVideoCatalog.cameras(in: try await client.listTopology().devices).filter {
                CameraPlaybackHistoryAvailability.isAvailable(in: $0.device.metadata)
            }
            guard cameras.count >= 2 else { throw XCTSkip("Two NVR cameras required") }
            group.activate(camera: cameras[0], position: .live)
            group.toggle(cameras[1])
            for session in group.sessions {
                session.playback.prepareHistory(metadata: session.controls.deviceMetadata, client: client)
                let model = CameraLiveVideoModel(deviceIdentifier: session.camera.device.addressableName,
                    quality: session.quality, client: client, playbackController: session.playback)
                streams.append((model, Task { await model.run() }))
            }
            try await eventually("Both selected-quality streams ready") { streams.allSatisfy { $0.0.state.displaysVideo } }
            for (index, stream) in streams.enumerated() { group.sessions[index].liveState = stream.0.state }
            group.tick()
            try await eventually("Both buffers cover a common instant") {
                let heads = group.sessions.compactMap(\.hostHead), tails = group.sessions.compactMap(\.hostTail)
                guard heads.count == 2, tails.count == 2 else { return false }
                return heads.min()! > tails.max()! + 1
            }
            XCTAssertTrue(group.sessions.allSatisfy { $0.quality == .automatic })
            group.togglePause()
            let paused = try XCTUnwrap(group.cursor)
            try await eventually("Both live buffers continue while group is paused") {
                group.sessions.allSatisfy { ($0.hostHead ?? 0) > paused + 3 }
            }
            XCTAssertEqual(group.cursor, paused)
            group.seek(by: 30)
            XCTAssertTrue(group.isPaused)
            XCTAssertFalse(group.isLive)
            group.seek(to: Date().addingTimeInterval(-90))
            try await eventually("Both history panes ready") {
                group.sessions.allSatisfy { $0.playback.historyState == .ready && !$0.playback.history.fetching }
            }
            try await eventually("Both history panes render") { group.sessions.allSatisfy { $0.playback.renderer.layer.isReadyForDisplay } }
            let frozen = try XCTUnwrap(group.cursor)
            XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [frozen, frozen])
            group.togglePause()
            try await eventually("Shared history clock advances") { (group.cursor ?? 0) > frozen + 2 }
            XCTAssertEqual(group.sessions[0].playback.history.position, group.sessions[1].playback.history.position)
            group.togglePause()
            group.seek(to: Date(timeIntervalSince1970: 946_684_800))
            try await eventually("Both panes report historical gap") {
                group.sessions.allSatisfy { session in
                    if case .ready = session.playback.historyNavigation { return session.playback.historyState == .gap }
                    return false
                }
            }
            let target = try XCTUnwrap(group.sessions[1].playback.history.adjacentRecording(previous: false))
            group.jump(from: group.sessions[1], previous: false)
            XCTAssertEqual(group.sessions.map { $0.playback.history.position }, [target.timeIntervalSince1970, target.timeIntervalSince1970])
            XCTAssertTrue(group.isPaused)
            group.goLive()
            XCTAssertTrue(group.sessions.allSatisfy { $0.playback.isLive })
            print("Multiple-camera smoke passed: default live quality, shared paused buffers, synchronized playing history, and per-pane gap navigation")
        } catch {
            for (model, task) in streams { task.cancel(); await model.stop(); await task.value }
            group.deactivate(); await client.disconnect(); throw error
        }
        for (model, task) in streams { task.cancel(); await model.stop(); await task.value }
        group.deactivate(); await client.disconnect()
    }

    func testCameraSwitchPreservesLiveBufferTimeAndHistoryPauseThroughRealServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit history smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        do {
            let cameras = try await client.listTopology().devices.filter {
                CameraPlaybackHistoryAvailability.isAvailable(in: $0.metadata)
            }
            guard cameras.count >= 2 else { throw XCTSkip("Camera switching smoke needs two NVR cameras") }
            let source = cameras[0], target = cameras[1]
            let playback = CameraLivePlaybackController()
            playback.prepareHistory(metadata: source.metadata, client: client)
            let model = CameraLiveVideoModel(deviceIdentifier: source.addressableName,
                quality: .low, client: client, playbackController: playback)
            let stream = Task { await model.run() }
            let destination: CameraSwitchPosition
            do {
                try await eventually("Source camera buffer ready") { playback.canControlPlayback }
                playback.togglePause()
                let frozen = try XCTUnwrap(playback.timeline.position)
                try await eventually("Source camera continues buffering while paused") {
                    (playback.timeline.head ?? 0) - frozen > 3
                }
                let departure = playback.positionForCameraSwitch(metadata: source.metadata)
                guard case .relative = departure else { throw CameraHistoryError.invalidResponse }
                let transport = await client.makeHistoryTransport()
                do { destination = try await departure.resolve(using: transport) }
                catch { await transport.close(); throw error }
                await transport.close()
            } catch {
                stream.cancel(); await model.stop(); await stream.value; playback.close(); throw error
            }
            stream.cancel(); await model.stop(); await stream.value; playback.close()
            XCTAssertEqual(playback.timeline.retainedBytes, 0, "Switch releases old camera buffer")
            guard case .canonical(let time, let paused) = destination else { throw CameraHistoryError.invalidResponse }
            XCTAssertTrue(paused)
            let replacement = CameraLivePlaybackController()
            defer { replacement.close() }
            replacement.prepareHistory(metadata: target.metadata, client: client)
            replacement.applyCameraSwitch(destination)
            try await eventually("Target camera at source's paused live-buffer timestamp") {
                replacement.historyState == .ready && !replacement.history.fetching
            }
            XCTAssertTrue(replacement.isPaused)
            XCTAssertEqual(replacement.playbackDate?.timeIntervalSince1970 ?? 0, time, accuracy: 0.001)
            try await eventually("Target camera history renders") { replacement.renderer.layer.isReadyForDisplay }

            // Switch back from older, playing history; this is an exact canonical
            // transfer and needs no relative clock lookup or source live stream.
            replacement.seek(to: Date(timeIntervalSince1970: time - 90), paused: false)
            try await eventually("Playing older history before switching back") {
                replacement.historyState == .ready && !replacement.history.fetching
            }
            let back = replacement.positionForCameraSwitch(metadata: target.metadata)
            let final = CameraLivePlaybackController()
            defer { final.close() }
            final.prepareHistory(metadata: source.metadata, client: client)
            final.applyCameraSwitch(back)
            XCTAssertEqual(final.positionForCameraSwitch(metadata: source.metadata), back)
            XCTAssertFalse(final.isPaused)
            replacement.close()
            try await eventually("Original camera resumes at playing history timestamp") {
                final.historyState == .ready && !final.history.fetching
            }
            try await eventually("Original camera history renders") { final.renderer.layer.isReadyForDisplay }
            XCTAssertNil(final.errorMessage)
            print("Camera switch smoke passed: paused \(source.displayName) buffer → \(target.displayName) history; playing history → \(source.displayName)")
        } catch { await client.disconnect(); throw error }
        await client.disconnect()
    }

    func testCalendarJumpBeforeLiveFramesAndEmptyDateThroughRealWebSocket() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit history smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        do {
            let cameras = try await client.listTopology().devices.filter {
                CameraPlaybackHistoryAvailability.isAvailable(in: $0.metadata)
            }
            XCTAssertFalse(cameras.isEmpty)
            for camera in cameras {
                let playback = CameraLivePlaybackController()
                defer { playback.close() }
                playback.prepareHistory(metadata: camera.metadata, client: client)
                let date = Date().addingTimeInterval(-90)
                playback.seek(to: date)
                try await eventually("\(camera.displayName): absolute calendar seek") {
                    playback.historyState == .ready && !playback.history.fetching
                }
                XCTAssertFalse(playback.isPaused)
                XCTAssertTrue(playback.isUsingHistory)
                try await eventually("\(camera.displayName): calendar frame rendered") { playback.renderer.layer.isReadyForDisplay }
                playback.togglePause()
                let emptyDate = Date(timeIntervalSince1970: 946_684_800)
                playback.seek(to: emptyDate)
                try await eventually("\(camera.displayName): empty date shows gap") {
                    playback.historyState == .gap && !playback.history.fetching
                }
                XCTAssertTrue(playback.isPaused)
                XCTAssertEqual(playback.playbackDate, emptyDate)
                XCTAssertNil(playback.errorMessage)
                guard case .ready(let neighbors) = playback.historyNavigation else {
                    XCTFail("\(camera.displayName): expected negotiated nearest-recording support")
                    throw SmokeFailure.timeout
                }
                XCTAssertNil(neighbors.previous, "A date before all retained recordings must disable the previous arrow")
                let next = try XCTUnwrap(neighbors.next)
                playback.seekToAdjacentRecording(previous: false)
                try await eventually("\(camera.displayName): jump to first available recording") {
                    playback.historyState == .ready && !playback.history.fetching
                }
                XCTAssertTrue(playback.isPaused)
                XCTAssertTrue(playback.isUsingHistory)
                XCTAssertEqual(playback.playbackDate?.timeIntervalSince1970 ?? 0, next.start, accuracy: 0.001)
                try await eventually("\(camera.displayName): first available frame rendered") { playback.renderer.layer.isReadyForDisplay }
                print("Calendar smoke passed: \(camera.displayName), absolute playback, empty-date boundary, and paused jump to first recording")
            }
        } catch { await client.disconnect(); throw error }
        await client.disconnect()
    }

    func testNeighborsBeyondEndOfArchiveThroughRealWebSocket() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Explicit history smoke opt-in required")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        let transport = await client.makeHistoryTransport()
        do {
            let cameras = try await client.listTopology().devices.compactMap {
                CameraPlaybackHistoryAvailability.metadata(in: $0.metadata)
            }
            XCTAssertFalse(cameras.isEmpty)
            for camera in cameras {
                let afterArchive = Date().addingTimeInterval(86400).timeIntervalSince1970
                let request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "neighbors", cameraID: camera.cameraID,
                    timeline: "canonical", range: .init(start: afterArchive, end: afterArchive + 1))
                let result = try await transport.fetch(request)
                let neighbors = try XCTUnwrap(result.neighbors)
                XCTAssertEqual(result.frameCount, 0, "Neighbor lookup should return metadata only")
                XCTAssertTrue(result.gaps.isEmpty)
                XCTAssertNil(neighbors.next, "No later video exists beyond the end of the archive")
                let previous = try XCTUnwrap(neighbors.previous)
                XCTAssertLessThan(previous.start, afterArchive)
                let frames = try await transport.fetch(HBNVRMediaRequest(requestID: UUID().uuidString, operation: "frames", cameraID: camera.cameraID,
                    timeline: "canonical", range: .init(start: previous.start, end: min(previous.end, previous.start + 2))))
                XCTAssertGreaterThan(frames.frameCount, 0, "The previous-recording target must have readable video")
                print("Archive end smoke passed: \(camera.cameraID), previous recording readable; no future recording")
            }
        } catch { await transport.close(); await client.disconnect(); throw error }
        await transport.close(); await client.disconnect()
    }

    func testNVRRecentFramesDecodeFromRealWebSocket() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else { throw XCTSkip("Explicit history smoke opt-in required") }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        do {
            let cameras = try await client.listTopology().devices.compactMap {
                CameraPlaybackHistoryAvailability.metadata(in: $0.metadata)
            }
            XCTAssertFalse(cameras.isEmpty)
            let transport = await client.makeHistoryTransport()
            await transport.start()
            do {
                for camera in cameras {
                    let request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "frames", cameraID: camera.cameraID,
                        timeline: "canonical", range: .init(start: -3, end: -1), relativeTo: "live")
                    let batch = try await transport.fetch(request)
                    XCTAssertGreaterThan(batch.frameCount, 0)
                    let renderer = CameraH264Renderer()
                    for piece in batch.pieces where !piece.samples.isEmpty {
                        try renderer.configureHistory(piece.segment)
                        for (index, sample) in piece.samples.enumerated() {
                            try renderer.enqueueHistory(sample, segment: piece.segment, display: index == piece.samples.count - 1)
                        }
                    }
                    try await eventually("History frame decoded") { renderer.layer.isReadyForDisplay }
                    XCTAssertNotEqual(renderer.layer.sampleBufferRenderer.status, .failed)
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        renderer.layer.sampleBufferRenderer.flush(removingDisplayedImage: true) { continuation.resume() }
                    }
                    print("Recent NVR decode passed: \(batch.frameCount) frames, \(batch.bytes) bytes")
                }
            } catch { await transport.close(); throw error }
            await transport.close()
        } catch { await client.disconnect(); throw error }
        await client.disconnect()
    }

    func testNVRHistoryThroughDedicatedWebSocketAndLiveHandoff() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Supply HB_HISTORY_PLAYBACK_SMOKE_URL to read NVR recordings explicitly.")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        do {
            let topology = try await client.listTopology()
            let cameras = CameraVideoCatalog.cameras(in: topology.devices).filter {
                CameraPlaybackHistoryAvailability.isAvailable(in: $0.device.metadata)
            }
            XCTAssertFalse(cameras.isEmpty, "No camera advertises local NVR history")
            for camera in cameras {
                let playback = CameraLivePlaybackController()
                playback.prepareHistory(metadata: camera.device.metadata, client: client)
                let model = CameraLiveVideoModel(deviceIdentifier: camera.device.addressableName,
                    quality: CameraLiveQualitySelection(camera.capability.previewQuality), client: client, playbackController: playback)
                let stream = Task { await model.run() }
                do {
                    try await eventually("\(camera.device.displayName): live buffer ready") { playback.canControlPlayback }
                    playback.togglePause()
                    playback.seek(by: -30)
                    try await eventually("\(camera.device.displayName): history range loaded") {
                        if case .failed(let error) = playback.historyState { print("History error: \(error)") }
                        return playback.isUsingHistory && !playback.history.fetching
                    }
                    XCTAssertTrue(playback.isPaused)
                    XCTAssertEqual(playback.historyState, .ready, "Recent recorded footage is needed for this smoke test")
                    XCTAssertGreaterThan(playback.history.buffer.bytes, 0)
                    try await eventually("\(camera.device.displayName): historical frame rendered") { playback.renderer.layer.isReadyForDisplay }
                    XCTAssertNil(playback.errorMessage)
                    let anchor = try XCTUnwrap(playback.history.canonicalOffset)
                    let previous = try XCTUnwrap(playback.history.position)
                    playback.seek(by: -30)
                    try await eventually("\(camera.device.displayName): earlier history loaded") { !playback.history.fetching }
                    XCTAssertEqual(playback.history.canonicalOffset, anchor)
                    XCTAssertEqual(playback.history.position!, previous - 30, accuracy: 0.001)
                    XCTAssertTrue(playback.isPaused)
                    playback.togglePause()
                    try await eventually("\(camera.device.displayName): history playing") { playback.history.position! > previous - 29.8 }
                    let before = playback.timeline.retainedBytes
                    playback.goLive()
                    XCTAssertTrue(playback.isLive)
                    XCTAssertGreaterThanOrEqual(playback.timeline.retainedBytes, before)
                    try await eventually("\(camera.device.displayName): return Live after history") { playback.renderer.layer.isReadyForDisplay }
                    XCTAssertNil(playback.errorMessage)
                    print("History smoke passed: \(camera.device.displayName), history \(playback.history.buffer.bytes) bytes; live \(playback.timeline.retainedBytes) bytes")
                } catch {
                    stream.cancel(); await model.stop(); await stream.value; playback.close()
                    throw error
                }
                stream.cancel(); await model.stop(); await stream.value; playback.close()
            }
        } catch { await client.disconnect(); throw error }
        await client.disconnect()
    }

    func testLiveCameraPauseSeekAndReturnToLive() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_LIVE_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Supply HB_LIVE_PLAYBACK_SMOKE_URL to access live cameras explicitly.")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        do {
            try await client.connect()
            let topology = try await client.listTopology()
            let cameras = CameraVideoCatalog.cameras(in: topology.devices)
            XCTAssertFalse(cameras.isEmpty)
            for camera in cameras {
                let playback = CameraLivePlaybackController()
                let model = CameraLiveVideoModel(
                    deviceIdentifier: camera.device.addressableName,
                    quality: CameraLiveQualitySelection(camera.capability.previewQuality),
                    client: client, playbackController: playback
                )
                let stream = Task { await model.run() }
                do {
                    try await eventually("\(camera.device.displayName): receive live video") { playback.canControlPlayback }
                    try await eventually("\(camera.device.displayName): collect buffer while Live") {
                        playback.timeline.entries.count > 10
                    }
                    XCTAssertTrue(playback.isLive)
                    playback.togglePause()
                    let pausedPosition = playback.timeline.position
                    try await eventually("\(camera.device.displayName): fill paused buffer") {
                        (playback.timeline.head ?? 0) - (pausedPosition ?? 0) >= 5
                            && playback.timeline.entries.count > 10
                    }
                    XCTAssertTrue(playback.isPaused)
                    XCTAssertEqual(playback.timeline.position, pausedPosition)
                    XCTAssertGreaterThan(playback.timeline.retainedBytes, 0)
                    let middle = (playback.timeline.tail! + playback.timeline.head!) / 2
                    playback.seek(by: middle - playback.timeline.position!)
                    XCTAssertTrue(playback.isPaused)
                    XCTAssertEqual(playback.timeline.position!, middle, accuracy: 0.001)
                    try await eventually("\(camera.device.displayName): display buffered seek") { playback.renderer.layer.isReadyForDisplay }
                    XCTAssertNil(playback.errorMessage)
                    XCTAssertNotEqual(playback.renderer.layer.sampleBufferRenderer.status, .failed)
                    // Exercise standalone buffering even on a server with an
                    // NVR; this does not change the server or request history.
                    playback.seek(by: -30)
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(playback.timeline.position, playback.timeline.tail)
                    XCTAssertFalse(playback.canSeekBackward)
                    playback.seek(by: 30)
                    XCTAssertTrue(playback.isPaused)
                    let pausedAtHead = playback.timeline.position
                    try await eventually("\(camera.device.displayName): stay paused at former live head") {
                        playback.timeline.head! > pausedAtHead! + 0.2
                    }
                    XCTAssertEqual(playback.timeline.position, pausedAtHead)
                    playback.seek(by: -30)
                    playback.togglePause()
                    let playingPosition = playback.timeline.position!
                    try await eventually("\(camera.device.displayName): advance playback") { playback.timeline.position! > playingPosition + 0.2 }
                    XCTAssertTrue(playback.canSeekBackward)
                    XCTAssertFalse(playback.isLive)
                    playback.seek(by: 30)
                    XCTAssertTrue(playback.isLive)
                    let retainedCount = playback.timeline.entries.count
                    XCTAssertGreaterThan(retainedCount, 10)
                    try await eventually("\(camera.device.displayName): keep collecting after returning Live") {
                        playback.timeline.entries.count > retainedCount + 5
                    }
                    try await eventually("\(camera.device.displayName): resynchronize live") { playback.renderer.layer.isReadyForDisplay }
                    playback.seek(by: -3)
                    XCTAssertFalse(playback.isLive)
                    try await eventually("\(camera.device.displayName): rewind directly from Live") { playback.renderer.layer.isReadyForDisplay }
                    playback.goLive()
                    XCTAssertGreaterThan(playback.timeline.retainedBytes, 0)
                    XCTAssertNil(playback.errorMessage)
                    print("Live buffer smoke passed: \(camera.device.displayName)")
                } catch {
                    print("Smoke diagnostics: model=\(model.state), mode=\(playback.mode), head=\(String(describing: playback.timeline.head)), position=\(String(describing: playback.timeline.position)), frames=\(playback.timeline.entries.count), renderer=\(playback.renderer.layer.sampleBufferRenderer.status.rawValue), ready=\(playback.renderer.isReadyForMoreMediaData), error=\(playback.errorMessage ?? "none")")
                    stream.cancel()
                    await model.stop()
                    await stream.value
                    playback.close()
                    throw error
                }
                stream.cancel()
                await model.stop()
                await stream.value
                XCTAssertGreaterThan(playback.timeline.retainedBytes, 0)
                playback.close()
                XCTAssertFalse(playback.canControlPlayback)
                XCTAssertEqual(playback.timeline.retainedBytes, 0)
            }
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    private func eventually(_ phase: String, _ condition: () -> Bool) async throws {
        print("Live smoke: \(phase)")
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                XCTFail("\(phase) did not reach the expected state within 15 seconds")
                throw SmokeFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum SmokeFailure: Error { case timeout }
}
