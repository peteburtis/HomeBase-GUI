//
//  CameraLiveVideo.swift
//  HomeBase-GUI
//

import AVFoundation
import Combine
import CoreMedia
import Foundation
import HomeBaseProtocol
@preconcurrency import Network
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CameraLiveVideoCapability: Equatable, Sendable {
    static let availableMetadataKey = "cameraLiveVideo"
    static let codecsMetadataKey = "cameraVideoCodecs"
    static let qualitiesMetadataKey = "cameraVideoQualities"
    static let streamPolicyMetadataKey = "cameraLiveStream"

    let qualities: Set<HBCameraLiveQuality>
    let supportsDefaultQuality: Bool

    init(
        qualities: Set<HBCameraLiveQuality>,
        supportsDefaultQuality: Bool = false
    ) {
        self.qualities = qualities
        self.supportsDefaultQuality = supportsDefaultQuality
    }

    init?(metadata: [String: HBJSONValue]) {
        guard metadata[Self.availableMetadataKey]?.boolValue == true else {
            return nil
        }

        let codecs = metadata[Self.codecsMetadataKey]?.arrayValue?
            .compactMap(\.stringValue)
            .map { $0.lowercased() } ?? []
        guard codecs.isEmpty || codecs.contains("h264") else { return nil }

        let advertisedQualities = metadata[Self.qualitiesMetadataKey]?
            .arrayValue?
            .compactMap(\.stringValue)
            .map { $0.lowercased() }
            .compactMap(HBCameraLiveQuality.init(rawValue:)) ?? []
        let qualities = Set(advertisedQualities)
        self.qualities = qualities.isEmpty
            ? Set(HBCameraLiveQuality.allCases)
            : qualities
        supportsDefaultQuality = metadata[Self.streamPolicyMetadataKey]?
            .objectValue?["version"]?.numberValue.map { $0 >= 1 } ?? false
    }

    var previewQuality: HBCameraLiveQuality {
        qualities.min() ?? .low
    }

    var fullScreenQuality: CameraLiveQualitySelection {
        supportsDefaultQuality
            ? .automatic
            : CameraLiveQualitySelection(qualities.max() ?? .high)
    }
}

struct CameraVideoDevice: Identifiable, Equatable, Sendable {
    let device: HBTopologyDeviceDescriptor
    let capability: CameraLiveVideoCapability

    var id: String { device.identifier }
    var artificialFeed: CameraArtificialFeed? {
        device.metadata[CameraArtificialFeed.metadataKey]?.stringValue
            .flatMap(CameraArtificialFeed.init(rawValue:))
    }
}

enum CameraArtificialFeed: String, CaseIterable, Sendable {
    static let environmentVariable = "HOMEBASE_ARTIFICIAL_CAMERAS"
    static let metadataKey = "homeBaseGUIArtificialCameraFeed"

    case red
    case green
    case blue
    case purple

    var color: Color {
        switch self {
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    var displayName: String {
        "Artificial \(rawValue.capitalized) Camera"
    }

    static var isEnabledByEnvironment: Bool {
        guard let value = ProcessInfo.processInfo.environment[environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return !value.isEmpty && !["0", "false", "no", "off"].contains(value)
    }
}

enum CameraVideoCatalog {
    static func cameras(
        in devices: [HBTopologyDeviceDescriptor],
        includesArtificial: Bool = CameraArtificialFeed.isEnabledByEnvironment
    ) -> [CameraVideoDevice] {
        let realCameras: [CameraVideoDevice] = devices.compactMap { device in
            guard let capability = CameraLiveVideoCapability(
                metadata: device.metadata
            ) else { return nil }
            return CameraVideoDevice(
                device: device,
                capability: capability
            )
        }
        guard includesArtificial else { return realCameras }
        return realCameras + CameraArtificialFeed.allCases.map { feed in
            let device = HBTopologyDeviceDescriptor(
                identifier: "homebase-gui-artificial-camera-\(feed.rawValue)",
                addressableName: "HomeBaseGUIArtificialCamera\(feed.rawValue.capitalized)",
                displayName: feed.displayName,
                metadata: [
                    CameraLiveVideoCapability.availableMetadataKey: .bool(true),
                    CameraLiveVideoCapability.qualitiesMetadataKey: .array(
                        HBCameraLiveQuality.allCases.map { .string($0.rawValue) }
                    ),
                    CameraLiveVideoCapability.streamPolicyMetadataKey: .object([
                        "version": .integer(1),
                    ]),
                    CameraArtificialFeed.metadataKey: .string(feed.rawValue),
                ]
            )
            return CameraVideoDevice(
                device: device,
                capability: CameraLiveVideoCapability(
                    qualities: Set(HBCameraLiveQuality.allCases),
                    supportsDefaultQuality: true
                )
            )
        }
    }
}

enum CameraLiveQualityPresentation {
    static func options(
        in qualities: Set<HBCameraLiveQuality>,
        includesDefault: Bool
    ) -> [CameraLiveQualitySelection] {
        (includesDefault ? [.automatic] : [])
            + qualities.sorted(by: >).map(CameraLiveQualitySelection.init)
    }

    static func title(for quality: CameraLiveQualitySelection) -> String {
        switch quality {
        case .automatic: return "Default"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

nonisolated final class HomeBaseMediaConnection: @unchecked Sendable {
    enum ConnectionError: Error, LocalizedError {
        case invalidPort
        case invalidServerMessage(String)
        case connectionEnded

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                "The HomeBase media port is invalid."
            case .invalidServerMessage(let reason):
                "The HomeBase media server sent an invalid message: \(reason)"
            case .connectionEnded:
                "The HomeBase media connection ended."
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "io.pjb.HomeBase-GUI.LiveVideoConnection"
    )
    private var decoder = HBMediaFrameDecoder()
    private var continuation:
        AsyncThrowingStream<HBMediaFrame, Error>.Continuation?
    private var lastSequence: UInt64?
    private var hello: Data?
    private var finished = false

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ConnectionError.invalidPort
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
    }

    func frames(
        ticket: String
    ) throws -> AsyncThrowingStream<HBMediaFrame, Error> {
        let hello = try HBMediaFrameCodec.encode(HBMediaFrame(
            type: .clientHello,
            payload: Data(ticket.utf8)
        ))

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(120)) {
            continuation in
            queue.async { [weak self] in
                self?.start(hello: hello, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.cancel()
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finish()
        }
    }

    private func start(
        hello: Data,
        continuation: AsyncThrowingStream<HBMediaFrame, Error>.Continuation
    ) {
        guard !finished, self.continuation == nil else {
            continuation.finish(throwing: ConnectionError.connectionEnded)
            return
        }
        self.hello = hello
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.stateChanged(state)
            }
        }
        connection.start(queue: queue)
    }

    private func stateChanged(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            sendHello()
        case .waiting(let error):
            // Before redemption, Network.framework may recover this attempt.
            // The arbiter's warm-up deadline bounds that wait. A redeemed
            // ticket can never be reused to establish another connection.
            if hello == nil { finish(throwing: error) }
        case .failed(let error):
            finish(throwing: error)
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private func sendHello() {
        guard let hello else {
            finish(throwing: ConnectionError.invalidServerMessage(
                "the client handshake was unavailable"
            ))
            return
        }
        self.hello = nil
        connection.send(content: hello, completion: .contentProcessed {
            [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if let error {
                    self.finish(throwing: error)
                } else {
                    self.receive()
                }
            }
        })
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, complete, error in
            self?.queue.async {
                guard let self, !self.finished else { return }
                if let error {
                    self.finish(throwing: error)
                    return
                }

                do {
                    if let data, !data.isEmpty {
                        for frame in try self.decoder.append(data) {
                            try self.accept(frame)
                        }
                    }
                    if complete {
                        try self.decoder.validateEndOfStream()
                        self.finish(throwing: ConnectionError.connectionEnded)
                    } else {
                        self.receive()
                    }
                } catch {
                    self.finish(throwing: error)
                }
            }
        }
    }

    private func accept(_ frame: HBMediaFrame) throws {
        guard frame.type != .clientHello else {
            throw ConnectionError.invalidServerMessage(
                "a server sent a client-only handshake frame"
            )
        }
        if let lastSequence, frame.sequence != lastSequence &+ 1 {
            throw ConnectionError.invalidServerMessage(
                "media sequence \(frame.sequence) followed \(lastSequence)"
            )
        }
        lastSequence = frame.sequence
        guard let continuation else {
            finish()
            return
        }
        switch continuation.yield(frame) {
        case .enqueued:
            break
        case .dropped:
            throw ConnectionError.invalidServerMessage(
                "the client could not keep up with the live video stream"
            )
        case .terminated:
            finish()
            return
        @unknown default:
            finish()
            return
        }
        if frame.type == .streamEnd {
            finish()
        }
    }

    private func finish(throwing error: Error? = nil) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        hello = nil
    }
}

@MainActor
final class CameraH264Renderer: ObservableObject {
    enum RendererError: Error, LocalizedError {
        case unsupportedCodec(String)
        case invalidParameterSets
        case invalidAccessUnit
        case mediaFrameworkFailure(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedCodec(let codec):
                "The camera selected unsupported video codec \(codec)."
            case .invalidParameterSets:
                "The camera supplied invalid H.264 configuration data."
            case .invalidAccessUnit:
                "The camera supplied an invalid H.264 picture."
            case .mediaFrameworkFailure(let operation, let status):
                "\(operation) failed with media status \(status)."
            }
        }
    }

    let layer = AVSampleBufferDisplayLayer()
    let displayRelay = CameraVideoDisplayRelay()
    var suppressesDisplay = false
    private var formatDescription: CMVideoFormatDescription?
    private var generation: UInt32?
    private var timeScale: Int32 = 90_000
    private var firstTimestamp: UInt64?
    private var firstHistoryTimestamp: Int64?
    private var sampleDuration: CMTime = .invalid
    private var waitingForKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func configure(
        _ configuration: HBMediaStreamConfiguration,
        removingDisplayedImage: Bool = true,
        updateRenderer: Bool = true
    ) throws -> CMVideoFormatDescription {
        guard configuration.codec.lowercased() == "h264" else {
            throw RendererError.unsupportedCodec(configuration.codec)
        }
        guard configuration.timeScale > 0,
              configuration.timeScale <= UInt32(Int32.max),
              let sps = Data(base64Encoded: configuration.sequenceParameterSet),
              let pps = Data(base64Encoded: configuration.pictureParameterSet),
              !sps.isEmpty,
              !pps.isEmpty else {
            throw RendererError.invalidParameterSets
        }

        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsAddress = spsBytes.bindMemory(to: UInt8.self)
                    .baseAddress,
                      let ppsAddress = ppsBytes.bindMemory(to: UInt8.self)
                        .baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers = [spsAddress, ppsAddress]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw RendererError.mediaFrameworkFailure(
                "H.264 configuration",
                status
            )
        }

        guard updateRenderer else { return description }
        reset(removingDisplayedImage: removingDisplayedImage)
        formatDescription = description
        generation = configuration.generation
        timeScale = Int32(configuration.timeScale)
        firstTimestamp = nil
        if let frameRate = configuration.frameRate,
           frameRate.isFinite,
           frameRate > 0 {
            sampleDuration = CMTime(
                seconds: 1 / frameRate,
                preferredTimescale: timeScale
            )
        } else {
            sampleDuration = .invalid
        }
        return description
    }

    @discardableResult
    func enqueue(_ frame: HBMediaFrame, display: Bool = true) throws -> CMSampleBuffer? {
        guard frame.type == .videoAccessUnit,
              frame.generation == generation,
              let formatDescription else {
            return nil
        }
        guard Self.isValidAVCCAccessUnit(frame.payload) else {
            throw RendererError.invalidAccessUnit
        }
        if layer.sampleBufferRenderer.status == .failed { reset() }
        if waitingForKeyframe {
            guard frame.flags.contains(.keyFrame) else { return nil }
            waitingForKeyframe = false
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RendererError.mediaFrameworkFailure(
                "H.264 buffer creation",
                status
            )
        }

        status = frame.payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.payload.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RendererError.mediaFrameworkFailure(
                "H.264 buffer copy",
                status
            )
        }

        let origin = firstTimestamp ?? frame.presentationTimestamp
        firstTimestamp = origin
        let relativeTimestamp = frame.presentationTimestamp >= origin
            ? frame.presentationTimestamp - origin
            : 0
        var timing = CMSampleTimingInfo(
            duration: sampleDuration,
            presentationTimeStamp: CMTime(
                value: Int64(clamping: relativeTimestamp),
                timescale: timeScale
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.payload.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RendererError.mediaFrameworkFailure(
                "H.264 sample creation",
                status
            )
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
           let attachment = attachments.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
            attachment[kCMSampleAttachmentKey_DoNotDisplay] = !display || suppressesDisplay
            attachment[kCMSampleAttachmentKey_NotSync] =
                !frame.flags.contains(.keyFrame)
        }

        layer.sampleBufferRenderer.enqueue(sampleBuffer)
        displayRelay.enqueue(sampleBuffer, keyFrame: frame.flags.contains(.keyFrame))
        return sampleBuffer
    }

    var isReadyForMoreMediaData: Bool {
        layer.sampleBufferRenderer.isReadyForMoreMediaData
    }

    func configureHistory(_ segment: CameraHistorySegment) throws {
        let description = try CameraHistorySampleBuilder.format(segment)
        reset()
        formatDescription = description
        generation = nil
    }

    @discardableResult
    func enqueueHistory(_ sample: CameraHistorySample, segment: CameraHistorySegment, display: Bool) throws -> CMSampleBuffer? {
        guard let formatDescription else { return nil }
        if layer.sampleBufferRenderer.status == .failed { reset() }
        if waitingForKeyframe {
            guard sample.frame.keyFrame else { return nil }
            waitingForKeyframe = false
        }
        let origin = firstHistoryTimestamp ?? sample.frame.presentationTicks
        firstHistoryTimestamp = origin
        let buffer = try CameraHistorySampleBuilder.sample(sample, segment: segment,
            format: formatDescription, origin: origin, display: display)
        layer.sampleBufferRenderer.enqueue(buffer)
        displayRelay.enqueue(buffer, keyFrame: sample.frame.keyFrame)
        return buffer
    }

    func reset(removingDisplayedImage: Bool = true) {
        displayRelay.flush(removingDisplayedImage: removingDisplayedImage)
        layer.sampleBufferRenderer.flush(
            removingDisplayedImage: removingDisplayedImage,
            completionHandler: nil
        )
        firstTimestamp = nil
        firstHistoryTimestamp = nil
        waitingForKeyframe = true
    }

    nonisolated static func isValidAVCCAccessUnit(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        var offset = 0
        var nalCount = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { return false }
            let length = data[offset ..< offset + 4].reduce(0) {
                ($0 << 8) | Int($1)
            }
            offset += 4
            guard length > 0, length <= data.count - offset else {
                return false
            }
            offset += length
            nalCount += 1
        }
        return offset == data.count && nalCount > 0
    }
}

/// Tracks the logical current run separately from every run that still owns
/// cleanup work. A normal stop may supersede a run before its subscription
/// acquisition returns; a later immediate stop must still strengthen that
/// unfinished run's eventual release policy.
@MainActor
struct CameraLiveVideoRunOwnership {
    struct Completion: Equatable {
        let wasCurrent: Bool
        let immediateStopRequested: Bool
    }

    private var current: UUID?
    private var unfinished: Set<UUID> = []
    private var immediateStops: Set<UUID> = []

    mutating func begin() -> UUID {
        let token = UUID()
        current = token
        unfinished.insert(token)
        return token
    }

    func isCurrent(_ token: UUID) -> Bool {
        current == token
    }

    @discardableResult
    mutating func stop(immediately: Bool) -> UUID? {
        let stopped = current
        if immediately {
            immediateStops.formUnion(unfinished)
        }
        current = nil
        return stopped
    }

    func shouldReleaseImmediately(_ token: UUID) -> Bool {
        immediateStops.contains(token)
    }

    mutating func finish(_ token: UUID) -> Completion {
        let wasCurrent = current == token
        if wasCurrent {
            current = nil
        }
        unfinished.remove(token)
        return Completion(
            wasCurrent: wasCurrent,
            immediateStopRequested: immediateStops.remove(token) != nil
        )
    }
}

@MainActor
final class CameraLiveVideoModel: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case waiting(String)
        case playing
        case ended(String, retryable: Bool)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var qualityWarning: String?

    let renderer: CameraH264Renderer

    private let deviceIdentifier: String
    let artificialFeed: CameraArtificialFeed?
    private var quality: CameraLiveQualitySelection
    private let client: HomeBaseWebSocketClient
    private let recordingController: CameraLocalRecordingController?
    private let playbackController: CameraLivePlaybackController?
    private var arbiter: CameraStreamArbiter?
    private var knownArbiter: CameraStreamArbiter?
    private var subscription: CameraStreamSubscription?
    private var runOwnership = CameraLiveVideoRunOwnership()

    init(
        deviceIdentifier: String,
        quality: CameraLiveQualitySelection,
        client: HomeBaseWebSocketClient,
        recordingController: CameraLocalRecordingController? = nil,
        playbackController: CameraLivePlaybackController? = nil,
        artificialFeed: CameraArtificialFeed? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.artificialFeed = artificialFeed
        self.quality = quality
        self.client = client
        self.recordingController = recordingController
        self.playbackController = playbackController
        self.renderer = playbackController?.renderer ?? CameraH264Renderer()
    }

    func setQuality(_ quality: CameraLiveQualitySelection) async {
        self.quality = quality
        if let arbiter, let subscription { await arbiter.update(subscription, quality: quality) }
    }

    func run(access: CameraAccessSession? = nil, authorization explicitAuthorization: CameraStreamAuthorization? = nil,
             viewerStreamOwner: UUID? = nil) async {
        guard state == .idle, !Task.isCancelled else { return }
        let token = runOwnership.begin()
        if artificialFeed != nil {
            state = .playing
            do {
                while runOwnership.isCurrent(token), !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3_600))
                }
            } catch {}
            let completion = runOwnership.finish(token)
            if completion.wasCurrent { state = .idle }
            return
        }
        state = .connecting
        qualityWarning = nil
        var ownedArbiter: CameraStreamArbiter?
        var ownedSubscription: CameraStreamSubscription?

        do {
            try Task.checkCancellation()
            guard runOwnership.isCurrent(token) else { throw CancellationError() }
            let shared = await client.cameraStreamArbiter()
            knownArbiter = shared
            guard runOwnership.isCurrent(token) else { throw CancellationError() }
            let authorization: CameraStreamAuthorization?
            if let explicitAuthorization {
                authorization = explicitAuthorization
            } else if let viewerStreamOwner {
                authorization = try access?.authorizeViewerStream(shared, camera: deviceIdentifier, owner: viewerStreamOwner)
            } else {
                authorization = try access?.authorizeStreams(shared)
            }
            let acquired = try await shared.subscribe(camera: deviceIdentifier, quality: quality, authorization: authorization)
            ownedArbiter = shared; ownedSubscription = acquired
            try Task.checkCancellation()
            guard runOwnership.isCurrent(token) else { throw CancellationError() }
            arbiter = shared; subscription = acquired
            // A quality selection may have changed during the acquire.
            await shared.update(acquired, quality: quality)
            events: for try await event in acquired.events {
                try Task.checkCancellation()
                guard runOwnership.isCurrent(token) else { break }
                guard authorization?.isValid != false else { throw CancellationError() }
                switch event {
                case .reconnecting:
                    state = .waiting("Reconnecting to camera…")
                case .qualityWarning(let message): qualityWarning = message
                case .frames(let frames):
                    for frame in frames {
                        guard runOwnership.isCurrent(token), !Task.isCancelled,
                              authorization?.isValid != false else { break events }
                        if try await !consume(frame, ownerID: token) {
                            break events
                        }
                        guard runOwnership.isCurrent(token),
                              !Task.isCancelled else { break events }
                    }
                }
            }
            if !Task.isCancelled, runOwnership.isCurrent(token) {
                switch state {
                case .ended, .failed:
                    break
                default:
                    state = .failed("The live video connection ended.")
                }
            }
        } catch is CancellationError {
            if runOwnership.isCurrent(token) { state = .idle }
        } catch {
            if runOwnership.isCurrent(token) {
                state = .failed(error.localizedDescription)
            }
        }

        let stopImmediately = runOwnership.shouldReleaseImmediately(token)
        await releaseSubscription(
            ownedSubscription,
            from: ownedArbiter,
            immediately: stopImmediately
        )
        let completion = runOwnership.finish(token)
        if completion.immediateStopRequested, !stopImmediately {
            // An immediate stop can arrive while an ordinary unsubscribe is
            // crossing actors. Upgrade the now-idle entry after that release.
            await ownedArbiter?.stopIdleStreamImmediately(
                camera: deviceIdentifier
            )
        }
        if completion.wasCurrent {
            playbackController?.stop(ownerID: token)
            await recordingController?.streamDidEnd(ownerID: token)
        }
    }

    func stop(immediately: Bool = false) async {
        // Mark every unfinished run before awaiting network work. This covers
        // a subscription that exists inside run() but is not published yet.
        let stoppedOwnerID = runOwnership.stop(immediately: immediately)
        if let stoppedOwnerID {
            playbackController?.stop(ownerID: stoppedOwnerID)
        }
        // Publish the stopped state before awaiting network cleanup, so an old
        // stop cannot overwrite a newer run after a quick dismissal/reopen.
        state = .idle
        qualityWarning = nil
        await releaseSubscription(subscription, from: arbiter, immediately: immediately)
        if immediately {
            // A preceding ordinary release may already have removed this
            // consumer and entered the arbiter's handoff grace. Upgrade that
            // idle entry too; another active viewer is never disturbed.
            await knownArbiter?.stopIdleStreamImmediately(camera: deviceIdentifier)
        }
        if let stoppedOwnerID {
            await recordingController?.streamDidEnd(ownerID: stoppedOwnerID)
        }
    }

    private func consume(
        _ frame: HBMediaFrame,
        ownerID: UUID
    ) async throws -> Bool {
        guard runOwnership.isCurrent(ownerID), !Task.isCancelled else {
            throw CancellationError()
        }
        switch frame.type {
        case .streamStatus:
            let status = try JSONDecoder().decode(
                HBMediaStreamStatus.self,
                from: frame.payload
            )
            // Older servers can reconfigure their shared source even while a
            // replacement is warming. Never blank a previously playing image.
            if state != .playing || status.state != .reconfiguring {
                state = .waiting(Self.statusText(status))
            }
        case .streamConfiguration:
            let configuration = try JSONDecoder().decode(
                HBMediaStreamConfiguration.self,
                from: frame.payload
            )
            guard configuration.generation == frame.generation else {
                throw HomeBaseMediaConnection.ConnectionError
                    .invalidServerMessage(
                        "the H.264 generation did not match its frame"
                    )
            }
            let formatDescription: CMVideoFormatDescription
            if let playbackController {
                formatDescription = try playbackController.configure(
                    configuration,
                    ownerID: ownerID,
                    preservingDisplayedImage: true
                )
            } else {
                formatDescription = try renderer.configure(configuration, removingDisplayedImage: false)
            }
            if let recordingController {
                let configured = await recordingController.configure(
                    ownerID: ownerID,
                    generation: configuration.generation,
                    formatDescription: formatDescription
                )
                guard configured else { throw CancellationError() }
            }
            guard runOwnership.isCurrent(ownerID), !Task.isCancelled else {
                throw CancellationError()
            }
            if configuration.width > 0, configuration.height > 0 {
                aspectRatio = CGFloat(configuration.width)
                    / CGFloat(configuration.height)
            }
            if state != .playing { state = .waiting("Waiting for video…") }
        case .videoAccessUnit:
            let sampleBuffer: CMSampleBuffer?
            if let playbackController {
                sampleBuffer = try playbackController.receive(
                    frame, ownerID: ownerID
                )
            } else {
                sampleBuffer = try renderer.enqueue(frame)
            }
            if let sampleBuffer {
                recordingController?.append(
                    sampleBuffer,
                    ownerID: ownerID,
                    generation: frame.generation,
                    isKeyFrame: frame.flags.contains(.keyFrame)
                )
            }
            if state != .playing { state = .playing }
        case .streamEnd:
            let end = try JSONDecoder().decode(
                HBMediaStreamEnd.self,
                from: frame.payload
            )
            state = .ended(end.reason, retryable: end.retryable)
            return false
        case .clientHello:
            throw HomeBaseMediaConnection.ConnectionError
                .invalidServerMessage(
                    "a server sent a client-only handshake frame"
                )
        }
        return true
    }

    private func releaseSubscription(
        _ owned: CameraStreamSubscription?,
        from shared: CameraStreamArbiter?,
        immediately: Bool = false
    ) async {
        guard let owned, let shared else { return }
        if subscription?.id == owned.id { subscription = nil; arbiter = nil }
        await shared.unsubscribe(camera: owned.camera, id: owned.id, immediately: immediately)
    }

    private static func statusText(_ status: HBMediaStreamStatus) -> String {
        if let detail = status.detail, !detail.isEmpty { return detail }
        switch status.state {
        case .starting:
            return "Starting video…"
        case .reconfiguring:
            return "Changing video quality…"
        case .reconnecting:
            return "Reconnecting to camera…"
        }
    }
}

extension CameraLiveVideoModel.State {
    var displaysVideo: Bool {
        self == .playing
    }
}

enum CameraLiveVideoLifecycle {
    struct TaskIdentity: Hashable {
        let retryID: Int
        let isSuspended: Bool
    }

    static func isSuspended(
        in scenePhase: ScenePhase,
        isStreamEnabled: Bool = true
    ) -> Bool {
        !isStreamEnabled || scenePhase == .background
    }

    static func taskIdentity(
        retryID: Int,
        scenePhase: ScenePhase,
        isStreamEnabled: Bool = true
    ) -> TaskIdentity {
        TaskIdentity(
            retryID: retryID,
            isSuspended: isSuspended(in: scenePhase, isStreamEnabled: isStreamEnabled)
        )
    }
}

struct CameraLiveVideoPlayer: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.cameraAccessSession) private var cameraAccessSession
    @StateObject private var model: CameraLiveVideoModel
    @State private var retryID = 0
    private let allowsRetry: Bool
    private let isStreamEnabled: Bool
    private let restartRequest: Int
    private let usesHistory: Bool
    private let quality: CameraLiveQualitySelection
    private let onStateChanged: ((CameraLiveVideoModel.State) -> Void)?
    private let onAspectRatioChanged: ((CGFloat) -> Void)?

    init(
        deviceIdentifier: String,
        quality: CameraLiveQualitySelection,
        client: HomeBaseWebSocketClient,
        allowsRetry: Bool,
        isStreamEnabled: Bool = true,
        restartRequest: Int = 0,
        recordingController: CameraLocalRecordingController? = nil,
        playbackController: CameraLivePlaybackController? = nil,
        artificialFeed: CameraArtificialFeed? = nil,
        usesHistory: Bool = false,
        onStateChanged: ((CameraLiveVideoModel.State) -> Void)? = nil,
        onAspectRatioChanged: ((CGFloat) -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: CameraLiveVideoModel(
            deviceIdentifier: deviceIdentifier,
            quality: quality,
            client: client,
            recordingController: recordingController,
            playbackController: playbackController,
            artificialFeed: artificialFeed
        ))
        self.allowsRetry = allowsRetry
        self.isStreamEnabled = isStreamEnabled
        self.restartRequest = restartRequest
        self.usesHistory = usesHistory
        self.quality = quality
        self.onStateChanged = onStateChanged
        self.onAspectRatioChanged = onAspectRatioChanged
    }

    var body: some View {
        CameraLiveVideoSurface(
            model: model,
            allowsRetry: allowsRetry,
            usesHistory: usesHistory,
            retry: retry
        )
        .onChange(of: quality, initial: true) { _, value in
            Task { await model.setQuality(value) }
        }
        .onChange(of: model.state, initial: true) { _, state in onStateChanged?(state) }
        .onChange(of: model.aspectRatio, initial: true) { _, ratio in onAspectRatioChanged?(ratio) }
        .task(id: CameraLiveVideoLifecycle.taskIdentity(
            retryID: retryID,
            scenePhase: scenePhase,
            isStreamEnabled: isStreamEnabled
        )) {
            // Standalone previews own their model lifetime. Full-screen camera
            // sessions use CameraLiveVideoSurface directly and are coordinated
            // by CameraGroupPlayback instead of view appearance.
            await model.stop(immediately: scenePhase == .background)
            guard !Task.isCancelled,
                  !CameraLiveVideoLifecycle.isSuspended(
                    in: scenePhase, isStreamEnabled: isStreamEnabled
                  ) else { return }
            await model.run(access: cameraAccessSession)
        }
        .onChange(of: restartRequest) { _, _ in
            guard isStreamEnabled, scenePhase == .active,
                  !model.state.displaysVideo else { return }
            retry()
        }
        .onDisappear {
            Task {
                await model.stop()
            }
        }
    }

    private func retry() {
        Task {
            await model.stop()
            retryID &+= 1
        }
    }
}

/// Presentation-only camera video. The caller owns the model and its resource
/// lifetime, so rebuilding or laying out this view cannot open or close a
/// camera stream.
struct CameraLiveVideoSurface: View {
    @ObservedObject var model: CameraLiveVideoModel
    let allowsRetry: Bool
    let usesHistory: Bool
    var isSecondaryOutput = false
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .allowsHitTesting(false)
            if let artificialFeed = model.artificialFeed, !usesHistory {
                artificialFeed.color
                    .allowsHitTesting(false)
            } else if usesHistory || model.state.displaysVideo {
                CameraSampleBufferView(renderer: model.renderer, isSecondaryOutput: isSecondaryOutput)
                    .allowsHitTesting(false)
            }

            if !usesHistory, let message = statusMessage {
                VStack(spacing: 12) {
                    if isPending {
                        ProgressView()
                            .tint(.white)
                            .allowsHitTesting(false)
                    } else {
                        Image(systemName: "video.slash.fill")
                            .font(.title2)
                            .allowsHitTesting(false)
                    }
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                    if allowsRetry, canRetry {
                        Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .aspectRatio(model.aspectRatio, contentMode: .fit)
        .accessibilityLabel(usesHistory ? "Recorded camera video" : "Live camera video")
        .overlay(alignment: .top) {
            if !usesHistory, let warning = model.qualityWarning {
                Text(warning).font(.caption).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.65), in: .rect(cornerRadius: 6))
                    .padding().allowsHitTesting(false)
            }
        }
    }

    private var statusMessage: String? {
        switch model.state {
        case .idle, .connecting:
            "Connecting to camera…"
        case .waiting(let message):
            message
        case .playing:
            nil
        case .ended(let reason, _), .failed(let reason):
            reason
        }
    }

    private var isPending: Bool {
        switch model.state {
        case .idle, .connecting, .waiting:
            true
        case .playing, .ended, .failed:
            false
        }
    }

    private var canRetry: Bool {
        switch model.state {
        case .failed, .ended(_, retryable: true):
            true
        default:
            false
        }
    }
}

private struct CameraTransparentToolbar: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        content.toolbarBackgroundVisibility(.hidden, for: .navigationBar)
#elseif os(macOS)
        content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
#else
        content
#endif
    }
}

struct CameraPlayerChromeVisibility: ViewModifier {
    let isVisible: Bool
    let hidesNavigationBar: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        content
            .statusBarHidden(!isVisible)
            .toolbarVisibility(
                isVisible && !hidesNavigationBar ? .visible : .hidden,
                for: .navigationBar
            )
            .toolbarVisibility(
                isVisible ? .visible : .hidden,
                for: .bottomBar
            )
#elseif os(macOS)
        content.toolbarVisibility(
            isVisible ? .visible : .hidden,
            for: .windowToolbar
        )
#else
        content
#endif
    }
}

nonisolated struct CameraToolbarArrangement: Equatable {
    let isLive: Bool
    let compactWidth: Bool
    let compactHeight: Bool

    var usesCompactWidthLayout: Bool {
        compactWidth && !compactHeight
    }

    var configurationControlsInBottomTrailing: Bool {
        isLive && usesCompactWidthLayout
    }

    var playbackControlsInOverflow: Bool {
        isLive && usesCompactWidthLayout
    }

    var playbackControlsInBottomTrailing: Bool {
        !isLive && usesCompactWidthLayout
    }

    var navigationItemsInBottomToolbar: Bool {
        compactHeight
    }

    var recordInTrailingNavigationBar: Bool {
        isLive && !navigationItemsInBottomToolbar
    }

    var recordInBottomTrailing: Bool {
        isLive && navigationItemsInBottomToolbar
    }
}

enum CameraPanGesturePhase {
    case began
    case changed
    case ended
    case cancelled
}

enum CameraMagnifyGesturePhase {
    case began
    case changed
    case ended
    case cancelled
}

#if canImport(UIKit)
final class CameraLiveGestureUIView: UIView {
    var videoVisible = true {
        didSet { updateRecognizerAvailability() }
    }
    var cameraControlsEnabled = true {
        didSet { updateRecognizerAvailability() }
    }
    var onPan: ((CameraPanGesturePhase, CGSize, CGSize) -> Void)?
    var onMagnify: ((CameraMagnifyGesturePhase, CGFloat) -> Void)? {
        didSet { updateRecognizerAvailability() }
    }
    var onSingleTap: (() -> Void)?
    var onTwoFingerTap: (() -> Void)?

    private lazy var pinchRecognizer = UIPinchGestureRecognizer(
        target: self,
        action: #selector(pinched(_:))
    )
    private lazy var panRecognizer = UIPanGestureRecognizer(
        target: self, action: #selector(panned(_:))
    )
    private lazy var twoFingerTapRecognizer = UITapGestureRecognizer(
        target: self, action: #selector(twoFingerTapped)
    )
    private lazy var singleTapRecognizer = UITapGestureRecognizer(
        target: self, action: #selector(singleTapped)
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        panRecognizer.minimumNumberOfTouches = 1
        panRecognizer.maximumNumberOfTouches = 1
        addGestureRecognizer(panRecognizer)

        pinchRecognizer.isEnabled = false
        addGestureRecognizer(pinchRecognizer)

        singleTapRecognizer.numberOfTouchesRequired = 1
        addGestureRecognizer(singleTapRecognizer)

        twoFingerTapRecognizer.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTapRecognizer)
    }

    private func updateRecognizerAvailability() {
        isUserInteractionEnabled = true
        singleTapRecognizer.isEnabled = true
        panRecognizer.isEnabled = videoVisible && cameraControlsEnabled
        pinchRecognizer.isEnabled = videoVisible && cameraControlsEnabled && onMagnify != nil
        twoFingerTapRecognizer.isEnabled = videoVisible && cameraControlsEnabled
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let phase: CameraPanGesturePhase
        switch recognizer.state {
        case .began:
            phase = .began
        case .changed:
            phase = .changed
        case .ended:
            phase = .ended
        case .cancelled, .failed:
            phase = .cancelled
        default:
            return
        }
        let translation = recognizer.translation(in: self)
        onPan?(
            phase,
            CGSize(width: translation.x, height: translation.y),
            bounds.size
        )
    }

    @objc private func singleTapped() {
        onSingleTap?()
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        let phase: CameraMagnifyGesturePhase
        switch recognizer.state {
        case .began:
            phase = .began
        case .changed:
            phase = .changed
        case .ended:
            phase = .ended
        case .cancelled, .failed:
            phase = .cancelled
        default:
            return
        }
        onMagnify?(phase, recognizer.scale)
    }

    @objc private func twoFingerTapped() {
        onTwoFingerTap?()
    }
}

struct CameraLiveGestureSurface: UIViewRepresentable {
    let videoVisible: Bool
    let cameraControlsEnabled: Bool
    let onPan: (CameraPanGesturePhase, CGSize, CGSize) -> Void
    let onMagnify: ((CameraMagnifyGesturePhase, CGFloat) -> Void)?
    let onSingleTap: () -> Void
    let onTwoFingerTap: () -> Void

    func makeUIView(context: Context) -> CameraLiveGestureUIView {
        let view = CameraLiveGestureUIView()
        update(view)
        return view
    }

    func updateUIView(
        _ uiView: CameraLiveGestureUIView,
        context: Context
    ) {
        update(uiView)
    }

    private func update(_ view: CameraLiveGestureUIView) {
        view.videoVisible = videoVisible
        view.cameraControlsEnabled = cameraControlsEnabled
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.onSingleTap = onSingleTap
        view.onTwoFingerTap = onTwoFingerTap
    }
}
#else
struct CameraLiveGestureSurface: View {
    let videoVisible: Bool
    let cameraControlsEnabled: Bool
    let onPan: (CameraPanGesturePhase, CGSize, CGSize) -> Void
    let onMagnify: ((CameraMagnifyGesturePhase, CGFloat) -> Void)?
    let onSingleTap: () -> Void
    let onTwoFingerTap: () -> Void
    @State private var isDragging = false
    @State private var isMagnifying = false

    var body: some View {
        GeometryReader { geometry in
            let surface = Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onPan(.began, .zero, geometry.size)
                            }
                            onPan(
                                .changed,
                                value.translation,
                                geometry.size
                            )
                        }
                        .onEnded { value in
                            isDragging = false
                            onPan(
                                .ended,
                                value.translation,
                                geometry.size
                            )
                        },
                    including: videoVisible && cameraControlsEnabled ? .all : .none
                )
                .simultaneousGesture(
                    TapGesture().onEnded(onSingleTap),
                    including: .all
                )

            if videoVisible, cameraControlsEnabled, let onMagnify {
                surface.simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if !isMagnifying {
                                isMagnifying = true
                                onMagnify(.began, 1)
                            }
                            onMagnify(.changed, value.magnification)
                        }
                        .onEnded { value in
                            isMagnifying = false
                            onMagnify(.ended, value.magnification)
                        }
                )
            } else {
                surface
            }
        }
        .allowsHitTesting(true)
        .onChange(of: videoVisible && cameraControlsEnabled) { _, enabled in
            if !enabled {
                isDragging = false
                isMagnifying = false
            }
        }
    }
}
#endif

struct CameraFullScreenLiveVideoView: View {
    let client: HomeBaseWebSocketClient
    @State private var viewerID: UUID
    @StateObject private var selection: CameraScreenSelection
    @StateObject private var cameraPicker: CameraPickerModel
    @State private var panel = CameraPlayerPanel.off
    @State private var controlsVisible = true

    init(device: HBTopologyDeviceDescriptor, quality: CameraLiveQualitySelection, client: HomeBaseWebSocketClient,
         viewerID: UUID = UUID()) {
        self.client = client
        _viewerID = State(initialValue: viewerID)
        _selection = StateObject(wrappedValue: CameraScreenSelection(device: device, quality: quality))
        _cameraPicker = StateObject(wrappedValue: CameraPickerModel {
            try await client.reactivate()
            return try await client.listTopology().devices
        })
    }

    var body: some View {
        // The presentation and navigation container survive camera changes. Only
        // camera-scoped resources are replaced, preventing stale callbacks or
        // buffers from one camera being attached to another camera's renderer.
        CameraAccessGate { access in
            NavigationStack {
                CameraFullScreenCameraContent(device: selection.session.device,
                quality: selection.session.quality, client: client,
                viewerID: viewerID, screenSelection: selection,
                access: access,
                initialPosition: selection.session.position, cameraPicker: cameraPicker,
                panel: $panel, controlsVisible: $controlsVisible,
                selectCamera: { selection.select($0, position: $1) },
                retainCamera: { selection.retain($0, quality: $1) })
                .id(selection.session.id)
            }
        }
    }
}

#if os(iOS)
private enum CameraRecordingSystemPresentation: Identifiable {
    case files([CameraLocalRecording])
    case share([CameraLocalRecording])

    var id: String {
        switch self {
        case .files(let recordings):
            "files-\(recordings.map(\.id.uuidString).joined(separator: "-"))"
        case .share(let recordings):
            "share-\(recordings.map(\.id.uuidString).joined(separator: "-"))"
        }
    }
}

struct CameraRecordingExportPresentation: Identifiable, Equatable {
    let id: UUID
    let recordings: [CameraLocalRecording]

    init(
        recordings: [CameraLocalRecording],
        id: UUID = UUID()
    ) {
        self.recordings = recordings
        self.id = id
    }
}

struct CameraRecordingExportTrigger: Equatable {
    let recordingIDs: [UUID]
    let isBusy: Bool
    let errorMessage: String?
}

private struct CameraRecordingControlStyle: ViewModifier {
    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.glassProminent)
        } else {
            content
        }
    }
}

private struct CameraRecordingExportPopover: View {
    let recordings: [CameraLocalRecording]
    let saveToPhotos: () -> Void
    let saveToFiles: () -> Void
    let share: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(recordings) { recording in
                        Text(recording.filename)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            .padding()

            Divider()

            VStack(spacing: 8) {
                actionButton(
                    "Save to Photos",
                    systemImage: "photo.on.rectangle",
                    action: saveToPhotos
                )
                actionButton(
                    "Save to Files",
                    systemImage: "folder",
                    action: saveToFiles
                )
                actionButton(
                    "Share",
                    systemImage: "square.and.arrow.up",
                    action: share
                )
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                        .foregroundStyle(.red)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 44,
                            maxHeight: 44
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44,
                    maxHeight: 44
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }
}

private struct CameraRecordingDocumentPicker: UIViewControllerRepresentable {
    let recordings: [CameraLocalRecording]
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forExporting: recordings.map(\.fileURL),
            asCopy: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(false)
        }
    }
}

private struct CameraRecordingActivityView: UIViewControllerRepresentable {
    let recordings: [CameraLocalRecording]
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: recordings.map(\.fileURL),
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion(completed)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
#endif

/// Construct the initial session lazily inside one StateObject. Eagerly making
/// a session in the View initializer creates discarded players whenever an
/// environment value (including minimized state or the badge count) changes.
@MainActor
private final class CameraViewerPlaybackOwner: ObservableObject {
    let initialSession: CameraGroupSession
    let group: CameraGroupPlayback
    var objectWillChange: ObservableObjectPublisher { group.objectWillChange }

    // Playback cleanup is explicit on close; SwiftUI can release this holder
    // outside a Swift task, including on the iOS 26 runtime.
    nonisolated deinit {}

    init(camera: CameraVideoDevice, quality: CameraLiveQualitySelection, client: HomeBaseWebSocketClient) {
        initialSession = CameraGroupSession(camera: camera, client: client, quality: quality)
        group = CameraGroupPlayback(client: client, initialSession: initialSession)
    }
}

private struct CameraFullScreenCameraContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(iOS)
    @Environment(\.cameraPictureInPicture) private var pictureInPicture
    @Environment(\.cameraViewerPresentation) private var retainedViewer
    @Environment(\.cameraViewerIsMinimized) private var phoneViewerMinimized
    @StateObject private var externalDisplay = CameraExternalDisplayPresentation()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif
    let client: HomeBaseWebSocketClient
    let viewerID: UUID
    let screenSelection: CameraScreenSelection
    let access: CameraAccessPresentation
    @StateObject private var playbackOwner: CameraViewerPlaybackOwner
    private var initialSession: CameraGroupSession { playbackOwner.initialSession }
    private var group: CameraGroupPlayback { playbackOwner.group }
    @State private var focusedCameraID: String?
    private var presentation: CameraGroupPresentation {
        CameraGroupPresentation(sessions: group.sessions, focusedCameraID: focusedCameraID)
    }
    private var primary: CameraGroupSession { presentation.focusedSession ?? group.sessions.first ?? initialSession }
    private var device: HBTopologyDeviceDescriptor { primary.camera.device }
    private var controlsModel: LiveDeviceControlsModel { primary.controls }
    private var playbackController: CameraLivePlaybackController { primary.playback }
    private var selectedQuality: CameraLiveQualitySelection {
        get { presentation.focusedSession?.quality ?? group.quality }
        nonmutating set {
            if let focused = presentation.focusedSession { focused.setQuality(newValue) }
            else { group.setQuality(newValue) }
        }
    }
    @Binding var panel: CameraPlayerPanel
    @Binding var controlsVisible: Bool
    let initialPosition: CameraSwitchPosition
    let cameraPicker: CameraPickerModel
    let selectCamera: (CameraVideoDevice, CameraSwitchPosition) -> Void
    let retainCamera: (CameraVideoDevice, CameraLiveQualitySelection) -> Void
    @State private var initialPositionApplied = false
    @State private var cameraPickerVisible = false
    @State private var switchingCamera = false
    @State private var cameraSwitchTask: Task<Void, Never>?
    @State private var cameraSwitchError: String?
    private var liveVideoState: CameraLiveVideoModel.State { primary.liveState }
    @State private var timelineResumeAfterSeek = false
    @State private var historyBookmark: CameraSwitchPosition?
    @State private var historyRestoreTask: Task<Void, Never>?
    @State private var historyRestoreGeneration = UUID()
    @State private var historyBookmarkError: String?
    @State private var s3Destination: CameraS3Destination?
#if os(iOS)
    private var recordingControllers: [CameraLocalRecordingController] {
        group.sessions.map(\.recordingController)
    }

    private var pendingRecordings: [CameraLocalRecording] {
        recordingControllers.compactMap(\.pendingRecording)
    }

    private var pendingRecordingIDs: [UUID] {
        pendingRecordings.map(\.id)
    }

    private var recordingExportTrigger: CameraRecordingExportTrigger {
        CameraRecordingExportTrigger(
            recordingIDs: pendingRecordingIDs,
            isBusy: recordingIsBusy,
            errorMessage: recordingErrorMessage
        )
    }

    private var recordingIsActive: Bool {
        recordingControllers.contains(where: \.isRecording)
    }

    private var recordingHasStarted: Bool {
        recordingControllers.contains { $0.state == .recording }
    }

    private var recordingIsBusy: Bool {
        recordingControllers.contains {
            $0.state == .finalizing || $0.state == .exporting
        }
    }

    private var recordingLocksStreamConfiguration: Bool {
        recordingControllers.contains(where: \.locksStreamConfiguration)
    }

    private var recordingStartedAt: Date? {
        recordingControllers.compactMap(\.recordingStartedAt).min()
    }

    private var recordingErrorMessage: String? {
        recordingControllers.compactMap(\.errorMessage).first
    }

    private var successfulRecordingExportCount: Int {
        recordingControllers.reduce(0) { $0 + $1.successfulExportCount }
    }

    @State private var recordingExportPresentation:
        CameraRecordingExportPresentation?
    @State private var recordingSystemPresentation: CameraRecordingSystemPresentation?
#endif
    @StateObject private var toolbarScrubRelay = CameraToolbarScrubRelay()

    init(
        device: HBTopologyDeviceDescriptor,
        quality: CameraLiveQualitySelection,
        client: HomeBaseWebSocketClient,
        viewerID: UUID,
        screenSelection: CameraScreenSelection,
        access: CameraAccessPresentation,
        initialPosition: CameraSwitchPosition,
        cameraPicker: CameraPickerModel,
        panel: Binding<CameraPlayerPanel>,
        controlsVisible: Binding<Bool>,
        selectCamera: @escaping (CameraVideoDevice, CameraSwitchPosition) -> Void,
        retainCamera: @escaping (CameraVideoDevice, CameraLiveQualitySelection) -> Void
    ) {
        self.client = client
        self.viewerID = viewerID
        self.screenSelection = screenSelection
        self.access = access
        self.initialPosition = initialPosition
        self.cameraPicker = cameraPicker
        self.selectCamera = selectCamera
        self.retainCamera = retainCamera
        _panel = panel
        _controlsVisible = controlsVisible
        let fallbackQualities = quality.requestedQuality.map { Set([$0]) }
            ?? Set(HBCameraLiveQuality.allCases)
        let camera = CameraVideoDevice(device: device,
            capability: CameraLiveVideoCapability(metadata: device.metadata) ?? .init(
                qualities: fallbackQualities,
                supportsDefaultQuality: quality == .automatic
            ))
        _playbackOwner = StateObject(wrappedValue: CameraViewerPlaybackOwner(
            camera: camera, quality: quality, client: client))
    }

    private var cameraPresentation: some View {
        liveVideo
        .onAppear {
            reconcilePhonePlayback()
            applyInitialPositionIfAuthorized()
        }
        .onDisappear {
            cancelHistoryRestore()
            cameraSwitchTask?.cancel(); cameraSwitchTask = nil
            stopLiveCameraGestures()
#if os(iOS)
            if !pendingRecordings.isEmpty {
                discardRecordingExport()
            }
#endif
#if os(iOS)
            if retainedViewer?.request?.id == viewerID, externalDisplay.isOutputActive {
                group.suspendForPhone(stopRecording: scenePhase != .active)
            } else { group.deactivate() }
#else
            group.deactivate()
#endif
        }
        .onChange(of: cameraControlsEnabled) { _, enabled in
            if !enabled { stopLiveCameraGestures() }
        }
        .onChange(of: group.sessions.map(\.id)) { _, _ in
            // Removing the focused camera (or collapsing to one) ends only the
            // presentation override. Never change the selection to enter/exit it.
            if presentation.focusedSession == nil { focusedCameraID = nil }
        }
        .onChange(of: panelAvailability, initial: true) { _, availability in
            panel = availability.validated(panel)
        }
        .onChange(of: isShowingVideo, initial: true) { _, showsVideo in
            if !showsVideo {
                stopLiveCameraGestures()
            }
        }
        .onChange(
            of: CameraLiveVideoLifecycle.isSuspended(
                in: scenePhase,
                isStreamEnabled: access.canStream
            ) || isPhoneViewerMinimized,
            initial: true
        ) { _, _ in
            // This reconciliation is synchronous. A superseded SwiftUI task
            // can therefore never apply an older foreground/background intent.
            reconcilePhonePlayback()
        }
        .onChange(of: scenePhase) { _, _ in
            // A minimized viewer is already phone-suspended, so the combined
            // flag above does not change when the app subsequently backgrounds.
            // Apply the background recording policy even in that case.
            if isPhoneViewerMinimized { reconcilePhonePlayback() }
        }
        .onChange(of: access.session?.unlockedCredentials) { _, _ in
            if access.isAuthorized {
                group.refreshHistoryAccess(access.session)
            }
        }
        .onChange(of: availableQualities) { _, qualities in
            guard !qualities.contains(selectedQuality),
                  let fallbackQuality = qualities.first else { return }
            selectedQuality = fallbackQuality
        }
    }

    private func reconcilePhonePlayback() {
        if isPhoneViewerMinimized || CameraLiveVideoLifecycle.isSuspended(in: scenePhase, isStreamEnabled: access.canStream) {
            group.suspendForPhone(stopImmediately: scenePhase == .background || !access.canStream,
                stopRecording: scenePhase != .active || !access.isAuthorized)
        } else {
            group.resume()
            group.activateResources(access: access.session)
        }
    }

    @ViewBuilder
    private var recordingPresentation: some View {
#if os(iOS)
        cameraPresentation
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            group.sessions.forEach { $0.playback.trimBufferForMemoryPressure() }
        }
        .sensoryFeedback(
            .success,
            trigger: successfulRecordingExportCount
        )
        .sensoryFeedback(
            .impact(weight: .medium),
            trigger: recordingHasStarted
        ) { wasRecording, isRecording in
            !wasRecording && isRecording
        }
        .alert(
            "Recording Error",
            isPresented: recordingErrorIsPresented
        ) {
            Button("OK") {
                recordingControllers.forEach { $0.dismissError() }
            }
        } message: {
            Text(recordingErrorMessage ?? "Unknown error")
        }
        .sheet(item: $recordingSystemPresentation) { presentation in
            switch presentation {
            case .files(let recordings):
                CameraRecordingDocumentPicker(recordings: recordings) { saved in
                    finishSystemRecordingExport(saved: saved)
                }
                .ignoresSafeArea()
            case .share(let recordings):
                CameraRecordingActivityView(recordings: recordings) { shared in
                    finishSystemRecordingExport(saved: shared)
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background,
               !pendingRecordings.isEmpty {
                discardRecordingExport()
            }
        }
#else
        cameraPresentation
#endif
    }

    var body: some View {
        recordingPresentation
        .sheet(item: $s3Destination) { destination in
            if let session = access.session {
                CameraS3CredentialsView(access: session, destination: destination)
            }
        }
        .onChange(of: access.isAuthorized) { _, allowed in
            if !allowed {
                group.suspendResources(stopImmediately: true)
                group.sessions.forEach { $0.playback.revokeCameraAccess() }
                s3Destination = nil
                cameraPickerVisible = false
                cameraSwitchTask?.cancel(); cameraSwitchTask = nil
                switchingCamera = false
            } else { applyInitialPositionIfAuthorized() }
        }
        .alert("Playback Unavailable", isPresented: Binding(
            get: {
                access.isUnlocked
                    && (historyBookmarkError != nil
                        || playbackController.errorMessage != nil)
            },
            set: {
                if !$0 {
                    historyBookmarkError = nil
                    playbackController.dismissError()
                }
            }
        )) {
            Button("OK") {
                historyBookmarkError = nil
                playbackController.dismissError()
            }
        } message: {
            Text(
                historyBookmarkError
                    ?? playbackController.errorMessage
                    ?? "Unknown error"
            )
        }
        .alert(cameraSwitchError != nil ? "Could Not Switch Camera" : "Camera Control Failed", isPresented: Binding(
            get: { access.isUnlocked && (cameraSwitchError != nil || group.error != nil) }, set: { if !$0 { cameraSwitchError = nil; group.error = nil } }
        )) {
            Button("OK") { cameraSwitchError = nil; group.error = nil }
        } message: {
            Text(cameraSwitchError ?? group.error ?? "Unknown error")
        }
        .allowsHitTesting(access.isUnlocked)
        .accessibilityHidden(!access.isUnlocked)
        .overlay {
            if !access.isUnlocked {
                CameraAccessLockedView(access: access)
            }
        }
        .toolbar { cameraToolbar }
        .modifier(CameraTransparentToolbar())
        .modifier(CameraPlayerChromeVisibility(
            isVisible: !access.isUnlocked || visiblePlayerControls,
            hidesNavigationBar: hidesNavigationBarInCompactHeight
        ))
        // Animate the bars and the media canvas's safe-area policy together.
        .animation(reduceMotion ? nil : .snappy, value: controlsVisible)
#if os(iOS)
        .onChange(of: externalStreamingCameraCount, initial: true) { _, count in
            retainedViewer?.updateExternalOutput(viewerID: viewerID, cameraCount: count)
        }
        .modifier(CameraPiPViewerRegistration(id: viewerID,
            cameraIDs: Set(group.sessions.map(\.camera.id)),
            owner: screenSelection,
            showControls: {
                if retainedViewer?.request?.id == viewerID { retainedViewer?.restore() }
                // If PiP restores a different, currently faded-out pane, reveal
                // its original position in the group rather than hiding it.
                if let focusedCameraID,
                   pictureInPicture?.restoration?.session.camera.id != focusedCameraID {
                    self.focusedCameraID = nil
                }
                controlsVisible = true
            }))
        .background {
            CameraExternalDisplayBridge(group: group,
                isVisible: access.isAuthorized, presentation: externalDisplay,
                retainWhenCovered: retainedViewer?.request?.id == viewerID)
                .frame(width: 0, height: 0)
            CameraToolbarScrubBridge(
                isEnabled: verticalSizeClass == .compact
                    && timelinePresented
                    && panel != .ptz
                    && playbackActionsEnabled,
                relay: toolbarScrubRelay
            )
            .frame(width: 0, height: 0)
        }
#endif
    }

    private var liveVideo: some View {
        ZStack {
        CameraGroupVideo(group: group, cameraControlsEnabled: cameraControlsEnabled,
                controlsVisible: visiblePlayerControls,
                isAccessAllowed: access.isAuthorized,
                allowsPictureInPicture: playbackActionsEnabled,
                focusedCameraID: presentation.focusedSession?.id,
                onFullScreen: focusCamera,
                onSingleTap: toggleControls)

            if visiblePlayerControls && panel == .ptz && panelAvailability.enablesPTZ {
                CameraDetailControlsOverlay(model: controlsModel)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if timelineVisible, panel != .ptz,
               let timelineSession,
               let metadata = CameraPlaybackHistoryAvailability.metadata(
                   in: timelineSession.controls.deviceMetadata
               ) {
                CameraTimelinePlacement(
                    edge: .top
                ) {
                    CameraTimelinePanel(
                        isPresented: timelinePresented,
                        isActive: timelineVisible
                    ) {
                        CameraHistoryTimeline(makeTransport: {
                            await CameraHistorySources.thumbnails(metadata: metadata, client: client, credentials: access.session?.unlockedCredentials)
                        }, source: .init(metadata: metadata, credentials: access.session?.unlockedCredentials),
                            cameraID: metadata.cameraID, timeZone: playbackTimeZone,
                            position: {
                                group.active
                                    ? group.positionForSwitch()
                                    : timelineSession.playback.positionForCameraSwitch(
                                        metadata: timelineSession.controls.deviceMetadata
                                    )
                            },
                            onBegin: {
                                guard playbackActionsEnabled else { return }
                                cancelHistoryRestore()
                                timelineResumeAfterSeek = !isPaused
                                stopLiveCameraGestures()
                                if !isPaused, canControlPlayback {
                                    if group.active { group.togglePause() } else { playbackController.togglePause() }
                                }
                            }, onSeek: { date in
                                guard playbackActionsEnabled else { return }
                                if group.active {
                                    group.seek(to: date)
                                    if timelineResumeAfterSeek, group.isPaused { group.togglePause() }
                                } else { playbackController.seek(to: date, paused: !timelineResumeAfterSeek) }
                                timelineResumeAfterSeek = false
                            }, interactionEnabled: playbackActionsEnabled,
                            onCancel: {
                                if scenePhase == .active, playbackActionsEnabled,
                                   timelineResumeAfterSeek, isPaused, canControlPlayback {
                                    if group.active { group.togglePause() } else { playbackController.togglePause() }
                                }
                                timelineResumeAfterSeek = false
                            }, toolbarScrubRelay: toolbarScrubRelay)
                            .id(metadata.cameraID)
                    }
                }
            }
        }
        .overlayPreferenceValue(CameraTimelineBoundsPreference.self) { timelineBounds in
            if visiblePlayerControls {
                if let destination = lockedS3Destination, access.session != nil {
                    CameraPlayerPanelPlacement(panel: panel, timelineBounds: timelineBounds, leading: true) {
                        CameraS3PadlockButton { s3Destination = destination }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(reduceMotion ? nil : .snappy, value: panel)
        .animation(reduceMotion ? nil : .snappy, value: timelineVisible)
        .accessibilityActions {
            Button("Toggle player controls", action: toggleControls)
        }
    }

    private func closeViewer() {
        if presentation.focusedSession != nil {
            setCameraFocus(nil)
            return
        }
#if os(iOS)
        pictureInPicture?.unregisterViewer(viewerID)
        if retainedViewer?.request?.id == viewerID {
            retainedViewer?.close()
            return
        }
#endif
        dismiss()
    }

    private func focusCamera(_ id: String) {
        guard access.isUnlocked, !switchingCamera,
              group.hasMultipleCameras, group.sessions.contains(where: { $0.id == id }) else { return }
        setCameraFocus(id)
    }

    private func setCameraFocus(_ id: String?) {
        stopLiveCameraGestures()
        withAnimation(reduceMotion ? nil : .snappy) {
            focusedCameraID = id
            panel = .off
            controlsVisible = true
        }
    }

    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
#if os(iOS)
        if toolbarArrangement.navigationItemsInBottomToolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                viewerDismissalControls
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
        } else {
            ToolbarItemGroup(placement: .navigation) {
                viewerDismissalControls
            }
        }
#else
        ToolbarItem(placement: .navigation) {
            CameraPlayerCloseButton(returnsToCameras: presentation.focusedSession != nil, action: closeViewer)
        }
#endif

#if os(iOS)
        if access.isUnlocked {
            if toolbarArrangement.usesCompactWidthLayout {
                if !recordingLocksStreamConfiguration {
                    if toolbarArrangement.playbackControlsInOverflow {
                        ToolbarItemGroup(placement: .secondaryAction) {
                            backControl.disabled(!playbackActionsEnabled)
                            pauseControl.disabled(!playbackActionsEnabled)
                            forwardControl.disabled(!playbackActionsEnabled)
                        }
                        .cameraPlaybackHorizontalAxis()
                    }
                    ToolbarItem(placement: .bottomBar) {
                        CameraLiveModeButton(
                            isLive: isLive,
                            showsTitle: false,
                            action: toggleLiveHistory
                        )
                            .disabled(!playbackActionsEnabled || (isLive && !canControlPlayback))
                    }
                    .cameraPlaybackHorizontalAxis()
                    if !isLive {
                        ToolbarSpacer(.fixed, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            playbackSpeedControl.disabled(!playbackActionsEnabled)
                        }
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)

                if toolbarArrangement.configurationControlsInBottomTrailing {
                    if toolbarArrangement.recordInBottomTrailing {
                        if recordingHasStarted {
                            ToolbarItem(placement: .bottomBar) {
                                recordingElapsedTimeLabel
                            }
                            .sharedBackgroundVisibility(.hidden)
                        }
                        ToolbarItem(placement: .bottomBar) { recordingControl }
                    }
                    if showsQualityControl {
                        ToolbarItem(placement: .bottomBar) { qualityControl }
                    }
                    if let dayNightModeControl {
                        ToolbarItem(placement: .bottomBar) {
                            dayNightModeControl
                        }
                    }
                    if let privacyControl {
                        ToolbarItem(placement: .bottomBar) { privacyControl }
                    }
                }
                if toolbarArrangement.playbackControlsInBottomTrailing,
                   !recordingLocksStreamConfiguration {
                    ToolbarItemGroup(placement: .bottomBar) {
                        backControl.disabled(!playbackActionsEnabled)
                        pauseControl
                            .labelStyle(.iconOnly)
                            .disabled(!playbackActionsEnabled)
                        forwardControl.disabled(!playbackActionsEnabled)
                    }
                    .cameraPlaybackHorizontalAxis()
                }
            } else {
                if !recordingLocksStreamConfiguration {
                    ToolbarItemGroup(placement: .bottomBar) {
                        backControl.disabled(!playbackActionsEnabled)
                        pauseControl
                            .labelStyle(.iconOnly)
                            .disabled(!playbackActionsEnabled)
                        forwardControl.disabled(!playbackActionsEnabled)
                    }
                    .cameraPlaybackHorizontalAxis()
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        CameraLiveModeButton(
                            isLive: isLive,
                            showsTitle: true,
                            action: toggleLiveHistory
                        )
                            .disabled(!playbackActionsEnabled || (isLive && !canControlPlayback))
                    }
                    .cameraPlaybackHorizontalAxis()
                    if !isLive {
                        ToolbarSpacer(.fixed, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            playbackSpeedControl.disabled(!playbackActionsEnabled)
                        }
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)

                if toolbarArrangement.recordInBottomTrailing {
                    if recordingHasStarted {
                        ToolbarItem(placement: .bottomBar) {
                            recordingElapsedTimeLabel
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarItem(placement: .bottomBar) { recordingControl }
                    if hasLiveToolbarControls {
                        ToolbarSpacer(.fixed, placement: .bottomBar)
                    }
                }
                if showsQualityControl {
                    ToolbarItem(placement: .bottomBar) { qualityControl }
                }
                if let dayNightModeControl {
                    ToolbarItem(placement: .bottomBar) {
                        dayNightModeControl
                    }
                }
                if let privacyControl {
                    ToolbarItem(placement: .bottomBar) { privacyControl }
                }
            }

            if toolbarArrangement.navigationItemsInBottomToolbar {
                if !recordingLocksStreamConfiguration {
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        cameraPickerControl
                    }
                }
            } else {
                if toolbarArrangement.recordInTrailingNavigationBar {
                    if recordingHasStarted {
                        ToolbarItem(placement: .primaryAction) {
                            recordingElapsedTimeLabel
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        recordingControl
                    }
                }
                if !recordingLocksStreamConfiguration {
                    if toolbarArrangement.recordInTrailingNavigationBar {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        cameraPickerControl
                    }
                }
            }
        }
#else
        if access.isUnlocked {
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItemGroup(placement: .navigation) {
                backControl.disabled(!playbackActionsEnabled)
                pauseControl
                    .labelStyle(.iconOnly)
                    .disabled(!playbackActionsEnabled)
                forwardControl.disabled(!playbackActionsEnabled)
            }
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) {
                CameraLiveModeButton(
                    isLive: isLive,
                    showsTitle: true,
                    action: toggleLiveHistory
                )
                    .disabled(!playbackActionsEnabled || (isLive && !canControlPlayback))
            }
            if !isLive {
                ToolbarSpacer(.fixed, placement: .navigation)
                ToolbarItem(placement: .navigation) {
                    playbackSpeedControl.disabled(!playbackActionsEnabled)
                }
            }

            if showsQualityControl {
                ToolbarItem(placement: .primaryAction) { qualityControl }
            }
            if let dayNightModeControl {
                ToolbarItem(placement: .primaryAction) {
                    dayNightModeControl
                }
            }
            if let privacyControl {
                ToolbarItem(placement: .primaryAction) {
                    privacyControl
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                cameraPickerControl
            }
        }
#endif
    }

    private var cameraPickerControl: some View {
        Button {
            group.beginCameraSelection()
            cameraPickerVisible = true
        } label: {
            if switchingCamera { ProgressView() }
        else { Image(systemName: "video") }
        }
        .accessibilityLabel("Choose camera")
        .accessibilityValue(group.active ? group.sessions.map { $0.camera.device.displayName }.joined(separator: ", ") : device.displayName)
        .disabled(switchingCamera || group.resolvingTime)
        .popover(isPresented: $cameraPickerVisible, attachmentAnchor: .rect(.bounds)) {
            CameraPickerPopover(model: cameraPicker,
                selectedIDs: Set(group.active ? group.sessions.map(\.id) : [device.identifier]),
                multiple: group.multipleSelectionEnabled, toggleMultiple: setMultiple,
                canSelect: { !group.multipleSelectionEnabled || group.canToggle($0) },
                select: {
                    guard playbackActionsEnabled else { return }
                    if group.multipleSelectionEnabled {
                        stopLiveCameraGestures()
                        group.toggle($0)
                        if !group.hasMultipleCameras { retainCamera(primary.camera, primary.quality) }
                    } else { switchCamera($0) }
                })
                .disabled(switchingCamera || group.resolvingTime)
        }
    }

    private func setMultiple(_ enabled: Bool) {
        guard access.isUnlocked, enabled != group.multipleSelectionEnabled, !switchingCamera else { return }
#if os(iOS)
        guard !recordingLocksStreamConfiguration else { return }
#endif
        stopLiveCameraGestures()
        withAnimation(.snappy) { group.setMultipleSelection(enabled) }
        if !group.active { retainCamera(primary.camera, primary.quality) }
    }

    private func switchCamera(_ camera: CameraVideoDevice) {
        cameraPickerVisible = false
        guard access.isUnlocked, camera.id != device.identifier, !switchingCamera else { return }
        cancelHistoryRestore()
        let departure = CameraPlaybackHistoryAvailability.isAvailable(in: camera.device.metadata)
            ? playbackController.positionForCameraSwitch(metadata: controlsModel.deviceMetadata) : .live
        stopLiveCameraGestures()
        switchingCamera = true
        cameraSwitchTask = Task {
            defer { switchingCamera = false }
            do {
#if os(iOS)
                // A camera change must never mix cameras in one local movie.
                await stopRecording()
                while recordingControllers.contains(where: {
                    $0.state == .finalizing
                }) {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard recordingErrorMessage == nil else { return }
                guard pendingRecordings.isEmpty else { return }
#endif
                let destination: CameraSwitchPosition
                if case .relative = departure {
                    let transport = await client.makeHistoryTransport()
                    do { destination = try await departure.resolve(using: transport) }
                    catch { await transport.close(); throw error }
                    await transport.close()
                } else { destination = departure }
                try Task.checkCancellation()
                guard access.session?.isUnlocked != false else { return }
                selectCamera(camera, destination)
            } catch is CancellationError {} catch {
                cameraSwitchError = error.localizedDescription
            }
        }
    }

#if os(iOS)
    private var recordingControl: some View {
        recordingButton
            .modifier(CameraRecordingControlStyle(
                isProminent: recordingIsActive
            ))
            .popover(
                item: $recordingExportPresentation,
                attachmentAnchor: .rect(.bounds)
            ) { presentation in
                CameraRecordingExportPopover(
                    recordings: presentation.recordings,
                    saveToPhotos: saveRecordingToPhotos,
                    saveToFiles: {
                        presentSystemRecordingExport(
                            .files(presentation.recordings)
                        )
                    },
                    share: {
                        presentSystemRecordingExport(
                            .share(presentation.recordings)
                        )
                    },
                    delete: discardRecordingExport
                )
                .presentationCompactAdaptation(.popover)
                .interactiveDismissDisabled()
            }
            .task(id: recordingExportTrigger) {
                guard !recordingExportTrigger.recordingIDs.isEmpty,
                      !recordingExportTrigger.isBusy,
                      recordingExportTrigger.errorMessage == nil,
                      recordingExportPresentation == nil,
                      recordingSystemPresentation == nil
                else { return }
                // In regular height the primary-action toolbar is rebuilt
                // when the neighboring camera control disappears. Present
                // only after this placement's new anchor has mounted.
                await Task.yield()
                presentRecordingExport()
            }
    }

    private var recordingButton: some View {
        Button {
            if !pendingRecordings.isEmpty {
                presentRecordingExport()
            } else if recordingIsActive {
                Task {
                    await stopRecording()
                }
            } else {
                guard cameraControlsEnabled else { return }
                Task {
                    await startRecording()
                }
            }
        } label: {
            recordingButtonLabel
        }
        .tint(.red)
        .disabled(
            recordingIsBusy
                || (!recordingIsActive
                    && pendingRecordings.isEmpty
                    && (presentation.visibleSessions.isEmpty
                        || !presentation.visibleSessions.allSatisfy({ $0.recordingController.isStreamAvailable })
                        || !cameraControlsEnabled))
        )
        .accessibilityLabel(
            recordingIsActive
                ? "Stop recording"
                : "Record video"
        )
        .accessibilityValue(recordingAccessibilityValue)
    }

    @ViewBuilder
    private var recordingButtonLabel: some View {
        if recordingIsBusy || (recordingIsActive && !recordingHasStarted) {
            ProgressView()
        } else if recordingHasStarted {
            Image(systemName: "stop.fill")
        } else {
            Image(systemName: "record.circle")
        }
    }

    private var recordingElapsedTimeLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = recordingStartedAt.map {
                max(0, context.date.timeIntervalSince($0))
            } ?? 0
            let timer = Duration.seconds(elapsed).formatted(
                .time(pattern: .hourMinuteSecond(padHourToLength: 2))
            )
            Text(timer)
                .font(.system(.callout, design: .monospaced, weight: .bold))
                .foregroundStyle(.red)
                .accessibilityLabel("Recording duration")
                .accessibilityValue(timer)
        }
    }

    private var recordingAccessibilityValue: String {
        if recordingControllers.contains(where: { $0.state == .exporting }) {
            return "Exporting recordings"
        }
        if recordingControllers.contains(where: { $0.state == .finalizing }) {
            return "Finishing recordings"
        }
        if recordingHasStarted { return "Recording" }
        if recordingIsActive { return "Starting recording" }
        if recordingErrorMessage != nil { return "Recording unavailable" }
        return "Not recording"
    }

    private func startRecording() async {
        for session in presentation.visibleSessions {
            await session.recordingController.start(
                suggestedFilename: session.camera.device.displayName
            )
        }
    }

    private func stopRecording() async {
        let tasks = recordingControllers
            .filter(\.isRecording)
            .map { controller in
                Task { @MainActor in
                    await controller.stop()
                }
            }
        for task in tasks {
            await task.value
        }
    }

    private func saveRecordingToPhotos() {
        recordingExportPresentation = nil
        Task {
            for controller in recordingControllers
            where controller.pendingRecording != nil {
                guard await controller.savePendingRecordingToPhotos() else {
                    return
                }
            }
        }
    }

    private func presentSystemRecordingExport(
        _ presentation: CameraRecordingSystemPresentation
    ) {
        recordingExportPresentation = nil
        Task { @MainActor in
            await Task.yield()
            recordingSystemPresentation = presentation
        }
    }

    private func finishSystemRecordingExport(saved: Bool) {
        recordingSystemPresentation = nil
        if saved {
            recordingControllers.forEach { $0.completePendingExport() }
        } else if !pendingRecordings.isEmpty {
            Task { @MainActor in
                await Task.yield()
                presentRecordingExport()
            }
        }
    }

    private func discardRecordingExport() {
        recordingExportPresentation = nil
        recordingSystemPresentation = nil
        recordingControllers.forEach { $0.discardPendingRecording() }
    }

    private func presentRecordingExport() {
        let recordings = pendingRecordings
        guard !recordings.isEmpty else { return }
        recordingExportPresentation = CameraRecordingExportPresentation(
            recordings: recordings
        )
    }

    private var recordingErrorIsPresented: Binding<Bool> {
        Binding(
            get: { access.isUnlocked && recordingErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    recordingControllers.forEach { $0.dismissError() }
                }
            }
        )
    }
#endif

    private var panelAvailability: CameraPlayerPanelAvailability {
        CameraPlayerPanelAvailability(
            historyAvailable: timelineSession != nil,
            ptzSupported: CameraDetailControlSet(controls: controlsModel.controls).hasPTZ,
            isLive: cameraControlsEnabled, isMultiple: presentation.showsMultipleCameras)
    }

    private var timelineVisible: Bool { !isLive }
    private var timelinePresented: Bool { timelineVisible && visiblePlayerControls }
    private var timelineSession: CameraGroupSession? {
        if let focused = presentation.focusedSession { return focused.historyAvailable ? focused : nil }
        if group.active { return group.historySourceSession }
        return primary.historyAvailable ? primary : nil
    }

#if os(iOS)
    private var toolbarArrangement: CameraToolbarArrangement {
        CameraToolbarArrangement(
            isLive: isLive,
            compactWidth: horizontalSizeClass == .compact,
            compactHeight: verticalSizeClass == .compact
        )
    }

    private var hidesNavigationBarInCompactHeight: Bool {
        toolbarArrangement.navigationItemsInBottomToolbar
    }
#else
    private var hidesNavigationBarInCompactHeight: Bool { false }
#endif

    private var playbackPosition: CameraSwitchPosition {
        group.active
            ? group.positionForSwitch()
            : playbackController.positionForCameraSwitch(
                metadata: controlsModel.deviceMetadata
            )
    }

    private func toggleLiveHistory() {
        guard playbackActionsEnabled else { return }
        if isLive {
            enterHistory()
        } else {
            leaveHistory()
        }
    }

    private func enterHistory() {
        guard isLive, canControlPlayback else { return }
        stopLiveCameraGestures()
        cancelHistoryRestore()

        // Entering History for the first time freezes the current live edge.
        // A later entry starts there too, then replaces it with the frozen
        // bookmark as soon as any source-camera clock lookup completes.
        if group.active {
            group.togglePause()
        } else {
            playbackController.togglePause()
        }

        guard let historyBookmark, historyBookmark != .live else { return }
        restoreHistoryBookmark(historyBookmark.paused)
    }

    private func leaveHistory() {
        guard !isLive else { return }
        cancelHistoryRestore()
        let departure = playbackPosition.paused
        if departure != .live {
            historyBookmark = departure
        }
        stopLiveCameraGestures()
        if group.active {
            group.goLive()
        } else {
            playbackController.goLive()
        }
    }

    private func restoreHistoryBookmark(_ position: CameraSwitchPosition) {
        switch position.paused {
        case .live:
            return
        case .canonical:
            applyHistoryBookmark(position.paused)
        case .relative:
            let generation = UUID()
            historyRestoreGeneration = generation
            historyRestoreTask = Task {
                let transport = await client.makeHistoryTransport()
                let resolved: CameraSwitchPosition
                do {
                    resolved = try await position.paused.resolve(
                        using: transport
                    )
                } catch is CancellationError {
                    await transport.close()
                    return
                } catch {
                    await transport.close()
                    guard historyRestoreGeneration == generation else { return }
                    historyRestoreTask = nil
                    historyBookmarkError = error.localizedDescription
                    return
                }
                await transport.close()
                guard !Task.isCancelled,
                      historyRestoreGeneration == generation,
                      !isLive else { return }
                applyHistoryBookmark(resolved.paused)
                historyRestoreTask = nil
            }
        }
    }

    private func applyHistoryBookmark(_ position: CameraSwitchPosition) {
        guard case .canonical(let time, _) = position else { return }
        let date = Date(timeIntervalSince1970: time)
        historyBookmark = position.paused
        if group.active {
            group.seek(to: date, paused: true)
        } else {
            playbackController.seek(to: date, paused: true)
        }
    }

    private func cancelHistoryRestore() {
        historyRestoreGeneration = UUID()
        historyRestoreTask?.cancel()
        historyRestoreTask = nil
    }

    private func applyInitialPositionIfAuthorized() {
        guard access.isAuthorized, !initialPositionApplied else { return }
        initialPositionApplied = true
        playbackController.applyCameraSwitch(initialPosition)
    }

    private var playbackControlsPresentation: CameraPlaybackControlsPresentation {
        CameraPlaybackControlsPresentation(isLive: isLive,
            timelineVisible: timelineVisible)
    }

    private var isPhoneViewerMinimized: Bool {
#if os(iOS)
        phoneViewerMinimized && retainedViewer?.request?.id == viewerID
#else
        false
#endif
    }

#if os(iOS)
    private var externalStreamingCameraCount: Int {
        externalDisplay.isOutputActive ? group.sessions.filter(group.showsVideo).count : 0
    }

    private var canMinimizeViewer: Bool {
        access.isUnlocked && externalStreamingCameraCount > 0 && retainedViewer?.request?.id == viewerID
    }

    @ViewBuilder
    private var viewerDismissalControls: some View {
        CameraPlayerCloseButton(returnsToCameras: presentation.focusedSession != nil,
            usesSystemCloseRole: !canMinimizeViewer, action: closeViewer)
        if canMinimizeViewer {
            Button("Minimize Video", systemImage: "chevron.down") {
                stopLiveCameraGestures()
                retainedViewer?.minimize(viewerID: viewerID,
                    externalOutputActive: externalDisplay.isOutputActive)
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("camera.minimize")
            .accessibilityHint("Keeps video on the external display. Return to Cameras to restore this viewer.")
        }
    }
#endif

    private var cameraControlsEnabled: Bool { access.isUnlocked && !isPhoneViewerMinimized && !switchingCamera && playbackControlsPresentation.cameraControlsEnabled }

    private var playbackActionsEnabled: Bool {
#if os(iOS)
        access.isUnlocked && !isPhoneViewerMinimized && !switchingCamera && !recordingLocksStreamConfiguration
#else
        access.isUnlocked && !switchingCamera
#endif
    }

    private var isLive: Bool { group.active ? group.isLive : playbackController.isLive }
    private var isPaused: Bool { group.active ? group.isPaused : playbackController.isPaused }
    private var canControlPlayback: Bool { group.active ? group.canControlPlayback : playbackController.canControlPlayback }
    private var activeControls: LiveDeviceControlsModel { presentation.showsMultipleCameras ? group.sharedControls : controlsModel }
    private var isShowingVideo: Bool {
        if let focused = presentation.focusedSession { return group.showsVideo(focused) }
        return group.active ? group.allPanesShowVideo : interactionPresentation.showsVideo
    }
    private var visiblePlayerControls: Bool {
        access.isUnlocked
            && interactionPresentation.controlsVisible(requested: controlsVisible)
    }

    private var lockedS3Destination: CameraS3Destination? {
        for session in presentation.visibleSessions {
            let destination = CameraS3Destination.advertised(in: session.controls.deviceMetadata)
            if CameraS3AccessPolicy.showsPadlock(isLive: isLive,
                showsVideo: group.showsVideo(session), historyState: session.playback.historyState,
                resolvingTime: group.resolvingTime, destination: destination,
                unlockedDestinationID: access.session?.unlockedCredentials?.destinationID) {
                return destination
            }
        }
        return nil
    }

    private var playbackTimeZone: TimeZone {
        CameraHistoryTimestamp.timeZone(
            in: timelineSession?.controls.deviceMetadata
                ?? controlsModel.deviceMetadata
        )
    }

    private var playbackSpeedControl: some View {
        CameraPlaybackSpeedMenu(speed: Binding(
            get: { group.active ? group.playbackSpeed : playbackController.playbackSpeed },
            set: { speed in
                guard !isLive, playbackActionsEnabled else { return }
                if group.active { group.setPlaybackSpeed(speed) }
                else { playbackController.setPlaybackSpeed(speed) }
            }
        ))
        .disabled(isLive || !canControlPlayback || group.resolvingTime)
    }

    private var backControl: some View {
        Button("Back 30 seconds", systemImage: "gobackward.30") {
            guard playbackActionsEnabled else { return }
            stopLiveCameraGestures()
            if group.active { group.seek(by: -30) } else { playbackController.seek(by: -30) }
        }
        .disabled(group.active ? !group.canSeekBackward || group.resolvingTime : !playbackController.canSeekBackward)
    }

    private var pauseControl: some View {
        Button(isPaused ? "Play" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill") {
            guard playbackActionsEnabled else { return }
            stopLiveCameraGestures()
            if group.active { group.togglePause() } else { playbackController.togglePause() }
        }
        .disabled(!canControlPlayback || group.resolvingTime)
    }

    private var forwardControl: some View {
        Button("Forward 30 seconds", systemImage: "goforward.30") {
            guard playbackActionsEnabled else { return }
            if group.active { group.seek(by: 30) } else { playbackController.seek(by: 30) }
        }
        .disabled(isLive || !canControlPlayback || group.resolvingTime)
    }

    private var showsQualityControl: Bool { cameraControlsEnabled && playbackActionsEnabled }

    private var privacyControl: CameraPrivacyToolbarControl? {
        guard cameraControlsEnabled, activeControls.state == .live else {
            return nil
        }
        let controls = CameraDetailControlSet(
            controls: activeControls.controls
        )
        guard let privacy = controls.privacy,
              privacy.valid != false,
              privacy.cameraOverlayBooleanValue != nil else {
            return nil
        }
        return CameraPrivacyToolbarControl(
            control: privacy,
            model: activeControls
        )
    }

    private var dayNightModeControl: CameraDayNightModeToolbarControl? {
        guard cameraControlsEnabled, activeControls.state == .live else {
            return nil
        }
        guard let target = CameraDayNightModeTarget(
            controls: activeControls.controls
        ), target.control.valid != false, target.selectedMode != nil else {
            return nil
        }
        return CameraDayNightModeToolbarControl(
            target: target,
            model: activeControls,
            appliesRepeatedSelections: presentation.showsMultipleCameras
        )
    }

    private var hasLiveToolbarControls: Bool {
        showsQualityControl
            || dayNightModeControl != nil
            || privacyControl != nil
    }

    private var qualityControl: some View {
        Menu {
            Picker("Video quality", selection: Binding(
                get: { displayedQuality },
                set: { quality in
                    guard let quality, cameraControlsEnabled,
                          playbackActionsEnabled else { return }
                    selectedQuality = quality
                }
            )) {
                if displayedQuality == nil {
                    Text("Mixed")
                        .tag(Optional<CameraLiveQualitySelection>.none)
                        .disabled(true)
                }
                ForEach(availableQualities, id: \.self) { quality in
                    Text(CameraLiveQualityPresentation.title(for: quality))
                        .tag(Optional(quality))
                }
            }
        } label: {
            Label("Video quality", systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel("Video quality")
        .accessibilityValue(
            displayedQuality.map(CameraLiveQualityPresentation.title(for:)) ?? "Mixed"
        )
        .disabled(!cameraControlsEnabled)
    }

    private var displayedQuality: CameraLiveQualitySelection? {
        if let focused = presentation.focusedSession { return focused.quality }
        guard Set(group.sessions.map(\.quality)).count <= 1 else { return nil }
        return group.sessions.first?.quality ?? group.quality
    }

    private var availableQualities: [CameraLiveQualitySelection] {
        if let focused = presentation.focusedSession {
            let capability = CameraLiveVideoCapability(metadata: focused.controls.deviceMetadata) ?? focused.camera.capability
            return CameraLiveQualityPresentation.options(in: capability.qualities, includesDefault: capability.supportsDefaultQuality)
        }
        return CameraLiveQualityPresentation.options(
            in: group.availableConcreteQualities,
            includesDefault: group.supportsDefaultQuality
        )
    }

    private func toggleControls() {
        withAnimation(reduceMotion ? nil : .snappy) {
            controlsVisible = interactionPresentation.togglingControls(
                from: controlsVisible
            )
        }
    }

    private var interactionPresentation: CameraPlaybackInteraction {
        CameraPlaybackInteraction(liveState: liveVideoState,
            usesHistory: playbackController.isUsingHistory,
            historyState: playbackController.historyState,
            playbackFailed: playbackController.errorMessage != nil)
    }

    private func stopLiveCameraGestures() {
        group.sessions.forEach { $0.gestures.stop() }
    }
}

#if canImport(UIKit)
private final class CameraSampleBufferUIView: UIView {
    let sampleBufferLayer: AVSampleBufferDisplayLayer
    weak var renderer: CameraH264Renderer?
    let replica: CameraVideoDisplayReplica?

    init(renderer: CameraH264Renderer, isSecondaryOutput: Bool) {
        self.renderer = renderer
        replica = isSecondaryOutput ? CameraVideoDisplayReplica() : nil
        sampleBufferLayer = replica?.layer ?? renderer.layer
        super.init(frame: .zero)
        self.layer.addSublayer(sampleBufferLayer)
        backgroundColor = .black
        if let replica { renderer.displayRelay.attach(replica) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleBufferLayer.frame = bounds
    }
}

private struct CameraSampleBufferView: UIViewRepresentable {
    let renderer: CameraH264Renderer
    let isSecondaryOutput: Bool

    func makeUIView(context: Context) -> CameraSampleBufferUIView {
        CameraSampleBufferUIView(renderer: renderer, isSecondaryOutput: isSecondaryOutput)
    }

    static func dismantleUIView(_ uiView: CameraSampleBufferUIView, coordinator: ()) {
        if let replica = uiView.replica { uiView.renderer?.displayRelay.detach(replica) }
    }

    func updateUIView(
        _ uiView: CameraSampleBufferUIView,
        context: Context
    ) {
        uiView.sampleBufferLayer.frame = uiView.bounds
    }
}
#elseif canImport(AppKit)
private final class CameraSampleBufferNSView: NSView {
    let sampleBufferLayer: AVSampleBufferDisplayLayer
    weak var renderer: CameraH264Renderer?
    let replica: CameraVideoDisplayReplica?

    init(renderer: CameraH264Renderer, isSecondaryOutput: Bool) {
        self.renderer = renderer
        replica = isSecondaryOutput ? CameraVideoDisplayReplica() : nil
        sampleBufferLayer = replica?.layer ?? renderer.layer
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(sampleBufferLayer)
        if let replica { renderer.displayRelay.attach(replica) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        sampleBufferLayer.frame = bounds
    }
}

private struct CameraSampleBufferView: NSViewRepresentable {
    let renderer: CameraH264Renderer
    let isSecondaryOutput: Bool

    func makeNSView(context: Context) -> CameraSampleBufferNSView {
        CameraSampleBufferNSView(renderer: renderer, isSecondaryOutput: isSecondaryOutput)
    }

    static func dismantleNSView(_ nsView: CameraSampleBufferNSView, coordinator: ()) {
        if let replica = nsView.replica { nsView.renderer?.displayRelay.detach(replica) }
    }

    func updateNSView(
        _ nsView: CameraSampleBufferNSView,
        context: Context
    ) {
        nsView.sampleBufferLayer.frame = nsView.bounds
    }
}
#endif
