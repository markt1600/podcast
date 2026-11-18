import Foundation

/// Podcast directory search backed by the public iTunes Search API
/// (no key required).
public enum PodcastSearch {
    public static func searchURL(term: String, limit: Int = 50) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "term", value: term),
        ]
        return components?.url
    }

    public static func decodeResults(_ data: Data) throws -> [PodcastSearchResult] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.results.compactMap { item in
            // Entries without a feed (e.g. removed shows) can't be subscribed to.
            guard let feed = item.feedUrl, let feedURL = URL(string: feed), let id = item.collectionId else { return nil }
            let art = item.artworkUrl600 ?? item.artworkUrl100
            return PodcastSearchResult(
                id: id,
                title: item.collectionName ?? "Untitled",
                author: item.artistName ?? "",
                feedURL: feedURL,
                artworkURL: art.flatMap(URL.init(string:)),
                genre: item.primaryGenreName,
                episodeCount: item.trackCount,
                genreIDs: (item.genreIds ?? []).compactMap { Int($0) }
            )
        }
    }

    private struct Response: Decodable {
        let results: [Item]
    }

    private struct Item: Decodable {
        let collectionId: Int?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl100: String?
        let artworkUrl600: String?
        let primaryGenreName: String?
        let trackCount: Int?
        let genreIds: [String]?
    }
}
