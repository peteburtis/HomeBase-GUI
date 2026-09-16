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

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func configure(_ configuration: HBMediaStreamConfiguration) throws {
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
    }

    func enqueue(_ frame: HBMediaFrame) throws {
        guard frame.type == .videoAccessUnit,
              frame.generation == generation,
              let formatDescription else {
            return
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
            duration: .invalid,
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
    private var mediaConnection: HomeBaseMediaConnection?
    private var streamID: UUID?
    private var runToken: UUID?

    init(
        deviceIdentifier: String,
        quality: HBCameraLiveQuality,
        client: HomeBaseWebSocketClient
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.quality = quality
        self.client = client
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
                if try !consume(frame) { break }
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
        if runToken == token { runToken = nil }
    }

    func stop() async {
        runToken = nil
        let connection = mediaConnection
        let streamID = streamID
        await releaseLease(connection: connection, streamID: streamID)
        state = .idle
    }

    private func consume(_ frame: HBMediaFrame) throws -> Bool {
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
            try renderer.configure(configuration)
            if configuration.width > 0, configuration.height > 0 {
                aspectRatio = CGFloat(configuration.width)
                    / CGFloat(configuration.height)
            }
            state = .waiting("Waiting for video…")
        case .videoAccessUnit:
            try renderer.enqueue(frame)
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

struct CameraLiveVideoPlayer: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CameraLiveVideoModel
    @State private var retryID = 0
    private let allowsRetry: Bool

    init(
        deviceIdentifier: String,
        quality: HBCameraLiveQuality,
        client: HomeBaseWebSocketClient,
        allowsRetry: Bool
    ) {
        _model = StateObject(wrappedValue: CameraLiveVideoModel(
            deviceIdentifier: deviceIdentifier,
            quality: quality,
            client: client
        ))
        self.allowsRetry = allowsRetry
    }

    var body: some View {
        ZStack {
            Color.black
            CameraSampleBufferView(renderer: model.renderer)

            if let message = statusMessage {
                VStack(spacing: 12) {
                    if isPending {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "video.slash.fill")
                            .font(.title2)
                    }
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
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
        .task(id: "\(retryID)-\(String(describing: scenePhase))") {
            if scenePhase == .active {
                await model.run()
            } else {
                await model.stop()
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

struct CameraFullScreenLiveVideoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let device: HBTopologyDeviceDescriptor
    let quality: HBCameraLiveQuality
    let client: HomeBaseWebSocketClient
    @StateObject private var controlsModel: LiveDeviceControlsModel

    init(
        device: HBTopologyDeviceDescriptor,
        quality: HBCameraLiveQuality,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        self.quality = quality
        self.client = client
        _controlsModel = StateObject(wrappedValue: LiveDeviceControlsModel(
            device: device,
            client: client
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraLiveVideoPlayer(
                deviceIdentifier: device.addressableName,
                quality: quality,
                client: client,
                allowsRetry: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            CameraDetailControlsOverlay(model: controlsModel)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Label("Close Live Video", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.6))
                    .accessibilityLabel("Close live video")
                }
                .padding()
                Spacer()
            }
        }
        .onAppear {
            CameraLandscapeOrientation.activate()
        }
        .onDisappear {
            CameraLandscapeOrientation.restore()
            Task {
                await controlsModel.stop()
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await controlsModel.run(reactivating: true)
            } else {
                await controlsModel.stop()
            }
        }
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

private enum CameraLandscapeOrientation {
    static func activate() {
#if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscape)
        )
#endif
    }

    static func restore() {
#if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .allButUpsideDown)
        )
#endif
    }
}
