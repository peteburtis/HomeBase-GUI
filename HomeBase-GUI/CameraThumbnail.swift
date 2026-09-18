import Foundation
import HomeBaseProtocol

nonisolated enum CameraThumbnailError: Error { case unsupported }
nonisolated struct CameraThumbnail: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let timestamp: Double
}
nonisolated protocol CameraThumbnailFetching: CameraHistoryFetching {
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail?
}
extension CameraHistoryTransport: CameraThumbnailFetching {}

/// A thumbnail becomes usable only after a complete, validated End. Reuse the
/// media wire framing, without allowing a truncated JPEG to masquerade as a gap.
nonisolated struct CameraThumbnailParser {
    private struct Header: Decodable {
        let mimeType: String; let width: Int; let height: Int; let byteCount: Int
        let timestamp: Double; let keyFrame: Bool
    }
    private struct Record: Decodable {
        let type: String; let requestID: String
        let cameraID: String?; let timeline: String?; let timestamp: Double?; let anchor: Double?
        let thumbnail: Header?; let outcome: String?; let frames: Int?; let code: Int?; let error: String?
    }
    let request: HBNVRThumbnailRequest
    private var began = false
    private var header: Header?
    private var data = Data()
    private var records = 0
    private(set) var finished = false
    private(set) var result: CameraThumbnail?
    init(request: HBNVRThumbnailRequest) { self.request = request }
    mutating func text(_ data: Data) throws {
        guard !finished, data.count <= 65536, records < 3,
              header == nil || self.data.count == header!.byteCount else { throw CameraHistoryError.invalidResponse }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.requestID == request.requestID else { throw CameraHistoryError.invalidResponse }
        records += 1
        if record.type == "end", record.outcome == "error" {
            throw CameraHistoryError.remote(record.code, String((record.error ?? "Thumbnail unavailable").prefix(512)))
        }
        switch record.type {
        case "begin":
            guard !began, record.cameraID == request.cameraID, record.timeline == (request.timeline ?? "canonical"),
                  let timestamp = record.timestamp, timestamp.isFinite, abs(timestamp) < 1e11 else { throw CameraHistoryError.invalidResponse }
            if request.relativeTo == nil {
                guard record.anchor == nil, abs(timestamp - request.timestamp) < 0.001 else { throw CameraHistoryError.invalidResponse }
            } else {
                guard let anchor = record.anchor, anchor.isFinite, abs(anchor) < 1e11,
                      abs(timestamp - (anchor + request.timestamp)) < 0.001 else { throw CameraHistoryError.invalidResponse }
            }
            began = true
        case "thumbnail":
            guard began, header == nil, let image = record.thumbnail, image.mimeType == "image/jpeg", image.keyFrame,
                  (1...request.size.width).contains(image.width), (1...request.size.height).contains(image.height),
                  (1...8 * 1024 * 1024).contains(image.byteCount), image.timestamp.isFinite, abs(image.timestamp) < 1e11 else {
                throw CameraHistoryError.invalidResponse
            }
            header = image
        case "end":
            guard began else { throw CameraHistoryError.invalidResponse }
            if let header {
                guard record.outcome == "complete", record.frames == 1, self.data.count == header.byteCount else {
                    throw CameraHistoryError.invalidResponse
                }
                result = CameraThumbnail(data: self.data, width: header.width, height: header.height, timestamp: header.timestamp)
            } else {
                guard record.outcome == "unavailable", record.frames == 0 else { throw CameraHistoryError.invalidResponse }
            }
            finished = true
        default: throw CameraHistoryError.invalidResponse
        }
    }
    mutating func bytes(_ chunk: Data) throws {
        guard !finished, let header, !chunk.isEmpty, chunk.count <= 65536, data.count + chunk.count <= header.byteCount else {
            throw CameraHistoryError.invalidResponse
        }
        data.append(chunk)
    }
}
