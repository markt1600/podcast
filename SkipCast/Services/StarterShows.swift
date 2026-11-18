import Foundation
import PodcastCore

/// Shows a fresh install is subscribed to.
enum StarterShows {
    static let all: [PodcastSearchResult] = [
        show(1545953110, "Huberman Lab", "Scicomm Media", "https://feeds.megaphone.fm/hubermanlab", [1512, 1533]),
        show(863897795, "The Tim Ferriss Show", "Tim Ferriss", "https://rss.art19.com/tim-ferriss-show", [1321]),
        show(1880097970, "All Songs Considered", "NPR", "https://feeds.npr.org/g-s1-111189/podcast.xml", [1310]),
        show(1400828889, "The Peter Attia Drive", "Peter Attia, MD", "https://rss.libsyn.com/shows/121729/destinations/713489.xml", [1512]),
        show(582272991, "The Rich Roll Podcast", "Rich Roll", "https://feeds.megaphone.fm/the-rich-roll-podcast", [1304, 1512]),
        show(1578319619, "The Matt Walker Podcast", "Dr. Matt Walker", "https://rss.buzzsprout.com/1821163.rss", [1512, 1533]),
        show(1458568923, "anything goes with emma chamberlain", "emma chamberlain", "https://feeds.megaphone.fm/stupid-genius", [1304, 1324]),
        show(1521578868, "SmartLess", "Jason Bateman, Sean Hayes, Will Arnett", "https://feeds.simplecast.com/hNaFxXpO", [1303]),
        show(1646101002, "The Mel Robbins Podcast", "Mel Robbins", "https://feeds.simplecast.com/UCwaTX1J", [1304, 1512]),
    ]

    private static func show(_ id: Int, _ title: String, _ author: String, _ feed: String, _ genres: [Int]) -> PodcastSearchResult {
        // The feed URLs are compile-time constants.
        PodcastSearchResult(id: id, title: title, author: author, feedURL: URL(string: feed)!, artworkURL: nil,
                            genre: nil, episodeCount: nil, genreIDs: genres)
    }
}
