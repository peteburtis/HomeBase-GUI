import HomeBaseProtocol

nonisolated struct DeviceMetadataObservation {
    private(set) var metadata: [String: HBJSONValue] = [:]
    private var baseline: Int64?
    private var pending: [String: (sequence: Int64, value: HBJSONValue)] = [:]

    mutating func install(_ snapshot: [String: HBJSONValue], at sequence: Int64) {
        metadata = snapshot; baseline = sequence
        for (key, update) in pending where update.sequence > sequence { metadata[key] = update.value }
        baseline = max(sequence, pending.values.map(\.sequence).max() ?? sequence)
        pending.removeAll()
    }
    mutating func apply(key: String, value: HBJSONValue, sequence: Int64) -> Bool {
        guard let baseline else {
            // Only the latest replacement per key matters. Metadata is small,
            // but don't allow an unbounded pending map before a snapshot.
            if pending.count < 256 || pending[key] != nil { pending[key] = (sequence, value) }
            return false
        }
        guard sequence > baseline else { return false }
        metadata[key] = value
        self.baseline = sequence
        return true
    }
}
