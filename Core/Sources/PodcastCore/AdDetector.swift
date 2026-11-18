import Foundation

/// Finds advertisements in an episode from a timed transcript.
///
/// Sponsor reads follow a recognisable shape. They are opened with an
/// attribution ("I'd like to thank our sponsor…", "this episode is brought
/// to you by…") and/or closed with a call to action built around a vanity
/// URL or promo code, usually said twice. In between there can be a minute
/// of ordinary-sounding talk, so the detector does not score the middle;
/// it finds those strong cues, groups the ones that sit close together, and
/// then works out where the read begins and ends:
///
///  * the end is the end of the sentence holding the last cue;
///  * the start is the first cue, pulled back to the first mention of the
///    sponsor's name (taken from its URL) so story-style lead-ins are covered.
///
/// A lone cue is never enough: a block needs several pieces of independent
/// evidence, which keeps passing mentions in real content from being skipped.
public struct AdDetector: Sendable {
    public struct Options: Sendable {
        /// Strong cues closer together than this belong to one ad block.
        public var maxCueGap: TimeInterval = 100
        /// Minimum summed cue weight for a block.
        public var minimumScore = 5.5
        /// How far before the first cue a sponsor's name may pull the start.
        public var brandLookback: TimeInterval = 150
        /// A silence at least this long marks an edit point.
        public var editPause: TimeInterval = 2.5
        /// How far before a story-style read to look for its edit point.
        public var pauseLookback: TimeInterval = 75
        /// How far after the last cue to look for the closing edit point.
        public var pauseLookahead: TimeInterval = 12
        /// Shorter detections are discarded as passing mentions.
        public var minimumDuration: TimeInterval = 12
        /// Longer detections are implausible and discarded.
        public var maximumDuration: TimeInterval = 600
        /// The show's own name and host, e.g. "The Tim Ferriss Show Tim Ferriss".
        /// Web addresses on the show's own site (newsletter, show notes, the
        /// host's side projects) are house plugs, not sponsor reads.
        public var showName = ""

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Transcript based detection

    public func detect(in segments: [TranscriptSegment]) -> [AdSegment] {
        detect(in: WordTrack(segments))
    }

    func detect(in track: WordTrack) -> [AdSegment] {
        let cues = cues(in: track)
        let strong = cues.filter { $0.weight >= 3 }
        guard !strong.isEmpty else { return [] }

        // Group strong cues that sit close together.
        var groups: [[Cue]] = []
        for cue in strong {
            if let last = groups.last?.last, track.words[cue.first].start - track.words[last.last].end <= options.maxCueGap {
                groups[groups.count - 1].append(cue)
            } else {
                groups.append([cue])
            }
        }

        let urlCues = cues.filter { $0.brand != nil }
        var output: [AdSegment] = []
        var previousEnd = -Double.infinity

        for group in groups {
            var firstWord = group.first!.first
            var lastWord = group.map(\.last).max()!
            let groupStart = track.words[firstWord].start
            let groupEnd = track.words[lastWord].end

            // Weak cues count as supporting evidence when they sit inside the block,
            // and a trailing one ("…or head to acme.com") extends it.
            let support = cues.filter {
                // A produced spot names its sponsor up front and its website half a minute later.
                $0.weight < 3 && track.words[$0.first].start >= groupStart - ($0.brand != nil ? 45 : 20)
                    && track.words[$0.first].start <= groupEnd + ($0.brand != nil ? 45 : 15)
            }
            let score = group.reduce(0) { $0 + $1.weight } + min(3, support.reduce(0) { $0 + $1.weight })
            let labels = Set(group.map(\.label) + support.map(\.label))
            guard score >= options.minimumScore, labels.count >= 2 else { continue }
            if let trailing = support.map(\.last).max(), trailing > lastWord { lastWord = trailing }
            // A sponsor's website named just before the first strong cue is part of the block too.
            if let leading = support.filter({ $0.brand != nil }).map(\.first).min(), leading < firstWord { firstWord = leading }

            // Pull the start back to the sentence, then to the sponsor's first mention.
            // A read that opens by naming its sponsor starts right there. One that
            // opens with a story only reveals itself at the URL, so look back for
            // where the sponsor was first mentioned.
            let opensWithAttribution = group.first!.label == "sponsor attribution"
            firstWord = track.sentenceStart(before: firstWord)
            let brands = Set((group + support).compactMap(\.brand))
            if !brands.isEmpty, !opensWithAttribution {
                let earliest = max(track.words[firstWord].start - options.brandLookback, previousEnd)
                let brandWords = Self.brandWords(for: brands, in: track, near: urlCues)
                var index = track.wordIndex(atTime: earliest)
                while index < firstWord {
                    if brandWords.contains(Self.bare(track.words[index].norm))
                        || (index + 1 < firstWord && brands.contains(track.words[index].norm + track.words[index + 1].norm)) {
                        firstWord = max(track.sentenceStart(before: index), track.wordIndex(atTime: earliest))
                        break
                    }
                    index += 1
                }
            }
            lastWord = track.sentenceEnd(after: lastWord)

            // Ad breaks are edited in, which leaves a beat of silence (or a music
            // sting) at each edge. When one sits just outside what the words gave
            // us, it is the real boundary: it recovers a story-style lead-in that
            // has no advertising language, and a sign-off after the last URL.
            if !opensWithAttribution {
                let limit = max(track.words[firstWord].start - options.pauseLookback, previousEnd)
                var index = firstWord
                while index > 0, track.words[index - 1].end >= limit {
                    if track.words[index].start - track.words[index - 1].end >= options.editPause {
                        firstWord = index
                        break
                    }
                    index -= 1
                }
            }
            var index = lastWord
            while index + 1 < track.words.count, track.words[index + 1].start - track.words[lastWord].end <= options.pauseLookahead {
                if track.words[index + 1].start - track.words[index].end >= options.editPause {
                    lastWord = index
                    break
                }
                index += 1
            }

            let start = max(track.words[firstWord].start, previousEnd)
            let end = track.words[lastWord].end
            guard end - start >= options.minimumDuration, end - start <= options.maximumDuration else { continue }

            var reasons: [String] = []
            for label in group.map(\.label) + support.map(\.label) where !reasons.contains(label) { reasons.append(label) }
            output.append(AdSegment(start: start, end: end, confidence: min(1, 0.4 + score / 20),
                                    reason: reasons.prefix(4).joined(separator: ", ")))
            previousEnd = end
        }
        return output
    }

    // MARK: - Chapter based detection

    /// Publishers sometimes label sponsor reads in chapter markers or in
    /// timestamped show notes ("(00:06:10) Sponsor: LMNT").
    public func detect(in chapters: [Chapter], episodeDuration: TimeInterval?) -> [AdSegment] {
        let sorted = chapters.sorted { $0.start < $1.start }
        return sorted.enumerated().compactMap { index, chapter in
            guard Self.isAdChapterTitle(chapter.title) else { return nil }
            let end = index + 1 < sorted.count ? sorted[index + 1].start : episodeDuration
            guard let end, end - chapter.start >= 5, end - chapter.start <= options.maximumDuration else { return nil }
            return AdSegment(start: chapter.start, end: end, confidence: 0.9, reason: "show notes: \(chapter.title)")
        }
    }

    static func isAdChapterTitle(_ title: String) -> Bool {
        // "Sponsors" alone is a label; "…, Sponsors, Social Media" in a long
        // sign-off chapter is not, so the word has to lead the title.
        title.range(of: #"^\W*(ads?|advert\w*|sponsor(s|ed)?|promo|commercials?|ad break|mid-?roll|pre-?roll|post-?roll)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            || title.range(of: #"\b(word|message) from (our|the) sponsors?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Combines measured detections (from the audio's own transcript) with
    /// approximate ones (from show notes, whose timestamps can be a few
    /// seconds off, or shifted wholesale by inserted ads).
    ///
    /// Where both describe the same ad, the measured end is trusted and the
    /// notes are used only to recover a start the transcript missed.
    public static func reconcile(measured: [AdSegment], approximate: [AdSegment]) -> [AdSegment] {
        var result = measured
        var offsets: [(time: TimeInterval, offset: TimeInterval)] = []
        var unmatched: [AdSegment] = []

        for notes in approximate {
            let overlapping = result.indices.filter {
                min(result[$0].end, notes.end + 20) - max(result[$0].start, notes.start - 20) > 0
            }
            guard let lastIndex = overlapping.last, let firstIndex = overlapping.first else {
                unmatched.append(notes)
                continue
            }
            let offset = result[lastIndex].end - notes.end
            guard abs(offset) <= 45 else { continue }
            offsets.append((notes.start, offset))
            var combined = result[firstIndex]
            // Only when the notes say the ad began well before the first spoken cue;
            // otherwise the measured sentence boundary is the more exact of the two.
            if notes.start + offset < combined.start - 8 { combined.start = notes.start + offset }
            combined.end = result[lastIndex].end
            combined.confidence = 1
            result.removeSubrange(firstIndex...lastIndex)
            result.insert(combined, at: firstIndex)
        }

        // Ads only the notes know about: shift them by the nearest measured offset.
        for var notes in unmatched {
            if let nearest = offsets.min(by: { abs($0.time - notes.start) < abs($1.time - notes.start) }) {
                notes.start += nearest.offset
                notes.end += nearest.offset
            }
            result.append(notes)
        }
        return merge(result)
    }

    /// Sorts and fuses overlapping or touching segments of the same kind.
    public static func merge(_ lists: [AdSegment]...) -> [AdSegment] {
        var output: [AdSegment] = []
        for segment in lists.joined().sorted(by: { $0.start < $1.start }) {
            if var last = output.last, segment.start <= last.end + 2, segment.kind == last.kind {
                last.end = max(last.end, segment.end)
                last.confidence = max(last.confidence, segment.confidence)
                if last.reason.isEmpty { last.reason = segment.reason }
                output[output.count - 1] = last
            } else {
                output.append(segment)
            }
        }
        return output
    }

    // MARK: - Cues

    struct Cue {
        var first: Int
        var last: Int
        var weight: Double
        var label: String
        /// Sponsor domain without TLD and spaces, for URL cues.
        var brand: String?
    }

    struct Pattern: @unchecked Sendable {
        let label: String
        let weight: Double
        let regex: NSRegularExpression
        /// Capture group holding the domain name, if this is a URL pattern.
        let brandGroup: Int?

        init(_ label: String, _ weight: Double, _ pattern: String, brandGroup: Int? = nil) {
            self.label = label
            self.weight = weight
            self.brandGroup = brandGroup
            // Patterns are compile-time constants; a failure is a programmer error.
            self.regex = try! NSRegularExpression(pattern: pattern)
        }
    }

    private static let tld = "(?:com|co|org|net|io|ai|fm|app|tv|us|blog|health|shop|store|life)"
    /// Speech recognisers write "acme.com/show", "acme .com slash show" or
    /// "acme dot com slash show"; and often split the name ("helix sleep .com").
    private static let domain = "((?:[a-z0-9-]+ )?[a-z0-9-]+(?:'s)?) ?(?:\\.| dot )\(tld)\\b(?: ?\\.\(tld)\\b)*"

    static let patterns: [Pattern] = [
        // Sponsor attribution
        Pattern("sponsor attribution", 4, #"\b(brought to you|sponsored|presented) (in part )?by\b"#),
        Pattern("sponsor attribution", 4, #"\bsupport for (this|the|today's) (show|podcast|episode|program)\b"#),
        Pattern("sponsor attribution", 4, #"\b(our|today's|this episode'?s?|this week's) sponsors?\b"#),
        Pattern("sponsor attribution", 4, #"\bthe sponsors? of (this|today's|the)\b"#),
        Pattern("sponsor attribution", 4, #"\b(thank|thanks|thanking) (again )?(to )?.{0,40}for sponsoring\b"#),
        // Public-radio and network style: "This message comes from…"
        Pattern("sponsor attribution", 4, #"\b(this|the following) message (comes|is|come) from\b"#),
        Pattern("sponsor attribution", 4, #"\bsupport for (npr|this station|the show) \w* ?(and the following message )?(comes?|is provided) (from|by)\b"#),
        Pattern("sponsor attribution", 4, #"\band the following message comes? from\b"#),
        // Promo codes
        Pattern("promo code", 4, #"\b(promo|offer|discount|coupon) code\b"#),
        Pattern("promo code", 4, #"\b(use|enter|with) (the )?code\b"#),
        Pattern("promo code", 3, #"\bat checkout\b"#),
        // Vanity URLs
        Pattern("sponsor URL", 4, domain + "(?: ?/ ?| slash | forward slash )[a-z0-9]+", brandGroup: 1),
        // Offers
        Pattern("discount offer", 3, #"\b\d+ ?(percent|dollars|bucks)? off\b"#),
        Pattern("discount offer", 3, #"\b(free trial|free shipping|free sample|money back guarantee|risk free|first (month|order|box|purchase|subscription)|limited time|special offer|exclusive (offer|deal|discount))\b"#),
        Pattern("discount offer", 3, #"\b(terms|restrictions|conditions) (and conditions )?apply\b"#),
        Pattern("call to action", 3, #"\b(tap|click) the (banner|link)\b"#),
        Pattern("call to action", 3, #"\b(tell them|let them know) .{0,24}sent you\b"#),
        Pattern("call to action", 3, #"\bwhere you heard about (them|us)\b"#),
        Pattern("discount offer", 3, #"\b(get|claim|grab) (your|a|an|my) (free|exclusive|special)\b"#),
        // Hosts repeat the address: "again, that's acme.com".
        Pattern("repeated URL", 3, "\\b(?:again|that's|that is|once more|one more time) (?:[a-z0-9-]+ ){0,3}?" + domain, brandGroup: 1),
        // Weak, supporting evidence only
        Pattern("website", 1.5, domain + "(?! ?/| slash| forward slash)", brandGroup: 1),
        Pattern("call to action", 1, #"\b(go|head|head over) to\b"#),
        Pattern("call to action", 1, #"\b(sign up|get started|learn more|download the app|check it out|link in the (show notes|description))\b"#),
        Pattern("call to action", 1, #"\b(our|for) listeners\b"#),
    ]

    /// Cues with the show's own web addresses demoted to weak evidence.
    func cues(in track: WordTrack) -> [Cue] {
        let house = Self.squeeze(options.showName)
        return Self.findCues(in: track).map { cue in
            guard let brand = cue.brand, !house.isEmpty else { return cue }
            let parts = brand.split(separator: "|").map { Self.squeeze(String($0)) }
            let isHouse = house.contains(parts.joined()) || (parts.last.map { $0.count >= 3 && house.contains($0) } ?? false)
            guard isHouse else { return cue }
            var cue = cue
            cue.weight = 0.5
            cue.label = "house website"
            cue.brand = nil
            return cue
        }
    }

    /// Letters and digits only, with doubled letters collapsed, so that a
    /// recogniser's "peteratia" still matches "Peter Attia".
    static func squeeze(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() where character.isLetter || character.isNumber {
            if result.last != character { result.append(character) }
        }
        return result
    }

    static func findCues(in track: WordTrack) -> [Cue] {
        guard !track.words.isEmpty else { return [] }
        let text = track.text as NSString
        var cues: [Cue] = []
        for pattern in patterns {
            for match in pattern.regex.matches(in: track.text, range: NSRange(location: 0, length: text.length)) {
                var brand: String?
                if let group = pattern.brandGroup, match.range(at: group).location != NSNotFound {
                    brand = text.substring(with: match.range(at: group))
                }
                cues.append(Cue(first: track.wordIndex(atUTF16: match.range.location),
                                last: track.wordIndex(atUTF16: match.range.location + match.range.length - 1),
                                weight: pattern.weight, label: pattern.label, brand: brand))
            }
        }
        cues.sort { $0.first < $1.first }
        // "acme.com/show" also matches the bare-website pattern at the same spot.
        var filtered: [Cue] = []
        for cue in cues {
            if let last = filtered.last, last.label == cue.label || (last.brand != nil && cue.brand != nil), cue.first <= last.last {
                if cue.weight > last.weight { filtered[filtered.count - 1] = cue }
                continue
            }
            filtered.append(cue)
        }
        // Expand "helix sleep" into the names a host might say: "helixsleep", "sleep", "helix".
        return filtered.map { cue in
            var cue = cue
            cue.brand = cue.brand?.replacingOccurrences(of: " ", with: "|")
            return cue
        }
    }

    /// Single words that name one of the sponsors. A candidate must be part of
    /// the sponsor's domain and must not be a word the episode uses freely
    /// elsewhere (so "sleep" doesn't count as a brand in an episode about sleep).
    static func brandWords(for brands: Set<String>, in track: WordTrack, near urlCues: [Cue]) -> Set<String> {
        // The pattern captures up to two words before the TLD, because recognisers
        // split names ("helix sleep .com"). Often the first is just the word before
        // the address ("at fin .ai"), in which case the name is the second alone.
        // For a real two-word name, the host may say it joined or by its first
        // word ("helix"); its last word alone ("sleep", "place", "one") is ordinary
        // vocabulary unless it is long enough to be distinctive ("momentous").
        var names = Set<String>()
        var singleWordNames = Set<String>()
        for brand in brands {
            let parts = brand.split(separator: "|").map(String.init)
            if parts.count == 2, !leadInWords.contains(parts[0]) {
                names.insert(parts.joined())
                if parts[1].count >= 7 { singleWordNames.insert(parts[1]) }
            } else if let last = parts.last {
                singleWordNames.insert(last)
            }
        }
        names.formUnion(singleWordNames)
        let adTimes = urlCues.map { track.words[$0.first].start }
        var counts: [String: Int] = [:]
        var candidates = Set<String>()
        for word in track.words where word.norm.count >= 3 {
            let norm = bare(word.norm)
            guard names.contains(where: { $0 == norm || ($0.hasPrefix(norm) && norm.count >= 4) })
                    || singleWordNames.contains(where: { $0.hasSuffix(norm) && norm.count >= 5 }) else { continue }
            candidates.insert(norm)
            // Mentions right around a sponsor URL are the ad itself, not general usage.
            if !adTimes.contains(where: { word.start > $0 - 180 && word.start < $0 + 30 }) {
                counts[norm, default: 0] += 1
            }
        }
        return candidates.filter { counts[$0, default: 0] <= 1 && !commonWords.contains($0) }
    }

    /// "Carhartt's" → "carhartt".
    static func bare(_ norm: String) -> String {
        norm.hasSuffix("'s") ? String(norm.dropLast(2)) : norm
    }

    /// Words that precede a spoken web address without being part of it.
    static let leadInWords: Set<String> = [
        "at", "to", "visit", "go", "is", "that's", "s", "in", "on", "the", "a", "and", "of", "by", "with", "check",
        "out", "via", "time", "just", "again", "try", "com", "it's", "called", "website", "site", "or", "online",
    ]

    static let commonWords: Set<String> = [
        "the", "get", "try", "use", "join", "with", "shop", "drink", "eat", "meet", "hello", "buy", "visit", "www",
        "http", "https", "you", "your", "for", "and", "that", "this", "now", "today", "one", "two", "go", "my",
    ]

    /// One line per cue, for tuning against real transcripts.
    public func debugCues(_ segments: [TranscriptSegment]) -> [String] {
        let track = WordTrack(segments)
        return cues(in: track).filter { $0.weight >= 1.5 }.map { cue in
            let words = track.words[max(0, cue.first - 4)...min(track.words.count - 1, cue.last + 4)].map(\.norm)
            return String(format: "%6.0f %3.1f %@ | %@", track.words[cue.first].start, cue.weight,
                          cue.label + (cue.brand.map { " <\($0)>" } ?? ""), words.joined(separator: " "))
        }
    }
}

/// Decides when playback should jump over an ad.
public enum AdSkipPlanner {
    /// Returns the time to seek to if `time` falls inside a segment, else nil.
    /// `tail` avoids re-triggering on the last instant of a segment.
    public static func skipTarget(at time: TimeInterval, segments: [AdSegment], minimumConfidence: Double = 0,
                                  tail: TimeInterval = 1) -> (segment: AdSegment, target: TimeInterval)? {
        guard let segment = segments.first(where: {
            $0.confidence >= minimumConfidence && time >= $0.start && time < $0.end - tail
        }) else { return nil }
        // Chain directly through back-to-back segments.
        var target = segment.end
        while let next = segments.first(where: {
            $0.confidence >= minimumConfidence && $0.start <= target + 1 && $0.end > target
        }) {
            target = next.end
        }
        return (segment, target)
    }
}
