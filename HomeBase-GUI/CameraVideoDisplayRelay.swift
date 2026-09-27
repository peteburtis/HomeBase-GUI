import AVFoundation

/// Additional displays consume the main player's samples without owning its
/// stream, clock, decoder state, or authorization.
@MainActor
protocol CameraVideoDisplayOutput: AnyObject {
    var needsRecovery: Bool { get }
    func enqueue(_ sample: CMSampleBuffer)
    func flush(removingDisplayedImage: Bool)
}

@MainActor
final class CameraVideoDisplayReplica: CameraVideoDisplayOutput {
    let layer = AVSampleBufferDisplayLayer()

    // The surface explicitly detaches/flushes before releasing this object.
    nonisolated deinit {}

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    var needsRecovery: Bool {
        layer.sampleBufferRenderer.status == .failed
            || !layer.sampleBufferRenderer.isReadyForMoreMediaData
    }

    func enqueue(_ sample: CMSampleBuffer) {
        layer.sampleBufferRenderer.enqueue(sample)
    }

    func flush(removingDisplayedImage: Bool) {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: removingDisplayedImage,
            completionHandler: nil)
    }
}

@MainActor
final class CameraVideoDisplayRelay {
    private struct Destination {
        weak var output: (any CameraVideoDisplayOutput)?
        var waitingForKeyframe = true
    }

    private var destinations: [ObjectIdentifier: Destination] = [:]
    private var samples: [CMSampleBuffer] = []
    private var sampleBytes = 0
    private var waitingForKeyframe = true
    private let maximumBytes: Int
    private let maximumSamples: Int

    // No actor-bound teardown: destinations are weak and samples are values.
    nonisolated deinit {}

    // Retain only a bounded GOP so connecting while paused can show the same
    // picture immediately. No additional network subscription or replay clock.
    init(maximumBytes: Int = 8 * 1_024 * 1_024, maximumSamples: Int = 240) {
        self.maximumBytes = maximumBytes
        self.maximumSamples = maximumSamples
    }

    func attach(_ output: any CameraVideoDisplayOutput) {
        prune()
        let id = ObjectIdentifier(output)
        guard destinations[id] == nil else { return }
        let displayedIndex = samples.lastIndex { sample in
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[String: Any]]
            return attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool != true
        }
        // Decode dependencies, but show only the final visible picture. Copies
        // keep bootstrap attachments from changing the phone's samples.
        for (index, sample) in samples.enumerated() {
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
                sampleBuffer: sample, sampleBufferOut: &copy) == noErr, let copy else { continue }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true)
                as? [NSMutableDictionary], let attachment = attachments.first {
                attachment[kCMSampleAttachmentKey_DoNotDisplay] = index != displayedIndex
            }
            output.enqueue(copy)
        }
        destinations[id] = Destination(output: output,
            waitingForKeyframe: waitingForKeyframe || samples.isEmpty)
    }

    func detach(_ output: any CameraVideoDisplayOutput) {
        destinations.removeValue(forKey: ObjectIdentifier(output))
        output.flush(removingDisplayedImage: true)
    }

    func enqueue(_ sample: CMSampleBuffer, keyFrame: Bool) {
        if keyFrame {
            samples.removeAll(keepingCapacity: true)
            sampleBytes = 0
            waitingForKeyframe = false
        }
        if !waitingForKeyframe {
            let bytes = CMSampleBufferGetTotalSampleSize(sample)
            if samples.count < maximumSamples, bytes <= maximumBytes - sampleBytes {
                samples.append(sample)
                sampleBytes += bytes
            } else {
                samples.removeAll(keepingCapacity: true)
                sampleBytes = 0
                waitingForKeyframe = true
            }
        }

        prune()
        for id in Array(destinations.keys) {
            guard var destination = destinations[id], let output = destination.output else { continue }
            if output.needsRecovery {
                output.flush(removingDisplayedImage: false)
                destination.waitingForKeyframe = true
            }
            if keyFrame { destination.waitingForKeyframe = false }
            if !destination.waitingForKeyframe { output.enqueue(sample) }
            destinations[id] = destination
        }
    }

    func flush(removingDisplayedImage: Bool) {
        // A preserving flush is used for paused seeks and quality changes.
        // Keep its last GOP available for a newly connected display until a new
        // keyframe arrives, but never feed dependent frames into that old GOP.
        if removingDisplayedImage {
            samples.removeAll(keepingCapacity: true)
            sampleBytes = 0
        }
        waitingForKeyframe = true
        prune()
        for id in Array(destinations.keys) {
            destinations[id]?.output?.flush(removingDisplayedImage: removingDisplayedImage)
            destinations[id]?.waitingForKeyframe = true
        }
    }

    private func prune() {
        destinations = destinations.filter { $0.value.output != nil }
    }
}
