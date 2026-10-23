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

struct CameraLocalRecording: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let creationDate: Date

    init(
        id: UUID = UUID(),
        fileURL: URL,
        creationDate: Date
    ) {
        self.id = id
        self.fileURL = fileURL
        self.creationDate = creationDate
    }

    var filename: String { fileURL.lastPathComponent }
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
        case waitingForKeyFrame
        case recording
        case finalizing
        case exporting
        case failed(String)
    }

    private struct StreamFormat {
        let generation: UInt32
        let formatDescription: CMVideoFormatDescription
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isStreamAvailable = false
    @Published private(set) var successfulExportCount = 0
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var pendingRecording: CameraLocalRecording?

    private let destination: any CameraRecordingDestination
    private var streamOwnerID: UUID?
    private var streamFormat: StreamFormat?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var recordingCreationDate: Date?
    private var recordingFilename: String?
    private var streamConfigurationRevision = 0
    private var pendingStreamOwnerID: UUID?
    private let configurationInstallationBarrier: (() async -> Void)?

    init(
        destination: any CameraRecordingDestination,
        pendingRecording: CameraLocalRecording? = nil,
        configurationInstallationBarrier: (() async -> Void)? = nil
    ) {
        self.destination = destination
        self.pendingRecording = pendingRecording
        self.configurationInstallationBarrier =
            configurationInstallationBarrier
    }

    var isRecording: Bool {
        switch state {
        case .waitingForKeyFrame, .recording:
            true
        case .idle, .finalizing, .exporting, .failed:
            false
        }
    }

    var locksStreamConfiguration: Bool {
        if pendingRecording != nil { return true }
        switch state {
        case .waitingForKeyFrame, .recording, .finalizing, .exporting:
            return true
        case .idle, .failed:
            return false
        }
    }

    var errorMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    func start(suggestedFilename: String? = nil) async {
        guard isStreamAvailable,
              streamFormat != nil,
              pendingRecording == nil,
              !locksStreamConfiguration else {
            return
        }

        let creationDate = Date()
        recordingCreationDate = creationDate
        recordingFilename = Self.filename(
            cameraName: suggestedFilename,
            creationDate: creationDate
        )
        state = .waitingForKeyFrame
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
            await stop()
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
        await stop()
    }

    func stop() async {
        guard state != .finalizing, state != .exporting else { return }

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
        recordingFilename = nil
        recordingStartedAt = nil
        state = .finalizing

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
            pendingRecording = CameraLocalRecording(
                fileURL: outputURL,
                creationDate: creationDate
            )
            state = .idle
        } catch {
            Self.removeRecordingFile(at: outputURL)
            fail(error)
        }
    }

    @discardableResult
    func savePendingRecordingToPhotos() async -> Bool {
        guard let pendingRecording, state == .idle else { return false }
        state = .exporting
        do {
            try await destination.prepare()
            try await destination.saveVideo(
                at: pendingRecording.fileURL,
                creationDate: pendingRecording.creationDate
            )
            completePendingExport()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func completePendingExport() {
        guard let pendingRecording else { return }
        Self.removeRecordingFile(at: pendingRecording.fileURL)
        self.pendingRecording = nil
        state = .idle
        successfulExportCount &+= 1
    }

    func discardPendingRecording() {
        guard let pendingRecording else { return }
        Self.removeRecordingFile(at: pendingRecording.fileURL)
        self.pendingRecording = nil
        state = .idle
    }

    func dismissError() {
        guard errorMessage != nil else { return }
        state = .idle
    }

    private func beginWriting(
        _ firstSampleBuffer: CMSampleBuffer,
        formatDescription: CMVideoFormatDescription
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HomeBase-Camera-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            recordingFilename ?? Self.filename(
                cameraName: nil,
                creationDate: Date()
            )
        )
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
            Self.removeRecordingFile(at: outputURL)
        }
        writer = nil
        writerInput = nil
        outputURL = nil
        recordingCreationDate = nil
        recordingFilename = nil
        recordingStartedAt = nil
    }

    private func fail(_ error: Error) {
        state = .failed(error.localizedDescription)
    }

    static func filename(
        cameraName: String?,
        creationDate: Date
    ) -> String {
        let unsafeCharacters = CharacterSet(charactersIn: "/:\\")
        let cleanedName = (cameraName ?? "Camera")
            .components(separatedBy: unsafeCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let timestamp = formatter.string(from: creationDate)
        return "\(cleanedName.isEmpty ? "Camera" : cleanedName) \(timestamp).mov"
    }

    static func removeRecordingFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if directory.lastPathComponent.hasPrefix("HomeBase-Camera-") {
            try? FileManager.default.removeItem(at: directory)
        }
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
