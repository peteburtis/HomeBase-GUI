//
//  CameraLocalRecording.swift
//  HomeBase-GUI
//

import AVFoundation
import Combine
import Foundation

#if os(iOS)
import Photos
#endif

protocol CameraRecordingDestination {
    func prepare() async throws
    func saveVideo(at fileURL: URL, creationDate: Date) async throws
}

enum CameraRecordingDestinationError: LocalizedError {
    case unavailable
    case permissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Local camera recording is unavailable on this platform."
        case .permissionDenied:
            "HomeBase needs permission to add recorded video to Photos."
        case .saveFailed:
            "Photos did not save the camera recording."
        }
    }
}

#if os(iOS)
struct CameraPhotoLibraryRecordingDestination: CameraRecordingDestination {
    func prepare() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CameraRecordingDestinationError.permissionDenied
        }
    }

    func saveVideo(at fileURL: URL, creationDate: Date) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest
                    .creationRequestForAssetFromVideo(atFileURL: fileURL)
                request?.creationDate = creationDate
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing:
                        error ?? CameraRecordingDestinationError.saveFailed
                    )
                }
            }
        }
    }
}
#endif

@MainActor
final class CameraLocalRecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingAuthorization
        case waitingForKeyFrame
        case recording
        case saving
        case failed(String)
    }

    private struct StreamFormat {
        let generation: UInt32
        let formatDescription: CMVideoFormatDescription
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isStreamAvailable = false
    @Published private(set) var successfulSaveCount = 0
    @Published private(set) var recordingStartedAt: Date?

    private let destination: any CameraRecordingDestination
    private var streamOwnerID: UUID?
    private var streamFormat: StreamFormat?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var recordingCreationDate: Date?
    private var authorizationOperation = UUID()
    private var streamConfigurationRevision = 0
    private var pendingStreamOwnerID: UUID?
    private let configurationInstallationBarrier: (() async -> Void)?

    init(
        destination: any CameraRecordingDestination,
        configurationInstallationBarrier: (() async -> Void)? = nil
    ) {
        self.destination = destination
        self.configurationInstallationBarrier =
            configurationInstallationBarrier
    }

    var isRecording: Bool {
        switch state {
        case .waitingForKeyFrame, .recording:
            true
        case .idle, .requestingAuthorization, .saving, .failed:
            false
        }
    }

    var locksStreamConfiguration: Bool {
        switch state {
        case .requestingAuthorization, .waitingForKeyFrame, .recording, .saving:
            true
        case .idle, .failed:
            false
        }
    }

    var errorMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    func toggle() {
        Task {
            if isRecording {
                await stopAndSave()
            } else {
                await start()
            }
        }
    }

    func start() async {
        guard isStreamAvailable,
              streamFormat != nil,
              !locksStreamConfiguration else {
            return
        }

        let operation = UUID()
        authorizationOperation = operation
        state = .requestingAuthorization
        do {
            try await destination.prepare()
            guard authorizationOperation == operation,
                  isStreamAvailable,
                  streamFormat != nil else {
                return
            }
            recordingCreationDate = Date()
            state = .waitingForKeyFrame
        } catch {
            guard authorizationOperation == operation else { return }
            fail(error)
        }
    }

    @discardableResult
    func configure(
        ownerID: UUID,
        generation: UInt32,
        formatDescription: CMVideoFormatDescription
    ) async -> Bool {
        streamConfigurationRevision &+= 1
        let revision = streamConfigurationRevision
        pendingStreamOwnerID = ownerID
        defer {
            if streamConfigurationRevision == revision {
                pendingStreamOwnerID = nil
            }
        }
        if writer != nil,
           (streamOwnerID != ownerID
                || streamFormat?.generation != generation) {
            await stopAndSave()
        }
        await configurationInstallationBarrier?()
        guard streamConfigurationRevision == revision,
              pendingStreamOwnerID == ownerID else {
            return false
        }
        streamOwnerID = ownerID
        streamFormat = StreamFormat(
            generation: generation,
            formatDescription: formatDescription
        )
        isStreamAvailable = true
        return true
    }

    func append(
        _ sampleBuffer: CMSampleBuffer,
        ownerID: UUID,
        generation: UInt32,
        isKeyFrame: Bool
    ) {
        guard isRecording,
              streamOwnerID == ownerID,
              streamFormat?.generation == generation else {
            return
        }

        do {
            if writer == nil {
                guard isKeyFrame,
                      let streamFormat else { return }
                try beginWriting(
                    sampleBuffer,
                    formatDescription: streamFormat.formatDescription
                )
                recordingStartedAt = Date()
                state = .recording
            }

            guard let writer,
                  let writerInput,
                  writer.status == .writing else {
                throw writer?.error ?? CameraRecordingError.writerUnavailable
            }
            guard writerInput.isReadyForMoreMediaData else {
                throw CameraRecordingError.writerBackPressure
            }
            guard writerInput.append(sampleBuffer) else {
                throw writer.error ?? CameraRecordingError.appendFailed
            }
        } catch {
            cancelWriter()
            fail(error)
        }
    }

    func streamDidEnd(ownerID: UUID) async {
        if pendingStreamOwnerID == ownerID {
            streamConfigurationRevision &+= 1
            pendingStreamOwnerID = nil
        }
        guard streamOwnerID == ownerID else { return }
        isStreamAvailable = false
        streamOwnerID = nil
        streamFormat = nil
        authorizationOperation = UUID()
        await stopAndSave()
    }

    func stopAndSave() async {
        guard state != .saving else { return }
        authorizationOperation = UUID()

        guard let writer, let writerInput, let outputURL else {
            cancelWriter()
            if errorMessage == nil { state = .idle }
            recordingCreationDate = nil
            return
        }

        let creationDate = recordingCreationDate ?? Date()
        self.writer = nil
        self.writerInput = nil
        self.outputURL = nil
        recordingCreationDate = nil
        recordingStartedAt = nil
        state = .saving

        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        do {
            guard writer.status == .completed else {
                throw writer.error ?? CameraRecordingError.finishFailed
            }
            try await destination.saveVideo(
                at: outputURL,
                creationDate: creationDate
            )
            try? FileManager.default.removeItem(at: outputURL)
            state = .idle
            successfulSaveCount &+= 1
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            fail(error)
        }
    }

    func dismissError() {
        guard errorMessage != nil else { return }
        state = .idle
    }

    private func beginWriting(
        _ firstSampleBuffer: CMSampleBuffer,
        formatDescription: CMVideoFormatDescription
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeBase-Camera-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CameraRecordingError.cannotAddVideoInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CameraRecordingError.writerUnavailable
        }
        writer.startSession(
            atSourceTime: CMSampleBufferGetPresentationTimeStamp(
                firstSampleBuffer
            )
        )

        self.writer = writer
        writerInput = input
        outputURL = url
    }

    private func cancelWriter() {
        writer?.cancelWriting()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        writer = nil
        writerInput = nil
        outputURL = nil
        recordingCreationDate = nil
        recordingStartedAt = nil
    }

    private func fail(_ error: Error) {
        state = .failed(error.localizedDescription)
    }
}

private enum CameraRecordingError: LocalizedError {
    case cannotAddVideoInput
    case writerUnavailable
    case writerBackPressure
    case appendFailed
    case finishFailed

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            "The camera's H.264 format could not be added to a movie."
        case .writerUnavailable:
            "The local movie writer could not start."
        case .writerBackPressure:
            "The device could not write camera video quickly enough."
        case .appendFailed:
            "The camera frame could not be added to the recording."
        case .finishFailed:
            "The local camera recording could not be finalized."
        }
    }
}
