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

    let qualities: Set<HBCameraLiveQuality>

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
    }

    var previewQuality: HBCameraLiveQuality {
        qualities.min() ?? .low
    }

    var fullScreenQuality: HBCameraLiveQuality {
        qualities.max() ?? .high
    }
}

enum CameraLiveQualityPresentation {
    static func options(
        in qualities: Set<HBCameraLiveQuality>
    ) -> [HBCameraLiveQuality] {
        qualities.sorted(by: >)
    }

    static func title(for quality: HBCameraLiveQuality) -> String {
        switch quality {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

private nonisolated final class HomeBaseMediaConnection: @unchecked Sendable {
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
    private var sampleDuration: CMTime = .invalid

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func configure(
        _ configuration: HBMediaStreamConfiguration
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

        layer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
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
    func enqueue(_ frame: HBMediaFrame) throws -> CMSampleBuffer? {
        guard frame.type == .videoAccessUnit,
              frame.generation == generation,
              let formatDescription else {
            return nil
        }
        guard Self.isValidAVCCAccessUnit(frame.payload) else {
            throw RendererError.invalidAccessUnit
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
            attachment[kCMSampleAttachmentKey_NotSync] =
                !frame.flags.contains(.keyFrame)
        }

        if layer.sampleBufferRenderer.status == .failed {
            layer.sampleBufferRenderer.flush()
        }
        layer.sampleBufferRenderer.enqueue(sampleBuffer)
        return sampleBuffer
    }

    static func isValidAVCCAccessUnit(_ data: Data) -> Bool {
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

    let renderer = CameraH264Renderer()

    private let deviceIdentifier: String
    private let quality: HBCameraLiveQuality
    private let client: HomeBaseWebSocketClient
    private let recordingController: CameraLocalRecordingController?
    private let recordingOwnerID = UUID()
    private var mediaConnection: HomeBaseMediaConnection?
    private var streamID: UUID?
    private var runToken: UUID?

    init(
        deviceIdentifier: String,
        quality: HBCameraLiveQuality,
        client: HomeBaseWebSocketClient,
        recordingController: CameraLocalRecordingController? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.quality = quality
        self.client = client
        self.recordingController = recordingController
    }

    func run() async {
        guard state == .idle else { return }
        let token = UUID()
        runToken = token
        state = .connecting
        var ownedConnection: HomeBaseMediaConnection?
        var ownedStreamID: UUID?

        do {
            try await client.reactivate()
            let lease = try await client.openCameraLiveStream(
                deviceIdentifier: deviceIdentifier,
                quality: quality
            )
            try Task.checkCancellation()
            streamID = lease.opened.streamID
            ownedStreamID = lease.opened.streamID

            let connection = try HomeBaseMediaConnection(
                host: lease.mediaHost,
                port: lease.opened.mediaPort
            )
            mediaConnection = connection
            ownedConnection = connection
            let frames = try connection.frames(ticket: lease.opened.ticket)
            for try await frame in frames {
                try Task.checkCancellation()
                guard runToken == token else { break }
                let shouldContinue = try await consume(frame)
                if !shouldContinue { break }
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

        await releaseLease(
            connection: ownedConnection,
            streamID: ownedStreamID
        )
        await recordingController?.streamDidEnd(ownerID: recordingOwnerID)
        if runToken == token { runToken = nil }
    }

    func stop() async {
        runToken = nil
        let connection = mediaConnection
        let streamID = streamID
        await releaseLease(connection: connection, streamID: streamID)
        await recordingController?.streamDidEnd(ownerID: recordingOwnerID)
        state = .idle
    }

    private func consume(_ frame: HBMediaFrame) async throws -> Bool {
        switch frame.type {
        case .streamStatus:
            let status = try JSONDecoder().decode(
                HBMediaStreamStatus.self,
                from: frame.payload
            )
            state = .waiting(Self.statusText(status))
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
            let formatDescription = try renderer.configure(configuration)
            await recordingController?.configure(
                ownerID: recordingOwnerID,
                generation: configuration.generation,
                formatDescription: formatDescription
            )
            if configuration.width > 0, configuration.height > 0 {
                aspectRatio = CGFloat(configuration.width)
                    / CGFloat(configuration.height)
            }
            state = .waiting("Waiting for video…")
        case .videoAccessUnit:
            if let sampleBuffer = try renderer.enqueue(frame) {
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

    private func releaseLease(
        connection: HomeBaseMediaConnection?,
        streamID: UUID?
    ) async {
        connection?.cancel()
        if mediaConnection === connection { mediaConnection = nil }
        guard let streamID, self.streamID == streamID else { return }
        self.streamID = nil
        try? await client.closeCameraLiveStream(streamID)
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

    static func isSuspended(in scenePhase: ScenePhase) -> Bool {
        scenePhase == .background
    }

    static func taskIdentity(
        retryID: Int,
        scenePhase: ScenePhase
    ) -> TaskIdentity {
        TaskIdentity(
            retryID: retryID,
            isSuspended: isSuspended(in: scenePhase)
        )
    }
}

struct CameraLiveVideoPlayer: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CameraLiveVideoModel
    @State private var retryID = 0
    private let allowsRetry: Bool
    private let restartRequest: Int

    init(
        deviceIdentifier: String,
        quality: HBCameraLiveQuality,
        client: HomeBaseWebSocketClient,
        allowsRetry: Bool,
        restartRequest: Int = 0,
        recordingController: CameraLocalRecordingController? = nil
    ) {
        _model = StateObject(wrappedValue: CameraLiveVideoModel(
            deviceIdentifier: deviceIdentifier,
            quality: quality,
            client: client,
            recordingController: recordingController
        ))
        self.allowsRetry = allowsRetry
        self.restartRequest = restartRequest
    }

    var body: some View {
        ZStack {
            Color.black
                .allowsHitTesting(false)
            if model.state.displaysVideo {
                CameraSampleBufferView(renderer: model.renderer)
                    .allowsHitTesting(false)
            }

            if let message = statusMessage {
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
        .accessibilityLabel("Live camera video")
        .task(id: CameraLiveVideoLifecycle.taskIdentity(
            retryID: retryID,
            scenePhase: scenePhase
        )) {
            if CameraLiveVideoLifecycle.isSuspended(in: scenePhase) {
                await model.stop()
            } else {
                await model.run()
            }
        }
        .onChange(of: restartRequest) { _, _ in
            guard scenePhase == .active,
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

private enum CameraPanGesturePhase {
    case began
    case changed
    case ended
    case cancelled
}

private enum CameraMagnifyGesturePhase {
    case began
    case changed
    case ended
    case cancelled
}

#if canImport(UIKit)
private final class CameraLiveGestureUIView: UIView {
    var onPan: ((CameraPanGesturePhase, CGSize, CGSize) -> Void)?
    var onMagnify: ((CameraMagnifyGesturePhase, CGFloat) -> Void)? {
        didSet { pinchRecognizer.isEnabled = onMagnify != nil }
    }
    var onSingleTap: (() -> Void)?
    var onTwoFingerTap: (() -> Void)?

    private lazy var pinchRecognizer = UIPinchGestureRecognizer(
        target: self,
        action: #selector(pinched(_:))
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(
            target: self,
            action: #selector(panned(_:))
        )
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        pinchRecognizer.isEnabled = false
        addGestureRecognizer(pinchRecognizer)

        let singleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(singleTapped)
        )
        singleTap.numberOfTouchesRequired = 1
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(
            target: self,
            action: #selector(twoFingerTapped)
        )
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)
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

private struct CameraLiveGestureSurface: UIViewRepresentable {
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
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.onSingleTap = onSingleTap
        view.onTwoFingerTap = onTwoFingerTap
    }
}
#else
private struct CameraLiveGestureSurface: View {
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
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded(onSingleTap)
                )

            if let onMagnify {
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
    }
}
#endif

struct CameraFullScreenLiveVideoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let device: HBTopologyDeviceDescriptor
    let client: HomeBaseWebSocketClient
    @StateObject private var controlsModel: LiveDeviceControlsModel
    @StateObject private var panTiltGestureController:
        CameraPanTiltGestureController
    @StateObject private var zoomGestureController: CameraZoomGestureController
    @State private var videoRestartRequest = 0
    @State private var controlsVisible = true
    @State private var selectedQuality: HBCameraLiveQuality
#if os(iOS)
    @StateObject private var recordingController:
        CameraLocalRecordingController
    @State private var savedConfirmationVisible = false
#endif

    init(
        device: HBTopologyDeviceDescriptor,
        quality: HBCameraLiveQuality,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        self.client = client
        _selectedQuality = State(initialValue: quality)
        let controlsModel = LiveDeviceControlsModel(
            device: device,
            client: client
        )
        _controlsModel = StateObject(wrappedValue: controlsModel)
        _panTiltGestureController = StateObject(wrappedValue:
            CameraPanTiltGestureController(model: controlsModel)
        )
        _zoomGestureController = StateObject(wrappedValue:
            CameraZoomGestureController(model: controlsModel)
        )
#if os(iOS)
        _recordingController = StateObject(wrappedValue:
            CameraLocalRecordingController(
                destination: CameraPhotoLibraryRecordingDestination()
            )
        )
#endif
    }

    var body: some View {
        NavigationStack {
            liveVideo
                .toolbar {
                    cameraToolbar
                }
                .modifier(CameraTransparentToolbar())
                .modifier(CameraToolbarVisibility(
                    isVisible: controlsVisible
                ))
        }
        .onAppear {
            CameraLandscapeOrientation.activate()
            captureInitialPanTiltPosition()
        }
        .onDisappear {
            panTiltGestureController.stop()
            zoomGestureController.stop()
            Task {
                await controlsModel.stop()
            }
        }
        .task(id: CameraLiveVideoLifecycle.isSuspended(in: scenePhase)) {
            if CameraLiveVideoLifecycle.isSuspended(in: scenePhase) {
                await controlsModel.stop()
            } else {
                await controlsModel.run(reactivating: true)
            }
        }
        .onChange(of: privacyEnabled) { previousValue, currentValue in
            guard CameraPrivacyStreamRecovery.shouldRequestRestart(
                from: previousValue,
                to: currentValue
            ) else { return }
            videoRestartRequest &+= 1
        }
        .onChange(of: panTiltGestureTarget?.observedPosition) {
            _, _ in
            captureInitialPanTiltPosition()
        }
        .onChange(of: availableQualities) { _, qualities in
            guard !qualities.contains(selectedQuality),
                  let fallbackQuality = qualities.first else { return }
            selectedQuality = fallbackQuality
        }
#if os(iOS)
        .task(id: recordingController.successfulSaveCount) {
            guard recordingController.successfulSaveCount > 0 else { return }
            withAnimation(.snappy) {
                savedConfirmationVisible = true
            }
            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                savedConfirmationVisible = false
            }
        }
        .sensoryFeedback(
            .success,
            trigger: recordingController.successfulSaveCount
        )
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
#endif
    }

    private var liveVideo: some View {
        ZStack {
            videoPresentation
                .ignoresSafeArea(.container)

            if controlsVisible {
                CameraDetailControlsOverlay(model: controlsModel)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .animation(.snappy, value: controlsVisible)
        .accessibilityAction(named: "Toggle camera controls") {
            toggleControls()
        }
        .accessibilityAction(named: "Recenter camera") {
            recenterCamera()
        }
    }

    private var videoPresentation: some View {
        CameraLiveVideoPlayer(
            deviceIdentifier: device.addressableName,
            quality: selectedQuality,
            client: client,
            allowsRetry: true,
            restartRequest: videoRestartRequest,
            recordingController: videoRecordingController
        )
        .id(selectedQuality)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraLiveGestureSurface(
                    onPan: handlePanGesture,
                    onMagnify: magnifyGestureHandler,
                    onSingleTap: toggleControls,
                    onTwoFingerTap: recenterCamera
                )
            }
        }
    }

#if os(iOS)
    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            closeButton
        }
        if savedConfirmationVisible {
            ToolbarItem(placement: .principal) {
                savedConfirmation
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            recordingControl
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            qualityControl
        }
        if let dayNightModeControl {
            ToolbarItem(placement: .topBarTrailing) {
                dayNightModeControl
            }
        }
        if let privacyControl {
            ToolbarItem(placement: .topBarTrailing) {
                privacyControl
            }
        }
    }
#else
    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            closeButton
        }
        ToolbarItem(placement: .primaryAction) {
            qualityControl
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
    }
#endif

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Close Live Video", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Close live video")
    }

#if os(iOS)
    private var savedConfirmation: some View {
        Text("Saved to Photos")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .accessibilityAddTraits(.isStaticText)
    }

    private var recordingControl: some View {
        Button {
            recordingController.toggle()
        } label: {
            Image(systemName: "record.circle")
        }
        .tint(recordingController.isRecording ? .red : .primary)
        .disabled(
            recordingController.state == .requestingAuthorization
                || recordingController.state == .saving
                || (!recordingController.isRecording
                    && !recordingController.isStreamAvailable)
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
            get: { recordingController.errorMessage != nil },
            set: { isPresented in
                if !isPresented { recordingController.dismissError() }
            }
        )
    }
#endif

    private var privacyControl: CameraPrivacyToolbarControl? {
        let controls = CameraDetailControlSet(
            controls: controlsModel.controls
        )
        guard let privacy = controls.privacy else { return nil }
        return CameraPrivacyToolbarControl(
            control: privacy,
            model: controlsModel
        )
    }

    private var dayNightModeControl: CameraDayNightModeToolbarControl? {
        guard let target = CameraDayNightModeTarget(
            controls: controlsModel.controls
        ) else { return nil }
        return CameraDayNightModeToolbarControl(
            target: target,
            model: controlsModel
        )
    }

    private var qualityControl: some View {
        Menu {
            ForEach(availableQualities, id: \.self) { quality in
                Button {
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
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Video quality")
        .accessibilityValue(
            CameraLiveQualityPresentation.title(for: selectedQuality)
        )
#if os(iOS)
        .disabled(recordingController.locksStreamConfiguration)
#endif
    }

    private var availableQualities: [HBCameraLiveQuality] {
        let qualities = CameraLiveVideoCapability(
            metadata: controlsModel.deviceMetadata
        )?.qualities ?? [selectedQuality]
        return CameraLiveQualityPresentation.options(in: qualities)
    }

    private var privacyEnabled: Bool? {
        CameraDetailControlSet(controls: controlsModel.controls)
            .observedPrivacyEnabled
    }

    private var videoRecordingController:
        CameraLocalRecordingController?
    {
#if os(iOS)
        recordingController
#else
        nil
#endif
    }

    private var panTiltGestureTarget: CameraPanTiltGestureTarget? {
        guard controlsModel.state == .live else { return nil }
        return CameraPanTiltGestureTarget(controls: controlsModel.controls)
    }

    private var zoomGestureTarget: CameraZoomGestureTarget? {
        guard controlsModel.state == .live else { return nil }
        return CameraZoomGestureTarget(controls: controlsModel.controls)
    }

    private var magnifyGestureHandler:
        ((CameraMagnifyGesturePhase, CGFloat) -> Void)?
    {
        guard zoomGestureTarget != nil else { return nil }
        return { phase, magnification in
            handleMagnifyGesture(
                phase: phase,
                magnification: magnification
            )
        }
    }

    private func captureInitialPanTiltPosition() {
        guard let panTiltGestureTarget else { return }
        panTiltGestureController.captureInitialPosition(
            from: panTiltGestureTarget
        )
    }

    private func handlePanGesture(
        phase: CameraPanGesturePhase,
        translation: CGSize,
        viewport: CGSize
    ) {
        switch phase {
        case .began:
            guard let panTiltGestureTarget else { return }
            panTiltGestureController.beginDrag(using: panTiltGestureTarget)
        case .changed:
            panTiltGestureController.updateDrag(
                translation: translation,
                viewport: viewport
            )
        case .ended:
            panTiltGestureController.endDrag(
                translation: translation,
                viewport: viewport
            )
        case .cancelled:
            panTiltGestureController.cancelDrag()
        }
    }

    private func handleMagnifyGesture(
        phase: CameraMagnifyGesturePhase,
        magnification: CGFloat
    ) {
        switch phase {
        case .began:
            guard let zoomGestureTarget else { return }
            zoomGestureController.beginMagnification(
                using: zoomGestureTarget
            )
        case .changed:
            zoomGestureController.updateMagnification(magnification)
        case .ended:
            zoomGestureController.endMagnification(magnification)
        case .cancelled:
            zoomGestureController.cancelMagnification()
        }
    }

    private func toggleControls() {
        withAnimation(.snappy) {
            controlsVisible.toggle()
        }
    }

    private func recenterCamera() {
        guard let panTiltGestureTarget else { return }
        panTiltGestureController.recenter(using: panTiltGestureTarget)
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

@MainActor
enum CameraLandscapeOrientation {
#if os(iOS)
    private static var isPreparedForCamera = false

    static func supportedInterfaceOrientations(
        for window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if isPreparedForCamera { return .landscape }
        return window?.traitCollection.userInterfaceIdiom == .pad
            ? .all
            : .allButUpsideDown
    }

    static func prepareForPresentation() {
        isPreparedForCamera = true
        invalidateSupportedOrientations()
    }
#endif

    static func activate() {
#if os(iOS)
        prepareForPresentation()
        requestGeometryUpdate(interfaceOrientations: .landscape)
#endif
    }

    static func restore() {
#if os(iOS)
        isPreparedForCamera = false
        invalidateSupportedOrientations()
        requestGeometryUpdate(interfaceOrientations: .allButUpsideDown)
#endif
    }

#if os(iOS)
    private static func invalidateSupportedOrientations() {
        for scene in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
        {
            for window in scene.windows where !window.isHidden {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
        }
    }

    private static func requestGeometryUpdate(
        interfaceOrientations: UIInterfaceOrientationMask
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        scene.requestGeometryUpdate(.iOS(
            interfaceOrientations: interfaceOrientations
        ))
    }
#endif
}
