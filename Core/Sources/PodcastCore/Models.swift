import Foundation

/// A podcast returned by a directory search.
public struct PodcastSearchResult: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let author: String
    public let feedURL: URL
    public let artworkURL: URL?
    public let genre: String?
    public let episodeCount: Int?
    /// Directory genre IDs, most specific first. See `PodcastTheme`.
    public let genreIDs: [Int]

    public init(id: Int, title: String, author: String, feedURL: URL, artworkURL: URL?, genre: String?, episodeCount: Int?, genreIDs: [Int] = []) {
        self.genreIDs = genreIDs
        self.id = id
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.genre = genre
        self.episodeCount = episodeCount
    }
}

public struct ParsedFeed: Sendable {
    public var title = ""
    public var author = ""
    public var summary = ""
    public var artworkURL: URL?
    /// `itunes:category` names, in feed order.
    public var categories: [String] = []
    public var episodes: [ParsedEpisode] = []
}

public struct TranscriptLink: Hashable, Sendable {
    public let url: URL
    /// MIME type as declared in the feed, e.g. `text/vtt`.
    public let type: String
}

public struct ParsedEpisode: Sendable {
    public var guid = ""
    public var title = ""
    public var summary = ""
    public var pubDate: Date?
    public var duration: TimeInterval?
    public var audioURL: URL
    public var fileSize: Int64?
    public var artworkURL: URL?
    public var transcripts: [TranscriptLink] = []
    public var chaptersURL: URL?
}

/// A timed piece of spoken text. May be a single word (speech recognition)
/// or a whole caption cue (publisher transcript).
public struct TranscriptSegment: Hashable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Chapter: Hashable, Sendable {
    public let start: TimeInterval
    public let title: String

    public init(start: TimeInterval, title: String) {
        self.start = start
        self.title = title
    }
}

/// A span of audio that isn't part of the episode proper.
public struct AdSegment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A sponsor read or inserted commercial.
        case ad
        /// Recurring non-sponsor material: show intro, outro, house promos.
        case boilerplate
    }

    public var start: TimeInterval
    public var end: TimeInterval
    /// 0...1, how sure the detector is.
    public var confidence: Double
    /// Short human-readable explanation, e.g. the phrases that triggered it.
    public var reason: String
    public var kind: Kind

    public var duration: TimeInterval { end - start }

    public init(start: TimeInterval, end: TimeInterval, confidence: Double, reason: String, kind: Kind = .ad) {
        self.start = start
        self.end = end
        self.confidence = confidence
        self.reason = reason
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        confidence = try container.decode(Double.self, forKey: .confidence)
        reason = try container.decode(String.self, forKey: .reason)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .ad
    }
}
