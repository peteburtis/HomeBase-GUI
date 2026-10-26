import Combine
import CoreGraphics
import Foundation
import HomeBaseProtocol
import ImageIO
import SwiftUI

@MainActor
final class CameraGridPreviewModel: ObservableObject {
    // Lifecycle cleanup is explicit; SwiftUI can release this outside a Swift task.
    nonisolated deinit {}

    enum Preview {
        case pending
        case hidden
        case thumbnail(CGImage, timestamp: Double)
        case live
    }

    static let pollingIntervalSeconds = 10.0

    @Published private var previews: [String: Preview] = [:]
    private var thumbnailCandidates: Set<String> = []
    private var thumbnailsUnsupported = false
    private var generation = UUID()
    private var client: HomeBaseWebSocketClient?
    private var cached: [String: (metadata: CameraThumbnail, image: CGImage)] = [:]
    private let tagRefresh = CameraFootageRefreshTask()
    private var tagSerial: UInt64 = 0
    private let makeTransport: @Sendable () async -> any CameraThumbnailFetching
    private let decode: (CameraThumbnail) throws -> CGImage
    private let sleep: @Sendable (Double) async throws -> Void

    init(
        client: HomeBaseWebSocketClient,
        decode: @escaping (CameraThumbnail) throws -> CGImage = CameraGridPreviewModel.decode,
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        makeTransport = { await client.makeHistoryTransport() }
        self.client = client
        self.decode = decode
        self.sleep = sleep
    }

    init(
        makeTransport: @escaping @Sendable () async -> any CameraThumbnailFetching,
        decode: @escaping (CameraThumbnail) throws -> CGImage,
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.makeTransport = makeTransport
        self.decode = decode
        self.sleep = sleep
    }

    func preview(for cameraID: String) -> Preview {
        previews[cameraID] ?? .pending
    }

    func run(cameras: [CameraVideoDevice]) async {
        let token = UUID()
        generation = token
        prepare(cameras)
        guard !thumbnailsUnsupported, !thumbnailCandidates.isEmpty else { return }

        var transport: any CameraThumbnailFetching = await makeTransport()
        if let client {
            let updates = await client.footageTagChanges()
            let instances = Dictionary(cameras.compactMap { camera -> (String, String)? in
                guard let metadata = CameraPlaybackHistoryAvailability.metadata(in: camera.device.metadata) else { return nil }
                return (metadata.cameraID.lowercased(), metadata.nvrInstanceID)
            }, uniquingKeysWith: { first, _ in first })
            let tagged = CameraTaggedHistorySource(source: transport, updates: updates) { query in
                guard let instance = instances[query.cameraID.lowercased()] else { throw CameraHistoryError.invalidResponse }
                return try await client.footageTagSnapshot(instanceID: instance, query: query)
            }
            await tagged.observe(); transport = tagged
        }
        var observer: Task<Void, Never>?
        if let source = transport as? any CameraFootageTagRefreshing {
            let stream = await source.tagChanges()
            observer = Task { [weak self] in
                for await _ in stream {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.tagSerial &+= 1
                    self.refreshFootageTags(cameras: cameras, source: source, token: token)
                }
            }
        }
        await transport.start()
        do {
            while !Task.isCancelled, generation == token {
                guard await refreshOnce(cameras: cameras, using: transport, token: token) else { break }
                try await sleep(Self.pollingIntervalSeconds)
            }
        } catch is CancellationError {
        } catch {
            // Individual requests already select or retain their fallback.
        }
        observer?.cancel()
        if generation == token { tagRefresh.cancel() }
        await transport.close()
    }

    private func refreshFootageTags(cameras: [CameraVideoDevice], source: any CameraFootageTagRefreshing, token: UUID) {
        tagRefresh.schedule { [weak self] revision in
            guard let self else { return }
            for camera in cameras {
                guard let metadata = CameraPlaybackHistoryAvailability.metadata(in: camera.device.metadata),
                      let entry = self.cached[camera.id] else { continue }
                do {
                    guard let image = try await source.refreshThumbnails([entry.metadata], cameraID: metadata.cameraID).first else { continue }
                    guard self.tagRefresh.isCurrent(revision), self.generation == token else { return }
                    guard self.cached[camera.id]?.metadata.timestamp == image.timestamp,
                          self.cached[camera.id]?.metadata.epochID == image.epochID else { continue }
                    self.cached[camera.id] = (image, entry.image)
                    self.previews[camera.id] = image.isHidden ? .hidden : .thumbnail(entry.image, timestamp: image.timestamp)
                } catch {
                    // Preserve the last accepted state. The next event or
                    // normal ten-second poll supplies another bounded attempt.
                }
            }
        }
    }

    /// Internal so the source-selection policy can be tested without a timer.
    @discardableResult
    func refreshOnce(
        cameras: [CameraVideoDevice],
        using transport: any CameraThumbnailFetching,
        token: UUID? = nil
    ) async -> Bool {
        prepare(cameras)
        let activeToken = token ?? generation
        guard !thumbnailsUnsupported else { return false }

        for camera in cameras {
            guard !Task.isCancelled, generation == activeToken else { return false }
            guard let metadata = CameraPlaybackHistoryAvailability.metadata(
                in: camera.device.metadata
            ) else { continue }

            do {
                let initialTagSerial = tagSerial
                let thumbnail = try await transport.thumbnail(HBNVRThumbnailRequest(
                    requestID: UUID().uuidString,
                    cameraID: metadata.cameraID,
                    timeline: "canonical",
                    timestamp: -0.3,
                    relativeTo: "live",
                    size: .init(width: 320, height: 180)
                ))
                try Task.checkCancellation()
                guard generation == activeToken else { return false }
                if let thumbnail {
                    let image = try decode(thumbnail)
                    self.cached[camera.id] = (.init(data: Data(), width: thumbnail.width, height: thumbnail.height,
                        timestamp: thumbnail.timestamp, isHidden: thumbnail.isHidden, epochID: thumbnail.epochID), image)
                    if tagSerial != initialTagSerial, let source = transport as? any CameraFootageTagRefreshing {
                        refreshFootageTags(cameras: cameras, source: source, token: activeToken)
                    }
                    if thumbnail.isHidden {
                        previews[camera.id] = .hidden
                        continue
                    }
                    previews[camera.id] = .thumbnail(
                        image,
                        timestamp: thumbnail.timestamp
                    )
                } else {
                    // No current recording coverage is a semantic absence, not
                    // a transport failure. Use live video until a later poll
                    // finds a recorded keyframe.
                    previews[camera.id] = .live
                }
            } catch is CancellationError {
                return false
            } catch CameraThumbnailError.unsupported {
                thumbnailsUnsupported = true
                for candidate in thumbnailCandidates {
                    previews[candidate] = .live
                }
                return false
            } catch {
                // Preserve a successfully decoded image through transient
                // worker/network failures. With no image yet, provide live.
                if case .some(.thumbnail) = previews[camera.id] { continue }
                if case .some(.hidden) = previews[camera.id] { continue }
                previews[camera.id] = .live
            }
        }
        return !thumbnailCandidates.isEmpty
    }

    private func prepare(_ cameras: [CameraVideoDevice]) {
        let cameraIDs = Set(cameras.map(\.id))
        previews = previews.filter { cameraIDs.contains($0.key) }
        cached = cached.filter { cameraIDs.contains($0.key) }
        let candidates = Set(cameras.compactMap { camera in
            CameraPlaybackHistoryAvailability.metadata(in: camera.device.metadata) == nil
                ? nil
                : camera.id
        })

        for camera in cameras {
            if candidates.contains(camera.id) {
                if !thumbnailCandidates.contains(camera.id), previews[camera.id] == nil {
                    previews[camera.id] = thumbnailsUnsupported ? .live : .pending
                }
            } else {
                previews[camera.id] = .live
            }
        }
        thumbnailCandidates = candidates
    }

    nonisolated static func decode(
        _ thumbnail: CameraThumbnail
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(thumbnail.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == thumbnail.width,
              properties[kCGImagePropertyPixelHeight] as? Int == thumbnail.height,
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.width == thumbnail.width,
              image.height == thumbnail.height else {
            throw CameraHistoryError.invalidResponse
        }
        return image
    }
}

struct CameraGridPreview: View {
    let camera: CameraVideoDevice
    let preview: CameraGridPreviewModel.Preview
    let client: HomeBaseWebSocketClient
    let isActive: Bool

    var body: some View {
        switch preview {
        case .pending:
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .accessibilityLabel("Loading camera preview")
        case .hidden:
            CameraVeilCover().aspectRatio(16 / 9, contentMode: .fit)
        case .thumbnail(let image, _):
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(16 / 9, contentMode: .fill)
                .clipped()
                .background(Color.black)
        case .live:
            CameraLiveVideoPlayer(
                deviceIdentifier: camera.device.addressableName,
                quality: CameraLiveQualitySelection(camera.capability.previewQuality),
                client: client,
                allowsRetry: false,
                isStreamEnabled: isActive,
                artificialFeed: camera.artificialFeed
            )
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
    }
}
