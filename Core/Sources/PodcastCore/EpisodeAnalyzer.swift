import Foundation

/// Everything known about an episode that can help locate non-content.
public struct EpisodeEvidence: Sendable {
    /// Timed transcript of the audio that will actually be played, if available.
    public var transcript: [TranscriptSegment] = []
    /// True if `transcript` was made from the exact audio file being played
    /// (as opposed to a publisher transcript of the ad-free master).
    public var transcriptMatchesAudio = true
    /// Episode description, with line breaks preserved.
    public var showNotes = ""
    /// Chapters from a `podcast:chapters` file.
    public var chapters: [Chapter] = []
    public var duration: TimeInterval?
    /// Show title and author; used to tell house plugs from sponsor reads.
    public var showName = ""
    public var episodeTitle = ""
    /// Fingerprints of other analysed episodes, for spotting recurring reads.
    public var reference: Set<UInt64> = []

    public init() {}
}

public struct EpisodeAnalysis: Sendable {
    public var segments: [AdSegment]
    /// Where the episode proper begins; nil if unknown.
    public var contentStart: TimeInterval?
    /// Keep this to pass as `reference` when analysing later episodes.
    public var fingerprint: [UInt64]
}

/// Combines all sources of evidence into one list of segments to skip.
public struct EpisodeAnalyzer: Sendable {
    public var detector = AdDetector()

    public init() {}

    private static let breakOut = try! NSRegularExpression(pattern:
        #"\b(we'll|we will|we'll all) be (right )?back\b|\b(right )?after (the|this|a quick|a short|a) break\b|\bmore after this\b"#)
    private static let breakIn = try! NSRegularExpression(pattern:
        #"\b(and )?(now )?back to the (show|episode|conversation|interview|program)\b|\bwelcome back\b|\band we're back\b"#)

    /// "We'll be right back … and now back to the show": everything between
    /// the two is the ad break, whatever is said in it.
    static func announcedBreaks(in track: WordTrack, cues: [AdDetector.Cue], maximumLength: TimeInterval = 420) -> [AdSegment] {
        guard !track.words.isEmpty else { return [] }
        let text = track.text as NSString
        let whole = NSRange(location: 0, length: text.length)
        let returns = breakIn.matches(in: track.text, range: whole).map { track.wordIndex(atUTF16: $0.range.location) }
        var output: [AdSegment] = []
        for match in breakOut.matches(in: track.text, range: whole) {
            let outWord = track.sentenceEnd(after: track.wordIndex(atUTF16: match.range.location + match.range.length - 1))
            guard outWord + 1 < track.words.count else { continue }
            let start = track.words[outWord + 1].start
            guard start >= (output.last?.end ?? 0),
                  let inWord = returns.first(where: { track.words[$0].start > start }) else { continue }
            let end = track.words[track.sentenceStart(before: inWord)].start
            // Needs to look like a break: a plausible length and at least one sponsor named.
            guard end - start >= 15, end - start <= maximumLength,
                  cues.contains(where: { ($0.weight >= 3 || $0.brand != nil) && (start...end).contains(track.words[$0.first].start) })
            else { continue }
            output.append(AdSegment(start: start, end: end, confidence: 0.95, reason: "announced ad break"))
        }
        return output
    }

    /// Inserted ads leave a beat of silence at every join, and conversation
    /// almost never pauses that long. So an ad that starts or ends near such
    /// a pause really starts or ends *at* it, and a short stretch of speech
    /// fenced by pauses right next to an ad is another spot in the same break
    /// (many carry no advertising language at all).
    static func expandToEditPoints(_ segments: [AdSegment], in track: WordTrack, editPause: TimeInterval) -> [AdSegment] {
        let words = track.words
        guard words.count > 1 else { return segments }
        // Slots: stretches of continuous speech between edit pauses.
        var slots: [ClosedRange<TimeInterval>] = []
        var slotStart = words[0].start
        var longSilences = 0
        for index in 0..<(words.count - 1) {
            let gap = words[index + 1].start - words[index].end
            guard gap >= editPause else { continue }
            if gap > 30 { longSilences += 1 }
            slots.append(slotStart...max(slotStart, words[index].end))
            slotStart = words[index + 1].start
        }
        slots.append(slotStart...max(slotStart, words[words.count - 1].end))
        // Music and clip shows are full of gaps that mean nothing of the sort.
        guard slots.count > 1, longSilences < 2 else { return segments }

        let spotLength: ClosedRange<TimeInterval> = 8...75
        var output: [AdSegment] = []
        for var segment in segments {
            guard segment.kind == .ad,
                  var first = slots.firstIndex(where: { segment.start <= $0.upperBound }),
                  var last = slots.lastIndex(where: { segment.end >= $0.lowerBound }), first <= last else {
                output.append(segment)
                continue
            }
            if segment.start - slots[first].lowerBound <= 45 { segment.start = min(segment.start, slots[first].lowerBound) }
            if slots[last].upperBound - segment.end <= 20 { segment.end = max(segment.end, slots[last].upperBound) }

            var added = 0
            while added < 5, first > 0, segment.start <= slots[first].lowerBound + 0.01,
                  spotLength.contains(slots[first - 1].upperBound - slots[first - 1].lowerBound) {
                first -= 1
                segment.start = slots[first].lowerBound
                added += 1
            }
            added = 0
            while added < 5, last + 1 < slots.count, segment.end >= slots[last].upperBound - 0.01,
                  spotLength.contains(slots[last + 1].upperBound - slots[last + 1].lowerBound) {
                last += 1
                segment.end = slots[last].upperBound
                added += 1
            }
            output.append(segment)
        }
        return AdDetector.merge(output)
    }

    public func analyze(_ evidence: EpisodeEvidence) -> EpisodeAnalysis {
        var detector = detector
        if detector.options.showName.isEmpty { detector.options.showName = evidence.showName }
        let track = WordTrack(evidence.transcript)
        let chapters = (evidence.chapters + ShowNotes.chapters(from: evidence.showNotes)).sorted { $0.start < $1.start }

        // 1. Sponsor reads recognised from what is said, reconciled with what
        //    the publisher's own index says.
        let spoken = detector.detect(in: track)
        let listed = detector.detect(in: chapters, episodeDuration: evidence.duration)
        var segments = AdDetector.reconcile(measured: spoken, approximate: listed)

        // 2. Verbatim repeats.
        let allCues = detector.cues(in: track)
        let cues = allCues.filter { $0.weight >= 3 }
        segments = AdDetector.merge(segments, Self.announcedBreaks(in: track, cues: allCues))
        for found in RepetitionDetector.repeats(in: track, reference: evidence.reference) {
            let range = found.range
            if let index = segments.firstIndex(where: { $0.kind == .ad && $0.start < range.upperBound && $0.end > range.lowerBound }) {
                // The repeat is this ad's script: it knows the true edges, including
                // a lead-in that contains no advertising language.
                segments[index].start = min(segments[index].start, range.lowerBound)
                segments[index].end = max(segments[index].end, range.upperBound)
                continue
            }
            let hasCue = cues.contains { range.contains(track.words[$0.first].start) }
            // The same spot inserted twice in one episode names somebody's website.
            let namesSponsor = allCues.contains { $0.brand != nil && range.contains(track.words[$0.first].start) }
            if !found.external, hasCue || namesSponsor {
                segments.append(AdSegment(start: range.lowerBound, end: range.upperBound, confidence: 0.85,
                                          reason: "same spot played twice"))
                continue
            }
            let nearStart = range.lowerBound < 300
            let nearEnd = evidence.duration.map { range.upperBound > $0 - 300 } ?? false
            if nearStart || (nearEnd && found.external) {
                // Standard show intro/outro (which may well thank "our sponsors" or
                // plug a newsletter), or a cold-open teaser replaying a later clip.
                segments.append(AdSegment(start: range.lowerBound, end: range.upperBound, confidence: 0.8,
                                          reason: found.external ? "recurring intro or outro" : "teaser of a later clip",
                                          kind: .boilerplate))
            } else if hasCue {
                segments.append(AdSegment(start: range.lowerBound, end: range.upperBound, confidence: 0.85,
                                          reason: "sponsor or promo read, repeated word for word"))
            } else if found.external {
                // Mid-episode and heard verbatim in another episode: an inserted ad.
                segments.append(AdSegment(start: range.lowerBound, end: range.upperBound, confidence: 0.7,
                                          reason: "also heard in another episode"))
            }
            // Otherwise it is the original of a clip teased at the top: real content.
        }
        segments = Self.expandToEditPoints(AdDetector.merge(segments), in: track, editPause: detector.options.editPause)

        let contentStart = IntroDetector().contentStart(in: track, ads: segments, chapters: chapters,
                                                        episodeTitle: evidence.episodeTitle)
        return EpisodeAnalysis(segments: segments, contentStart: contentStart,
                               fingerprint: RepetitionDetector.fingerprint(of: track))
    }
}
