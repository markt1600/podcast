import Foundation

/// Finds the pauses in an episode from its loudness over time, so playback
/// can hurry through them.
public enum SilenceFinder {
    /// - Parameters:
    ///   - levels: loudness of each successive window, in dBFS.
    ///   - window: length of one window in seconds.
    ///   - threshold: a window quieter than this is silent.
    ///   - minimumDuration: shorter pauses are natural speech rhythm and are left alone.
    ///   - leadIn: left untouched at the start of a pause, so the last word's tail is heard.
    ///   - leadOut: left untouched at the end, so playback is back to normal speed
    ///     comfortably before the next word begins.
    public static func silences(levels: [Float], window: TimeInterval, threshold: Float = -50,
                                minimumDuration: TimeInterval = 0.8, leadIn: TimeInterval = 0.15,
                                leadOut: TimeInterval = 0.35) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        var runStart: Int?
        func close(at end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let from = Double(start) * window + leadIn
            let to = Double(end) * window - leadOut
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

    /// A silence threshold suited to this recording: well below its normal
    /// speaking level, so quiet words and breaths are never mistaken for a
    /// pause, whether the episode was mastered loud or soft.
    public static func threshold(for levels: [Float]) -> Float {
        guard !levels.isEmpty else { return -50 }
        // Sample the levels; the upper quartile sits in ordinary speech.
        let step = max(1, levels.count / 20_000)
        let sample = stride(from: 0, to: levels.count, by: step).map { levels[$0] }.sorted()
        let speech = sample[min(sample.count - 1, sample.count * 3 / 4)]
        return min(-45, max(-62, speech - 30))
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
