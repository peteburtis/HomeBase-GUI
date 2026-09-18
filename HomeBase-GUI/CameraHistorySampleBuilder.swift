import CoreMedia
import Foundation

enum CameraHistorySampleBuilder {
    static func format(_ segment: CameraHistorySegment) throws -> CMVideoFormatDescription {
        try segment.validate()
        let parameters = segment.parameterSets.map { $0 as NSData }
        let pointers = parameters.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = parameters.map(\.length)
        var description: CMFormatDescription?
        let status = withExtendedLifetime(parameters) {
            if segment.codec == "H264" {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(segment.nalUnitLengthBytes), formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(segment.nalUnitLengthBytes), extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else {
            throw CameraH264Renderer.RendererError.mediaFrameworkFailure("History decoder configuration", status)
        }
        return description
    }

    static func sample(_ sample: CameraHistorySample, segment: CameraHistorySegment,
                       format: CMVideoFormatDescription, origin: Int64, display: Bool) throws -> CMSampleBuffer {
        guard CameraHistoryResponseParser.validAccessUnit(sample.data, lengthBytes: segment.nalUnitLengthBytes) else {
            throw CameraH264Renderer.RendererError.invalidAccessUnit
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: sample.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: sample.data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else {
            throw CameraH264Renderer.RendererError.mediaFrameworkFailure("History buffer creation", status)
        }
        status = sample.data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: sample.data.count)
        }
        guard status == noErr else { throw CameraH264Renderer.RendererError.mediaFrameworkFailure("History buffer copy", status) }
        let scale = Int32(segment.timescale)
        let zero = CMTime(value: origin, timescale: scale)
        var timing = CMSampleTimingInfo(duration: CMTime(value: sample.frame.durationTicks, timescale: scale),
            presentationTimeStamp: CMTimeSubtract(CMTime(value: sample.frame.presentationTicks, timescale: scale), zero),
            decodeTimeStamp: sample.frame.decodeTicks.map { CMTimeSubtract(CMTime(value: $0, timescale: scale), zero) } ?? .invalid)
        var size = sample.data.count
        var buffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw CameraH264Renderer.RendererError.mediaFrameworkFailure("History sample creation", status) }
        if let values = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary], let value = values.first {
            value[kCMSampleAttachmentKey_DisplayImmediately] = true
            value[kCMSampleAttachmentKey_DoNotDisplay] = !display
            value[kCMSampleAttachmentKey_NotSync] = !sample.frame.keyFrame
        }
        return buffer
    }
}
