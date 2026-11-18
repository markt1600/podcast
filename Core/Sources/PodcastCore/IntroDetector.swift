import Foundation

/// Finds where the episode proper begins, after the cold open, show intro
/// and any opening sponsor reads.
public struct IntroDetector: Sendable {
    /// Intros longer than this are not believed.
    public var maximumIntro: TimeInterval = 600

    public init() {}

    public func contentStart(in segments: [TranscriptSegment], ads: [AdSegment], chapters: [Chapter] = []) -> TimeInterval? {
        contentStart(in: WordTrack(segments), ads: ads, chapters: chapters)
    }

    func contentStart(in track: WordTrack, ads: [AdSegment], chapters: [Chapter]) -> TimeInterval? {
        var candidates: [TimeInterval] = []

        // Show notes: when the index opens at 0:00, its second entry is the first real topic.
        let sorted = chapters.sorted { $0.start < $1.start }
        if sorted.count >= 2, sorted[0].start <= 1, sorted[1].start >= 10, sorted[1].start <= maximumIntro {
            candidates.append(sorted[1].start)
        }

        // Transcript: the host hands over to the episode ("…please enjoy").
        if let handoff = Self.lastHandoff(in: track, before: maximumIntro) {
            candidates.append(handoff)
        }

        // Recurring intro material and opening ads that run from the very top.
        var cursor = 0.0
        for segment in ads.sorted(by: { $0.start < $1.start }) where segment.start <= cursor + 20 && segment.end <= maximumIntro {
            cursor = max(cursor, segment.end)
        }
        if cursor > 0 { candidates.append(cursor) }

        // Sources that agree to within a minute and a half describe the same
        // intro; take the latest. Otherwise trust the first source only.
        guard let first = candidates.first else { return nil }
        var start = candidates.filter { abs($0 - first) <= 90 }.max() ?? first
        // If that lands inside (or right before) an ad, start after the ad.
        for segment in ads.sorted(by: { $0.start < $1.start }) where segment.start <= start + 5 && segment.end > start {
            start = segment.end
        }
        return start >= 5 ? start : nil
    }

    private static let handoffs = try! NSRegularExpression(pattern: [
        #"\bplease enjoy\b"#,
        #"\bwithout further ado\b"#,
        #"\band now (for )?(my|our|the) (discussion|conversation|interview|chat)\b"#,
        #"\bhere'?s? (is )?(my|our) (discussion|conversation|interview|chat) with\b"#,
        #"\blet's (get started|get into it|dive in|jump in|get to it)\b"#,
        #"\bon with the show\b"#,
    ].joined(separator: "|"))

    /// End of the sentence containing the last hand-off phrase in the opening minutes.
    static func lastHandoff(in track: WordTrack, before limit: TimeInterval) -> TimeInterval? {
        guard !track.words.isEmpty else { return nil }
        let text = track.text as NSString
        var result: TimeInterval?
        for match in handoffs.matches(in: track.text, range: NSRange(location: 0, length: text.length)) {
            let index = track.wordIndex(atUTF16: match.range.location + match.range.length - 1)
            guard track.words[index].start <= limit else { break }
            result = track.words[track.sentenceEnd(after: index)].end
        }
        return result
    }
}
