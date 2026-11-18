import Foundation

/// Finds the pauses in an episode from its loudness over time, so playback
/// can hurry through them.
public enum SilenceFinder {
    /// - Parameters:
    ///   - levels: loudness of each successive window, in dBFS.
    ///   - window: length of one window in seconds.
    ///   - threshold: a window quieter than this is silent.
    ///   - minimumDuration: shorter pauses are natural speech rhythm and are left alone.
    ///   - padding: kept at each end so words aren't clipped.
    public static func silences(levels: [Float], window: TimeInterval, threshold: Float = -42,
                                minimumDuration: TimeInterval = 0.6, padding: TimeInterval = 0.15) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        var runStart: Int?
        func close(at end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let from = Double(start) * window + padding
            let to = Double(end) * window - padding
            if Double(end - start) * window >= minimumDuration, to > from { result.append(from...to) }
        }
        for (index, level) in levels.enumerated() {
            if level < threshold {
                if runStart == nil { runStart = index }
            } else {
                close(at: index)
            }
        }
        close(at: levels.count)
        return result
    }

    /// The silence containing `time`, if any (ranges must be sorted).
    public static func silence(at time: TimeInterval, in silences: [ClosedRange<TimeInterval>]) -> ClosedRange<TimeInterval>? {
        var low = 0
        var high = silences.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if silences[mid].upperBound < time {
                low = mid + 1
            } else if silences[mid].lowerBound > time {
                high = mid - 1
            } else {
                return silences[mid]
            }
        }
        return nil
    }
}
