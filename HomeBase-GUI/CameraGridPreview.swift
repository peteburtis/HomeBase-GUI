import Combine
import CoreGraphics
import Foundation
import HomeBaseProtocol
import ImageIO
import SwiftUI

@MainActor
final class CameraGridPreviewModel: ObservableObject {
    enum Preview {
        case pending
        case thumbnail(CGImage, timestamp: Double)
        case live
    }

    static let pollingIntervalSeconds = 10.0

    @Published private var previews: [String: Preview] = [:]
    private var thumbnailCandidates: Set<String> = []
    private var thumbnailsUnsupported = false
    private var generation = UUID()
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

        let transport = await makeTransport()
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
        await transport.close()
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
                    previews[camera.id] = .thumbnail(
                        try decode(thumbnail),
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
                previews[camera.id] = .live
            }
        }
        return !thumbnailCandidates.isEmpty
    }

    private func prepare(_ cameras: [CameraVideoDevice]) {
        let cameraIDs = Set(cameras.map(\.id))
        previews = previews.filter { cameraIDs.contains($0.key) }
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
                isStreamEnabled: isActive
            )
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
    }
}
