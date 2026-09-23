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
}

enum CameraVideoCatalog {
    static func cameras(
        in devices: [HBTopologyDeviceDescriptor]
    ) -> [CameraVideoDevice] {
        devices.compactMap { device in
            guard let capability = CameraLiveVideoCapability(
                metadata: device.metadata
            ) else { return nil }
            return CameraVideoDevice(
                device: device,
                capability: capability
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
        case .failed(let error), .waiting(let error):
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
            attachment[kCMSampleAttachmentKey_DoNotDisplay] = !display
            attachment[kCMSampleAttachmentKey_NotSync] =
                !frame.flags.contains(.keyFrame)
        }

        layer.sampleBufferRenderer.enqueue(sampleBuffer)
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
        return buffer
    }

    func reset(removingDisplayedImage: Bool = true) {
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
    private var quality: CameraLiveQualitySelection
    private let client: HomeBaseWebSocketClient
    private let recordingController: CameraLocalRecordingController?
    private let playbackController: CameraLivePlaybackController?
    private let recordingOwnerID = UUID()
    private var arbiter: CameraStreamArbiter?
    private var subscription: CameraStreamSubscription?
    private var runToken: UUID?

    init(
        deviceIdentifier: String,
        quality: CameraLiveQualitySelection,
        client: HomeBaseWebSocketClient,
        recordingController: CameraLocalRecordingController? = nil,
        playbackController: CameraLivePlaybackController? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
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

    func run(access: CameraAccessSession? = nil) async {
        guard state == .idle, !Task.isCancelled else { return }
        let token = UUID()
        runToken = token
        state = .connecting
        qualityWarning = nil
        var ownedArbiter: CameraStreamArbiter?
        var ownedSubscription: CameraStreamSubscription?

        do {
            try await client.reactivate()
            try Task.checkCancellation()
            guard runToken == token else { throw CancellationError() }
            let shared = await client.cameraStreamArbiter()
            guard runToken == token else { throw CancellationError() }
            let authorization = try access?.authorizeStreams(shared)
            let acquired = try await shared.subscribe(camera: deviceIdentifier, quality: quality, authorization: authorization)
            ownedArbiter = shared; ownedSubscription = acquired
            try Task.checkCancellation()
            guard runToken == token else { throw CancellationError() }
            arbiter = shared; subscription = acquired
            // A quality selection may have changed during the acquire.
            await shared.update(acquired, quality: quality)
            events: for try await event in acquired.events {
                try Task.checkCancellation()
                guard runToken == token else { break }
                guard authorization?.isValid != false else { throw CancellationError() }
                switch event {
                case .qualityWarning(let message): qualityWarning = message
                case .frames(let frames):
                    for frame in frames {
                        guard runToken == token, !Task.isCancelled, authorization?.isValid != false else { break events }
                        if try await !consume(frame) { break events }
                    }
                }
            }
            if !Task.isCancelled, runToken == token {
                switch state {
                case .ended, .failed:
                    break
                default:
                    state = .failed("The live video connection ended.")
                }
            }
        } catch is CancellationError {
            if runToken == token { state = .idle }
        } catch {
            if runToken == token {
                state = .failed(error.localizedDescription)
            }
        }

        await releaseSubscription(ownedSubscription, from: ownedArbiter)
        if runToken == token {
            playbackController?.stop(ownerID: recordingOwnerID)
            runToken = nil
            await recordingController?.streamDidEnd(ownerID: recordingOwnerID)
        }
    }

    func stop(immediately: Bool = false) async {
        runToken = nil
        playbackController?.stop(ownerID: recordingOwnerID)
        // Publish the stopped state before awaiting network cleanup, so an old
        // stop cannot overwrite a newer run after a quick dismissal/reopen.
        state = .idle
        qualityWarning = nil
        await releaseSubscription(subscription, from: arbiter, immediately: immediately)
        await recordingController?.streamDidEnd(ownerID: recordingOwnerID)
    }

    private func consume(_ frame: HBMediaFrame) async throws -> Bool {
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
                    configuration, ownerID: recordingOwnerID, preservingDisplayedImage: true
                )
            } else {
                formatDescription = try renderer.configure(configuration, removingDisplayedImage: false)
            }
            await recordingController?.configure(
                ownerID: recordingOwnerID,
                generation: configuration.generation,
                formatDescription: formatDescription
            )
            if configuration.width > 0, configuration.height > 0 {
                aspectRatio = CGFloat(configuration.width)
                    / CGFloat(configuration.height)
            }
            if state != .playing { state = .waiting("Waiting for video…") }
        case .videoAccessUnit:
            let sampleBuffer: CMSampleBuffer?
            if let playbackController {
                sampleBuffer = try playbackController.receive(
                    frame, ownerID: recordingOwnerID
                )
            } else {
                sampleBuffer = try renderer.enqueue(frame)
            }
            if let sampleBuffer {
                recordingController?.append(
                    sampleBuffer,
                    ownerID: recordingOwnerID,
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
        usesHistory: Bool = false,
        onStateChanged: ((CameraLiveVideoModel.State) -> Void)? = nil,
        onAspectRatioChanged: ((CGFloat) -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: CameraLiveVideoModel(
            deviceIdentifier: deviceIdentifier,
            quality: quality,
            client: client,
            recordingController: recordingController,
            playbackController: playbackController
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
        ZStack {
            Color.black
                .allowsHitTesting(false)
            if usesHistory || model.state.displaysVideo {
                CameraSampleBufferView(renderer: model.renderer)
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
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task {
                                await model.stop()
                                retryID += 1
                            }
                        }
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
            // Covered previews relinquish their subscription; the arbiter
            // keeps a short handoff grace period, except on background/lock.
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
            Task {
                await model.stop()
                retryID &+= 1
            }
        }
        .onDisappear {
            Task {
                await model.stop()
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

private struct CameraToolbarVisibility: ViewModifier {
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        content.toolbarVisibility(
            isVisible ? .visible : .hidden,
            for: .navigationBar
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
        isUserInteractionEnabled = videoVisible
        singleTapRecognizer.isEnabled = videoVisible
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
        guard videoVisible else { return }
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
                    including: videoVisible ? .all : .none
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
        .allowsHitTesting(videoVisible)
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
    @Environment(\.dismiss) private var dismiss
    let client: HomeBaseWebSocketClient
    @StateObject private var selection: CameraScreenSelection
    @StateObject private var cameraPicker: CameraPickerModel
    @State private var panel = CameraPlayerPanel.off
    @State private var controlsVisible = true

    init(device: HBTopologyDeviceDescriptor, quality: CameraLiveQualitySelection, client: HomeBaseWebSocketClient) {
        self.client = client
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
                access: access,
                initialPosition: selection.session.position, cameraPicker: cameraPicker,
                panel: $panel, controlsVisible: $controlsVisible,
                selectCamera: { selection.select($0, position: $1) },
                retainCamera: { selection.retain($0, quality: $1) })
                .id(selection.session.id)
                .allowsHitTesting(access.isUnlocked)
                .accessibilityHidden(!access.isUnlocked)
                .overlay {
                    if !access.isUnlocked { CameraAccessLockedView(access: access) }
                }
                .toolbar {
                    if !access.isUnlocked {
                        ToolbarItem(placement: .cancellationAction) {
                            CameraPlayerCloseButton { dismiss() }
                        }
                    }
                }
            }
        }
    }
}

private struct CameraFullScreenCameraContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    let client: HomeBaseWebSocketClient
    let access: CameraAccessPresentation
    @StateObject private var initialSession: CameraGroupSession
    @StateObject private var group: CameraGroupPlayback
    private var primary: CameraGroupSession { group.sessions.first ?? initialSession }
    private var device: HBTopologyDeviceDescriptor { primary.camera.device }
    private var controlsModel: LiveDeviceControlsModel { primary.controls }
    private var playbackController: CameraLivePlaybackController { primary.playback }
    private var selectedQuality: CameraLiveQualitySelection {
        get { group.quality }
        nonmutating set { group.setQuality(newValue) }
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
    @State private var s3Destination: CameraS3Destination?
#if os(iOS)
    private var recordingController: CameraLocalRecordingController { primary.recordingController }
    @State private var savedConfirmationVisible = false
#endif

    init(
        device: HBTopologyDeviceDescriptor,
        quality: CameraLiveQualitySelection,
        client: HomeBaseWebSocketClient,
        access: CameraAccessPresentation,
        initialPosition: CameraSwitchPosition,
        cameraPicker: CameraPickerModel,
        panel: Binding<CameraPlayerPanel>,
        controlsVisible: Binding<Bool>,
        selectCamera: @escaping (CameraVideoDevice, CameraSwitchPosition) -> Void,
        retainCamera: @escaping (CameraVideoDevice, CameraLiveQualitySelection) -> Void
    ) {
        self.client = client
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
        let session = CameraGroupSession(camera: camera, client: client, quality: quality)
        _initialSession = StateObject(wrappedValue: session)
        _group = StateObject(wrappedValue: CameraGroupPlayback(client: client, initialSession: session))
    }

    private var cameraPresentation: some View {
        liveVideo
            .toolbar {
                if access.isUnlocked { cameraToolbar }
            }
            .modifier(CameraTransparentToolbar())
            .modifier(CameraToolbarVisibility(
                isVisible: !access.isUnlocked || visiblePlayerControls
            ))
        .onAppear {
            if access.isAuthorized {
                playbackController.prepareHistory(metadata: controlsModel.deviceMetadata, client: client, credentials: access.session?.unlockedCredentials)
            } else { group.suspend() }
            applyInitialPositionIfAuthorized()
        }
        .onDisappear {
            cameraSwitchTask?.cancel(); cameraSwitchTask = nil
            stopLiveCameraGestures()
            group.deactivate()
        }
        .onChange(of: cameraControlsEnabled) { _, enabled in
            if !enabled { stopLiveCameraGestures() }
        }
        .onChange(of: panelAvailability, initial: true) { _, availability in
            panel = availability.validated(panel)
        }
        .onChange(of: isShowingVideo, initial: true) { _, showsVideo in
            if !showsVideo {
                controlsVisible = true
                stopLiveCameraGestures()
            }
        }
        .task(id: CameraLiveVideoLifecycle.isSuspended(in: scenePhase, isStreamEnabled: access.isAuthorized)) {
            if CameraLiveVideoLifecycle.isSuspended(in: scenePhase, isStreamEnabled: access.isAuthorized) {
                group.suspend()
            } else { group.resume() }
        }
        .onChange(of: availableQualities) { _, qualities in
            guard !qualities.contains(selectedQuality),
                  let fallbackQuality = qualities.first else { return }
            selectedQuality = fallbackQuality
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
        .task(id: recordingController.successfulSaveCount) {
            guard recordingController.successfulSaveCount > 0 else { return }
            withAnimation(.snappy) {
                savedConfirmationVisible = true
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                savedConfirmationVisible = false
            }
        }
        .onChange(of: recordingController.state) { _, state in
            if state == .requestingAuthorization {
                savedConfirmationVisible = false
            }
        }
        .sensoryFeedback(
            .success,
            trigger: recordingController.successfulSaveCount
        )
        .sensoryFeedback(
            .impact(weight: .medium),
            trigger: recordingController.state
        ) { previousState, currentState in
            previousState != .recording && currentState == .recording
        }
        .alert(
            "Recording Unavailable",
            isPresented: recordingErrorIsPresented
        ) {
            Button("OK") {
                recordingController.dismissError()
            }
        } message: {
            Text(recordingController.errorMessage ?? "Unknown error")
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
                group.sessions.forEach { $0.playback.revokeCameraAccess() }
                s3Destination = nil
                cameraPickerVisible = false
                cameraSwitchTask?.cancel(); cameraSwitchTask = nil
                switchingCamera = false
            } else { applyInitialPositionIfAuthorized() }
        }
        .alert("Playback Unavailable", isPresented: Binding(
            get: { access.isUnlocked && playbackController.errorMessage != nil },
            set: { if !$0 { playbackController.dismissError() } }
        )) {
            Button("OK") { playbackController.dismissError() }
        } message: {
            Text(playbackController.errorMessage ?? "Unknown error")
        }
        .alert(cameraSwitchError != nil ? "Could Not Switch Camera" : "Camera Control Failed", isPresented: Binding(
            get: { access.isUnlocked && (cameraSwitchError != nil || group.error != nil) }, set: { if !$0 { cameraSwitchError = nil; group.error = nil } }
        )) {
            Button("OK") { cameraSwitchError = nil; group.error = nil }
        } message: {
            Text(cameraSwitchError ?? group.error ?? "Unknown error")
        }
    }

    private var liveVideo: some View {
        ZStack {
            CameraGroupVideo(group: group, cameraControlsEnabled: cameraControlsEnabled,
                controlsVisible: visiblePlayerControls,
                isAccessAllowed: access.isAuthorized,
                credentials: access.session?.unlockedCredentials,
                onSingleTap: toggleControls)

            if visiblePlayerControls && panel == .ptz && panelAvailability.enablesPTZ {
                CameraDetailControlsOverlay(model: controlsModel)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if visiblePlayerControls, panel != .ptz,
               let metadata = CameraPlaybackHistoryAvailability.metadata(in: controlsModel.deviceMetadata) {
                CameraTimelinePlacement(isMultiple: group.hasMultipleCameras) {
                    CameraTimelinePanel(isPresented: timelineVisible) {
                        CameraHistoryTimeline(makeTransport: {
                            await CameraHistorySources.thumbnails(metadata: metadata, client: client, credentials: access.session?.unlockedCredentials)
                        }, source: .init(metadata: metadata, credentials: access.session?.unlockedCredentials),
                            cameraID: metadata.cameraID, timeZone: playbackTimeZone,
                            position: { group.active ? group.positionForSwitch() : playbackController.positionForCameraSwitch(metadata: controlsModel.deviceMetadata) },
                            onBegin: {
                                guard playbackActionsEnabled else { return }
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
                            })
                            .id(metadata.cameraID)
                    }
                }
            }
        }
        .overlayPreferenceValue(CameraTimelineBoundsPreference.self) { timelineBounds in
            if visiblePlayerControls {
                CameraPlayerPanelPlacement(panel: panel, timelineBounds: timelineBounds) {
                    CameraPlayerPanelPicker(selection: $panel, availability: panelAvailability)
                }
                if let destination = lockedS3Destination, access.session != nil {
                    CameraPlayerPanelPlacement(panel: panel, timelineBounds: timelineBounds, leading: true) {
                        CameraS3PadlockButton { s3Destination = destination }
                    }
                }
            }
        }
#if os(iOS)
        .overlay(alignment: .top) {
            if visiblePlayerControls, !group.hasMultipleCameras,
               recordingController.locksStreamConfiguration || savedConfirmationVisible {
                cameraStatusMessage.fixedSize().padding(.top, 8).allowsHitTesting(false)
            }
        }
#endif
        .background(Color.black.ignoresSafeArea())
        .animation(.snappy, value: controlsVisible)
        .animation(reduceMotion ? nil : .snappy, value: panel)
        .onChange(of: controlsModel.deviceMetadata, initial: true) { _, metadata in
            if access.isAuthorized, !group.active { playbackController.prepareHistory(metadata: metadata, client: client, credentials: access.session?.unlockedCredentials) }
        }
        .accessibilityActions {
            if isShowingVideo {
                Button("Toggle player controls", action: toggleControls)
            }
        }
    }

#if os(iOS)
    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
        playbackToolbar
        // In compact width, playback speed takes Record's trailing place
        // outside Live. Regular width still keeps the disabled Record button.
        if !group.hasMultipleCameras, horizontalSizeClass != .compact || isLive {
            ToolbarItem(placement: .topBarTrailing) { recordingControl }
            if horizontalSizeClass != .compact, hasLiveToolbarControls {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }
        if showsQualityControl {
            ToolbarItem(placement: cameraSettingsPlacement) { qualityControl }
        }
        if let dayNightModeControl {
            ToolbarItem(placement: cameraSettingsPlacement) {
                dayNightModeControl
            }
        }
        if let privacyControl {
            ToolbarItem(placement: cameraSettingsPlacement) {
                privacyControl
            }
        }
        if horizontalSizeClass != .compact {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            cameraPickerControl
        }
    }

    private var cameraSettingsPlacement: ToolbarItemPlacement {
        // iOS 26 compact-width overflow policy, shared with the 30-second
        // shuttles in CameraPlaybackToolbar. Record and camera selection stay
        // primary. Adopt iOS 27's overflow/visibility-priority APIs when available.
        horizontalSizeClass == .compact ? .secondaryAction : .topBarTrailing
    }
#else
    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
        playbackToolbar
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

    private var playbackToolbar: some ToolbarContent {
        CameraPlaybackToolbar(isLive: isLive, playbackEnabled: playbackActionsEnabled,
            close: { dismiss() }, goLive: returnToLive,
            back: backControl, pause: pauseControl, forward: forwardControl,
            speed: playbackSpeedControl)
    }

    private var cameraPickerControl: some View {
        Button {
            group.beginCameraSelection()
            cameraPickerVisible = true
        } label: {
            if switchingCamera { ProgressView() }
            else { Image(systemName: "rectangle.grid.3x3.fill") }
        }
        .accessibilityLabel("Choose camera")
        .accessibilityValue(group.active ? group.sessions.map { $0.camera.device.displayName }.joined(separator: ", ") : device.displayName)
        .disabled(switchingCamera || group.resolvingTime)
#if os(iOS)
        .disabled(recordingController.locksStreamConfiguration)
#endif
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
        guard !recordingController.locksStreamConfiguration else { return }
#endif
        stopLiveCameraGestures()
        withAnimation(.snappy) { group.setMultipleSelection(enabled) }
        if !group.active { retainCamera(primary.camera, primary.quality) }
    }

    private func switchCamera(_ camera: CameraVideoDevice) {
        cameraPickerVisible = false
        guard access.isUnlocked, camera.id != device.identifier, !switchingCamera else { return }
        let departure = CameraPlaybackHistoryAvailability.isAvailable(in: camera.device.metadata)
            ? playbackController.positionForCameraSwitch(metadata: controlsModel.deviceMetadata) : .live
        stopLiveCameraGestures()
        switchingCamera = true
        cameraSwitchTask = Task {
            defer { switchingCamera = false }
            do {
#if os(iOS)
                // A camera change must never mix cameras in one Photos recording.
                await recordingController.stopAndSave()
                while recordingController.state == .saving { try await Task.sleep(for: .milliseconds(50)) }
                guard recordingController.errorMessage == nil else { return }
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
    @ViewBuilder
    private var cameraStatusMessage: some View {
        if recordingController.state == .requestingAuthorization {
            CameraToolbarStatus(title: "Requesting Photos access…")
        } else if recordingController.state == .waitingForKeyFrame {
            CameraToolbarStatus(
                title: "Recording",
                showsActivityIndicator: true,
                accessibilityValue: "Waiting for video to start"
            )
        } else if recordingController.state == .recording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = recordingController.recordingStartedAt.map {
                    max(0, context.date.timeIntervalSince($0))
                } ?? 0
                let timer = Duration.seconds(elapsed).formatted(
                    .time(pattern: .minuteSecond(padMinuteToLength: 1))
                )
                CameraToolbarStatus(
                    title: "Recording \(timer)",
                    prominent: true,
                    monospacedDigits: true
                )
            }
        } else if recordingController.state == .saving {
            CameraToolbarStatus(title: "Saving to Photos…")
        } else if savedConfirmationVisible {
            CameraToolbarStatus(title: "Saved to Photos")
        }
    }

    @ViewBuilder
    private var recordingControl: some View {
        if recordingController.isRecording {
            recordingButton.buttonStyle(.glassProminent)
        } else {
            recordingButton
        }
    }

    private var recordingButton: some View {
        Button {
            guard recordingController.isRecording || cameraControlsEnabled else { return }
            recordingController.toggle()
        } label: {
            Image(systemName: recordingController.isRecording
                ? "stop.fill"
                : "record.circle")
        }
        .tint(.red)
        .disabled(
            recordingController.state == .requestingAuthorization
                || recordingController.state == .saving
                || (!recordingController.isRecording
                    && (!recordingController.isStreamAvailable || !cameraControlsEnabled))
        )
        .accessibilityLabel(
            recordingController.isRecording
                ? "Stop recording"
                : "Record video"
        )
        .accessibilityValue(recordingAccessibilityValue)
    }

    private var recordingAccessibilityValue: String {
        switch recordingController.state {
        case .idle: "Not recording"
        case .requestingAuthorization: "Requesting Photos access"
        case .waitingForKeyFrame: "Starting recording"
        case .recording: "Recording"
        case .saving: "Saving to Photos"
        case .failed: "Recording unavailable"
        }
    }

    private var recordingErrorIsPresented: Binding<Bool> {
        Binding(
            get: { access.isUnlocked && recordingController.errorMessage != nil },
            set: { isPresented in
                if !isPresented { recordingController.dismissError() }
            }
        )
    }
#endif

    private var panelAvailability: CameraPlayerPanelAvailability {
        CameraPlayerPanelAvailability(
            historyAvailable: CameraPlaybackHistoryAvailability.isAvailable(in: controlsModel.deviceMetadata),
            ptzSupported: CameraDetailControlSet(controls: controlsModel.controls).hasPTZ,
            isLive: cameraControlsEnabled, isMultiple: group.hasMultipleCameras)
    }

    private var timelineVisible: Bool { panel == .history }

    private func returnToLive() {
        guard !isLive, playbackActionsEnabled else { return }
        stopLiveCameraGestures()
        if group.active { group.goLive() } else { playbackController.goLive() }
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

    private var cameraControlsEnabled: Bool { access.isUnlocked && !switchingCamera && playbackControlsPresentation.cameraControlsEnabled }

    private var playbackActionsEnabled: Bool {
#if os(iOS)
        access.isUnlocked && !switchingCamera && !recordingController.locksStreamConfiguration
#else
        access.isUnlocked && !switchingCamera
#endif
    }

    private var isLive: Bool { group.active ? group.isLive : playbackController.isLive }
    private var isPaused: Bool { group.active ? group.isPaused : playbackController.isPaused }
    private var canControlPlayback: Bool { group.active ? group.canControlPlayback : playbackController.canControlPlayback }
    private var activeControls: LiveDeviceControlsModel { group.hasMultipleCameras ? group.sharedControls : controlsModel }
    private var isShowingVideo: Bool { group.active ? group.allPanesShowVideo : interactionPresentation.showsVideo }
    private var visiblePlayerControls: Bool { access.isUnlocked && (!isShowingVideo || controlsVisible) }

    private var lockedS3Destination: CameraS3Destination? {
        for session in group.sessions {
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
        CameraHistoryTimestamp.timeZone(in: group.active ? (group.sessions.first?.controls.deviceMetadata ?? [:]) : controlsModel.deviceMetadata)
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
        .labelStyle(.iconOnly)
        .disabled(!canControlPlayback || group.resolvingTime)
    }

    private var forwardControl: some View {
        Button("Forward 30 seconds", systemImage: "goforward.30") {
            guard playbackActionsEnabled else { return }
            if group.active { group.seek(by: 30) } else { playbackController.seek(by: 30) }
        }
        .disabled(isLive || !canControlPlayback || group.resolvingTime)
    }

    private var privacyControl: CameraPrivacyToolbarControl? {
        guard cameraControlsEnabled, activeControls.state == .live else { return nil }
        let controls = CameraDetailControlSet(
            controls: activeControls.controls
        )
        guard let privacy = controls.privacy, privacy.valid != false,
              privacy.cameraOverlayBooleanValue != nil else { return nil }
        return CameraPrivacyToolbarControl(
            control: privacy,
            model: activeControls
        )
    }

    private var dayNightModeControl: CameraDayNightModeToolbarControl? {
        guard cameraControlsEnabled, activeControls.state == .live else { return nil }
        guard let target = CameraDayNightModeTarget(
            controls: activeControls.controls
        ), target.control.valid != false, target.selectedMode != nil else { return nil }
        return CameraDayNightModeToolbarControl(
            target: target,
            model: activeControls,
            appliesRepeatedSelections: group.hasMultipleCameras
        )
    }

    private var showsQualityControl: Bool { cameraControlsEnabled && playbackActionsEnabled }

    private var hasLiveToolbarControls: Bool {
        showsQualityControl || dayNightModeControl != nil || privacyControl != nil
    }

    private var qualityControl: some View {
        Menu {
            ForEach(availableQualities, id: \.self) { quality in
                Button {
                    guard cameraControlsEnabled, playbackActionsEnabled else { return }
                    selectedQuality = quality
                } label: {
                    if quality == selectedQuality {
                        Label(
                            CameraLiveQualityPresentation.title(for: quality),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(CameraLiveQualityPresentation.title(for: quality))
                    }
                }
            }
        } label: {
            Label("Video quality", systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel("Video quality")
        .accessibilityValue(
            CameraLiveQualityPresentation.title(for: selectedQuality)
        )
        .disabled(!cameraControlsEnabled)
#if os(iOS)
        .disabled(recordingController.locksStreamConfiguration)
#endif
    }

    private var availableQualities: [CameraLiveQualitySelection] {
        CameraLiveQualityPresentation.options(
            in: group.availableConcreteQualities,
            includesDefault: group.supportsDefaultQuality
        )
    }

    private func toggleControls() {
        withAnimation(.snappy) {
            controlsVisible = isShowingVideo ? !controlsVisible : true
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

    init(layer: AVSampleBufferDisplayLayer) {
        sampleBufferLayer = layer
        super.init(frame: .zero)
        self.layer.addSublayer(layer)
        backgroundColor = .black
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

    func makeUIView(context: Context) -> CameraSampleBufferUIView {
        CameraSampleBufferUIView(layer: renderer.layer)
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

    init(layer: AVSampleBufferDisplayLayer) {
        sampleBufferLayer = layer
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(layer)
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

    func makeNSView(context: Context) -> CameraSampleBufferNSView {
        CameraSampleBufferNSView(layer: renderer.layer)
    }

    func updateNSView(
        _ nsView: CameraSampleBufferNSView,
        context: Context
    ) {
        nsView.sampleBufferLayer.frame = nsView.bounds
    }
}
#endif
