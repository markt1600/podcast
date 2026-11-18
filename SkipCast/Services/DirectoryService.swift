import Foundation
import PodcastCore

/// Network access to the public podcast directory and to feeds.
enum DirectoryService {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "SkipCast/1.0 (iOS podcast player)"]
        return URLSession(configuration: configuration)
    }()

    static var country: String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    static func search(_ term: String) async throws -> [PodcastSearchResult] {
        guard let url = PodcastSearch.searchURL(term: term) else { return [] }
        let (data, _) = try await session.data(from: url)
        return try PodcastSearch.decodeResults(data)
    }

    /// Popular shows, overall or for one theme.
    static func topShows(themeID: Int?, limit: Int = 30) async throws -> [PodcastSearchResult] {
        guard let chartURL = PodcastDiscovery.topChartsURL(themeID: themeID, country: country, limit: limit) else { return [] }
        let (chartData, _) = try await session.data(from: chartURL)
        let ids = try PodcastDiscovery.decodeChartIDs(chartData)
        guard !ids.isEmpty, let lookupURL = PodcastDiscovery.lookupURL(ids: ids) else { return [] }
        let (lookupData, _) = try await session.data(from: lookupURL)
        return PodcastDiscovery.ordered(try PodcastSearch.decodeResults(lookupData), by: ids)
    }

    /// Suggestions drawn from the charts of the themes the user subscribes to most.
    static func recommendations(subscribedThemeIDs: [Int], subscribedFeedURLs: Set<URL>) async -> [PodcastSearchResult] {
        let themes = PodcastDiscovery.rankedThemes(subscribedThemeIDs: subscribedThemeIDs)
        var charts: [[PodcastSearchResult]] = []
        for theme in themes {
            if let chart = try? await topShows(themeID: theme.id, limit: 40) { charts.append(chart) }
        }
        return PodcastDiscovery.recommendations(charts: charts, subscribedFeedURLs: subscribedFeedURLs)
    }

    static func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        let (data, _) = try await session.data(from: url)
        // Big feeds (hundreds of episodes) take a while to parse; keep it off the main actor.
        return try await Task.detached(priority: .userInitiated) { try RSSParser.parse(data) }.value
    }
}
