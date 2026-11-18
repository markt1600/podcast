import Foundation

/// A browsable theme, backed by a top-level directory genre.
public struct PodcastTheme: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    /// SF Symbol name used for the theme tile.
    public let symbol: String

    public static let all: [PodcastTheme] = [
        .init(id: 1489, name: "News", symbol: "newspaper"),
        .init(id: 1303, name: "Comedy", symbol: "theatermasks"),
        .init(id: 1488, name: "True Crime", symbol: "magnifyingglass"),
        .init(id: 1318, name: "Technology", symbol: "cpu"),
        .init(id: 1321, name: "Business", symbol: "briefcase"),
        .init(id: 1324, name: "Society & Culture", symbol: "person.3"),
        .init(id: 1487, name: "History", symbol: "building.columns"),
        .init(id: 1533, name: "Science", symbol: "atom"),
        .init(id: 1545, name: "Sports", symbol: "sportscourt"),
        .init(id: 1512, name: "Health & Fitness", symbol: "heart"),
        .init(id: 1304, name: "Education", symbol: "graduationcap"),
        .init(id: 1309, name: "TV & Film", symbol: "film"),
        .init(id: 1310, name: "Music", symbol: "music.note"),
        .init(id: 1301, name: "Arts", symbol: "paintpalette"),
        .init(id: 1483, name: "Fiction", symbol: "book"),
        .init(id: 1502, name: "Leisure", symbol: "gamecontroller"),
        .init(id: 1305, name: "Kids & Family", symbol: "figure.2.and.child.holdinghands"),
        .init(id: 1314, name: "Religion & Spirituality", symbol: "sparkles"),
        .init(id: 1511, name: "Government", symbol: "building.2"),
    ]

    public static func theme(id: Int) -> PodcastTheme? {
        all.first { $0.id == id }
    }

    /// The top-level theme for a show, from directory genre IDs (which mix
    /// sub-genres and top-level genres) or, failing that, feed category names.
    public static func theme(genreIDs: [Int], categoryNames: [String] = []) -> PodcastTheme? {
        for id in genreIDs {
            if let match = theme(id: id) { return match }
        }
        for name in categoryNames {
            if let match = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        }
        return nil
    }
}

/// Top charts and recommendations, using the public iTunes charts feed.
public enum PodcastDiscovery {
    /// Chart of popular shows, optionally restricted to one theme.
    public static func topChartsURL(themeID: Int?, country: String = "us", limit: Int = 50) -> URL? {
        let genre = themeID.map { "/genre=\($0)" } ?? ""
        return URL(string: "https://itunes.apple.com/\(country.lowercased())/rss/toppodcasts/limit=\(limit)\(genre)/json")
    }

    /// Chart entries carry no feed URL, so they have to be resolved with a
    /// lookup before they can be shown as subscribable results.
    public static func decodeChartIDs(_ data: Data) throws -> [Int] {
        struct Response: Decodable {
            struct Feed: Decodable { let entry: [Entry]? }
            struct Entry: Decodable {
                struct ID: Decodable {
                    let attributes: [String: String]
                }
                let id: ID
            }
            let feed: Feed
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.feed.entry ?? []).compactMap { $0.id.attributes["im:id"].flatMap { Int($0) } }
    }

    public static func lookupURL(ids: [Int]) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
        ]
        return components?.url
    }

    /// Restores chart order after a lookup (which returns results in its own order).
    public static func ordered(_ results: [PodcastSearchResult], by ids: [Int]) -> [PodcastSearchResult] {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return results.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// Themes to recommend from, most-subscribed first.
    public static func rankedThemes(subscribedThemeIDs: [Int], limit: Int = 3) -> [PodcastTheme] {
        var counts: [Int: Int] = [:]
        var firstSeen: [Int: Int] = [:]
        for (index, id) in subscribedThemeIDs.enumerated() {
            counts[id, default: 0] += 1
            if firstSeen[id] == nil { firstSeen[id] = index }
        }
        return counts.keys
            .sorted { (counts[$0]!, -firstSeen[$0]!) > (counts[$1]!, -firstSeen[$1]!) }
            .compactMap(PodcastTheme.theme(id:))
            .prefix(limit)
            .map { $0 }
    }

    /// Round-robins per-theme charts into one list, dropping shows the user
    /// already subscribes to and duplicates.
    public static func recommendations(charts: [[PodcastSearchResult]], subscribedFeedURLs: Set<URL>,
                                       limit: Int = 30) -> [PodcastSearchResult] {
        var seen = Set<Int>()
        var output: [PodcastSearchResult] = []
        let subscribed = Set(subscribedFeedURLs.map(normalize))
        let longest = charts.map(\.count).max() ?? 0
        for index in 0..<longest {
            for chart in charts where index < chart.count {
                let show = chart[index]
                guard !subscribed.contains(normalize(show.feedURL)), seen.insert(show.id).inserted else { continue }
                output.append(show)
                if output.count == limit { return output }
            }
        }
        return output
    }

    /// Feed URLs differ in scheme and trailing slash between directories and feeds.
    public static func normalize(_ url: URL) -> String {
        var string = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where string.hasPrefix(prefix) {
            string.removeFirst(prefix.count)
        }
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }
}
