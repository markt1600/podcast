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
        let cues = detector.cues(in: track).filter { $0.weight >= 3 }
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
        segments = AdDetector.merge(segments)

        let contentStart = IntroDetector().contentStart(in: track, ads: segments, chapters: chapters,
                                                        episodeTitle: evidence.episodeTitle)
        return EpisodeAnalysis(segments: segments, contentStart: contentStart,
                               fingerprint: RepetitionDetector.fingerprint(of: track))
    }
}
