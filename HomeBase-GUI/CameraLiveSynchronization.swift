import Foundation

/// Compare received source heads, never displayed/held pictures. The window is
/// both a clock-disagreement escape valve and the maximum stall hold.
nonisolated struct CameraLiveSynchronization {
    static let maximumDelay: Double = 2.5
    struct Head: Equatable {
        let id: String
        let cameraUTC: Double
        let receivedAt: Double
    }
    private var previousMembers: Set<String> = []

    mutating func targets(for heads: [Head], now: Double) -> [String: Double] {
        let eligible = heads.filter {
            $0.cameraUTC.isFinite && abs($0.cameraUTC) < 1e11 && $0.receivedAt.isFinite
                && now >= $0.receivedAt && now - $0.receivedAt <= Self.maximumDelay
        }.sorted { $0.cameraUTC == $1.cameraUTC ? $0.id < $1.id : $0.cameraUTC < $1.cameraUTC }
        // With three or four cameras, one wildly advanced clock must not
        // disqualify an otherwise coherent group. Prefer the largest bounded
        // group, then continuity, then the freshest group on a tie.
        var best: [Head] = []
        var overlap = -1
        for start in eligible.indices {
            let group = Array(eligible[start...].prefix { $0.cameraUTC - eligible[start].cameraUTC <= Self.maximumDelay })
            let common = group.filter { previousMembers.contains($0.id) }.count
            if group.count > best.count || (group.count == best.count && common >= overlap) {
                best = group; overlap = common
            }
        }
        guard best.count >= 2, let target = best.first?.cameraUTC else {
            previousMembers = []; return [:]
        }
        previousMembers = Set(best.map(\.id))
        return Dictionary(uniqueKeysWithValues: best.map { ($0.id, target) })
    }
}
