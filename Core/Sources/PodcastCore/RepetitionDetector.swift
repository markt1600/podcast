import Foundation

/// Spots passages that are spoken word-for-word more than once: the same
/// sponsor read at the middle and end of an episode, an ad that also ran in
/// last week's episode, or the show's standard intro.
///
/// Real conversation never repeats itself verbatim for 15 seconds, so a long
/// repeated passage is reliably *not* content, even when it contains none of
/// the usual advertising phrases.
public enum RepetitionDetector {
    /// Words per shingle. Long enough that chance matches are negligible.
    static let shingle = 5

    /// Order-preserving shingle hashes of a transcript, small enough to keep
    /// for every analysed episode (about 8 bytes per word).
    public static func fingerprint(of segments: [TranscriptSegment]) -> [UInt64] {
        fingerprint(of: WordTrack(segments))
    }

    static func fingerprint(of track: WordTrack) -> [UInt64] {
        let words = track.words.map { $0.norm.filter { $0.isLetter || $0.isNumber } }
        guard words.count >= shingle else { return [] }
        return (0...(words.count - shingle)).map { index in
            // FNV-1a: stable across launches, unlike Swift's seeded Hasher.
            var hash: UInt64 = 0xcbf29ce484222325
            for word in words[index..<(index + shingle)] {
                for byte in word.utf8 {
                    hash = (hash ^ UInt64(byte)) &* 0x100000001b3
                }
                hash = (hash ^ 0x20) &* 0x100000001b3
            }
            return hash
        }
    }

    struct Repeat {
        var range: ClosedRange<TimeInterval>
        /// The passage also occurs in another episode (as opposed to only
        /// twice within this one).
        var external: Bool
    }

    /// Passages of `track` that also occur elsewhere in the same episode
    /// (at least a minute away) or in any of the reference fingerprints.
    static func repeats(in track: WordTrack, reference: Set<UInt64>, minimumDuration: TimeInterval = 15) -> [Repeat] {
        let hashes = fingerprint(of: track)
        guard !hashes.isEmpty else { return [] }

        var positions: [UInt64: [Int]] = [:]
        for (index, hash) in hashes.enumerated() { positions[hash, default: []].append(index) }

        var covered = [Bool](repeating: false, count: track.words.count)
        var external = [Bool](repeating: false, count: track.words.count)
        for (index, hash) in hashes.enumerated() {
            let inReference = reference.contains(hash)
            var repeated = inReference
            if !repeated, let others = positions[hash], others.count > 1 {
                let time = track.words[index].start
                repeated = others.contains { abs(track.words[$0].start - time) >= 60 }
            }
            if repeated {
                for offset in 0..<shingle {
                    covered[index + offset] = true
                    if inReference { external[index + offset] = true }
                }
            }
        }

        // Join covered runs across small holes left by recognition errors.
        var output: [Repeat] = []
        var runStart: Int?
        var lastCovered = 0
        var coveredCount = 0
        var externalCount = 0
        func close() {
            guard let start = runStart else { return }
            let duration = track.words[lastCovered].end - track.words[start].start
            let density = Double(coveredCount) / Double(lastCovered - start + 1)
            if duration >= minimumDuration, coveredCount >= 30, density >= 0.6 {
                output.append(Repeat(range: track.words[start].start...track.words[lastCovered].end,
                                     external: externalCount * 2 >= coveredCount))
            }
            runStart = nil
            coveredCount = 0
            externalCount = 0
        }
        for index in covered.indices where covered[index] {
            if runStart != nil, index - lastCovered > 12 || track.words[index].start - track.words[lastCovered].end > 6 { close() }
            if runStart == nil { runStart = index }
            lastCovered = index
            coveredCount += 1
            if external[index] { externalCount += 1 }
        }
        close()
        return output
    }
}
