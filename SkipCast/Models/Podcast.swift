import Foundation
import SwiftData

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: URL
    var title: String
    var author: String
    var summary: String
    var artworkURL: URL?
    /// Top-level directory theme, used for recommendations.
    var themeID: Int?
    var subscribedAt: Date
    var lastRefreshed: Date?
    /// Manual "always skip the first N seconds" for this show; 0 = off.
    var introSkipSeconds: Double = 0

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    init(feedURL: URL, title: String, author: String, summary: String, artworkURL: URL?, themeID: Int?) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.themeID = themeID
        self.subscribedAt = .now
    }

    var sortedEpisodes: [Episode] {
        episodes.sorted { $0.pubDate > $1.pubDate }
    }
}
