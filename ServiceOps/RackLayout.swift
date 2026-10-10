import Foundation

/// Converts a recorded bottom-based U position to a top-based diagram offset.
/// Missing or invalid measurements stay unplaced rather than being guessed.
enum RackLayout {
    static func offset(capacity: Int, position: Double?, height: Int?) -> Double? {
        guard capacity > 0, capacity <= 120,
              let position, position.isFinite, position >= 1,
              let height, height > 0,
              position + Double(height) - 1 <= Double(capacity) else { return nil }
        return Double(capacity) - position - Double(height) + 1
    }

    static func hasOverlap(capacity: Int, placements: [(position: Double?, height: Int?)]) -> Bool {
        let intervals = placements.compactMap { placement -> (start: Double, end: Double)? in
            guard offset(capacity: capacity, position: placement.position, height: placement.height) != nil,
                  let position = placement.position, let height = placement.height else { return nil }
            return (position, position + Double(height))
        }.sorted { $0.start < $1.start }
        var end = -Double.infinity
        for interval in intervals {
            if interval.start < end { return true }
            end = max(end, interval.end)
        }
        return false
    }

}
