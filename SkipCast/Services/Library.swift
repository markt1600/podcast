import Foundation
import SwiftData
import Observation
import PodcastCore

/// Subscriptions and feed refreshing.
@MainActor
@Observable
final class Library {
    private let context: ModelContext
    private let settings: Settings
    private let downloads: DownloadManager

    private(set) var isRefreshing = false
    var lastError: String?

    init(context: ModelContext, settings: Settings, downloads: DownloadManager) {
        self.context = context
        self.settings = settings
        self.downloads = downloads
    }

    func podcasts() -> [Podcast] {
        (try? context.fetch(FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)]))) ?? []
    }

    func podcast(feedURL: URL) -> Podcast? {
        let key = PodcastDiscovery.normalize(feedURL)
        return podcasts().first { PodcastDiscovery.normalize($0.feedURL) == key }
    }

    @discardableResult
    func subscribe(feedURL: URL, directoryEntry: PodcastSearchResult? = nil, feed prefetched: ParsedFeed? = nil) async throws -> Podcast {
        if let existing = podcast(feedURL: feedURL) { return existing }
        let feed: ParsedFeed
        if let prefetched {
            feed = prefetched
        } else {
            feed = try await DirectoryService.fetchFeed(feedURL)
        }
        let theme = PodcastTheme.theme(genreIDs: directoryEntry?.genreIDs ?? [], categoryNames: feed.categories)
        let podcast = Podcast(
            feedURL: feedURL,
            title: feed.title.isEmpty ? (directoryEntry?.title ?? feedURL.host() ?? "Podcast") : feed.title,
            author: feed.author.isEmpty ? (directoryEntry?.author ?? "") : feed.author,
            summary: RSSParser.plainText(feed.summary),
            artworkURL: feed.artworkURL ?? directoryEntry?.artworkURL,
            themeID: theme?.id
        )
        context.insert(podcast)
        merge(feed, into: podcast)
        try? context.save()
        autoDownload(for: podcast)
        return podcast
    }

    func unsubscribe(_ podcast: Podcast) {
        for episode in podcast.episodes {
            downloads.removeDownload(for: episode)
        }
        context.delete(podcast)
        try? context.save()
    }

    func refresh(_ podcast: Podcast) async {
        do {
            let feed = try await DirectoryService.fetchFeed(podcast.feedURL)
            merge(feed, into: podcast)
            try? context.save()
            autoDownload(for: podcast)
        } catch {
            lastError = "Couldn’t refresh \(podcast.title): \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for podcast in podcasts() {
            await refresh(podcast)
        }
    }

    private func merge(_ feed: ParsedFeed, into podcast: Podcast) {
        if let artwork = feed.artworkURL { podcast.artworkURL = artwork }
        if !feed.title.isEmpty { podcast.title = feed.title }
        podcast.lastRefreshed = .now

        var known: [String: Episode] = [:]
        for episode in podcast.episodes { known[episode.guid] = episode }

        for parsed in feed.episodes {
            let transcript = TranscriptParser.bestLink(from: parsed.transcripts)
            if let existing = known[parsed.guid] {
                // Publishers do fix titles and re-point enclosures after release.
                existing.title = parsed.title
                if existing.downloadState == .none { existing.audioURL = parsed.audioURL }
                if existing.duration == 0, let duration = parsed.duration { existing.duration = duration }
                existing.transcriptURL = transcript?.url
                existing.transcriptType = transcript?.type
                existing.chaptersURL = parsed.chaptersURL
                continue
            }
            let episode = Episode(
                guid: parsed.guid,
                title: parsed.title.isEmpty ? "Untitled episode" : parsed.title,
                summary: parsed.summary,
                pubDate: parsed.pubDate ?? .distantPast,
                duration: parsed.duration ?? 0,
                audioURL: parsed.audioURL,
                fileSize: parsed.fileSize ?? 0
            )
            episode.artworkURL = parsed.artworkURL
            episode.transcriptURL = transcript?.url
            episode.transcriptType = transcript?.type
            episode.chaptersURL = parsed.chaptersURL
            episode.podcast = podcast
            context.insert(episode)
            known[parsed.guid] = episode
        }
    }

    /// Keeps the newest N unplayed episodes of a show on the device.
    func autoDownload(for podcast: Podcast) {
        guard settings.autoDownload, settings.keepCount > 0 else { return }
        let wanted = podcast.sortedEpisodes.prefix(settings.keepCount).filter { !$0.isPlayed }
        for episode in wanted where episode.downloadState == .none {
            downloads.download(episode, automatic: true)
        }
    }

    func markPlayed(_ episode: Episode, played: Bool) {
        episode.isPlayed = played
        if played {
            episode.position = 0
            if settings.autoDeletePlayed { downloads.removeDownload(for: episode) }
        }
        try? context.save()
    }
}
