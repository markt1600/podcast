import Foundation
import SwiftData
import Observation
import PodcastCore

/// Subscriptions and feed refreshing.
@MainActor
@Observable
final class Library {
    private let context: ModelContext
    private let settings: AppSettings
    private let downloads: DownloadManager

    private(set) var isRefreshing = false
    var lastError: String?
    /// Called after subscriptions, show settings or play state change, so they can be synced.
    @ObservationIgnored var onChange: (() -> Void)?

    init(context: ModelContext, settings: AppSettings, downloads: DownloadManager) {
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
        await merge(feed, into: podcast)
        try? context.save()
        SyncTombstones.remove(feedURL)
        // First sync of a show: just the newest few, and only over Wi-Fi.
        if settings.autoDownload {
            for episode in podcast.sortedEpisodes.prefix(AppSettings.firstSyncCount) {
                downloads.download(episode, automatic: true, wifiOnly: true)
            }
        }
        onChange?()
        return podcast
    }

    /// On first launch, subscribes to the starter shows.
    func addStarterShowsIfNeeded() async {
        let key = "starterShowsAdded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Mark first: an unsubscribed starter show must not come back on the next launch.
        UserDefaults.standard.set(true, forKey: key)
        isRefreshing = true
        defer { isRefreshing = false }
        for show in StarterShows.all {
            guard let podcast = try? await subscribe(feedURL: show.feedURL, directoryEntry: show) else { continue }
            if let speed = StarterShows.speeds[show.id] { podcast.playbackSpeed = speed }
            if StarterShows.adFree.contains(show.id) {
                podcast.cleanScanStreak = Podcast.cleanScansBeforePause
                podcast.scanAutoPaused = true
                podcast.scanPausedAt = .now
            }
            // Starter picks are only a default: anything already in iCloud from
            // another device (including having removed one) takes precedence.
            podcast.syncUpdatedAt = Date(timeIntervalSince1970: 1)
        }
        onChange?()
    }

    // MARK: - OPML

    /// The current subscriptions as an OPML document other podcast apps can import.
    func exportOPML() -> String {
        OPML.generate(podcasts().map { OPML.Entry(title: $0.title, feedURL: $0.feedURL) }, title: "SkipCast subscriptions")
    }

    /// Subscribes to every feed in an OPML document that isn't already followed.
    /// Returns how many were added and how many couldn't be loaded.
    func importOPML(_ data: Data) async -> (added: Int, failed: Int, found: Int) {
        let entries = OPML.parse(data)
        var added = 0
        var failed = 0
        isRefreshing = true
        defer { isRefreshing = false }
        for entry in entries where podcast(feedURL: entry.feedURL) == nil {
            if (try? await subscribe(feedURL: entry.feedURL)) != nil {
                added += 1
            } else {
                failed += 1
            }
        }
        return (added, failed, entries.count)
    }

    func unsubscribe(_ podcast: Podcast) {
        for episode in podcast.episodes {
            downloads.removeDownload(for: episode)
        }
        SyncTombstones.add(podcast)
        context.delete(podcast)
        try? context.save()
        onChange?()
    }

    func refresh(_ podcast: Podcast) async {
        do {
            let feed = try await DirectoryService.fetchFeed(podcast.feedURL)
            let added = await merge(feed, into: podcast)
            try? context.save()
            autoDownload(added, for: podcast)
        } catch {
            lastError = "Couldn’t refresh \(podcast.title): \(error.localizedDescription)"
        }
    }

    /// Checks every show for new episodes. Feeds are fetched side by side, so
    /// the whole pass fits in the short time iOS allows a background refresh.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let shows = podcasts()
        let urls = shows.map(\.feedURL)
        let feeds = await withTaskGroup(of: (URL, ParsedFeed?).self) { group in
            for url in urls {
                group.addTask { (url, try? await DirectoryService.fetchFeed(url)) }
            }
            var result: [URL: ParsedFeed] = [:]
            for await (url, feed) in group {
                if let feed { result[url] = feed }
            }
            return result
        }
        for podcast in shows where !podcast.isDeleted {
            guard let feed = feeds[podcast.feedURL] else { continue }
            let added = await merge(feed, into: podcast)
            autoDownload(added, for: podcast)
        }
        try? context.save()
        UserDefaults.standard.set(Date.now, forKey: Self.lastRefreshKey)
    }

    /// Refreshes if the last full check was longer ago than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 3600) async {
        let last = UserDefaults.standard.object(forKey: Self.lastRefreshKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > maxAge else { return }
        await refreshAll()
    }

    private static let lastRefreshKey = "lastFullRefresh"

    /// Returns the episodes that were not known before.
    @discardableResult
    private func merge(_ feed: ParsedFeed, into podcast: Podcast) async -> [Episode] {
        if let artwork = feed.artworkURL { podcast.artworkURL = artwork }
        if !feed.title.isEmpty { podcast.title = feed.title }
        podcast.lastRefreshed = .now

        var known: [String: Episode] = [:]
        for episode in podcast.episodes { known[episode.guid] = episode }
        var inserted = 0
        var added: [Episode] = []

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
            added.append(episode)
            // A first import can be a thousand episodes; let the UI breathe.
            inserted += 1
            if inserted % 100 == 0 { await Task.yield() }
        }
        podcast.latestEpisodeDate = known.values.map(\.pubDate).max()
        return added
    }

    /// Downloads newly published episodes, and keeps a show from piling up
    /// more than the chosen number of downloads.
    private func autoDownload(_ added: [Episode], for podcast: Podcast) {
        guard settings.autoDownload, settings.keepCount > 0, !added.isEmpty else { return }
        let newest = Set(podcast.sortedEpisodes.prefix(settings.keepCount).map(\.uid))
        for episode in added where newest.contains(episode.uid) && !episode.isPlayed {
            downloads.download(episode, automatic: true)
        }
        // Make room: drop the oldest downloads that were never started.
        let held = podcast.sortedEpisodes.filter { $0.downloadState != .none }
        for episode in held.dropFirst(settings.keepCount) where episode.position == 0 {
            downloads.removeDownload(for: episode)
        }
    }

    /// Records a change to a show's own settings (speed, intro skip).
    func showSettingsChanged(_ podcast: Podcast) {
        podcast.syncUpdatedAt = .now
        try? context.save()
        onChange?()
    }

    func markPlayed(_ episode: Episode, played: Bool) {
        episode.isPlayed = played
        episode.stateUpdatedAt = .now
        if played {
            episode.position = 0
            if settings.autoDeletePlayed { downloads.removeDownload(for: episode) }
        }
        try? context.save()
        onChange?()
    }
}

/// Subscriptions removed on this device, remembered so the removal can be
/// passed on to the user's other devices.
enum SyncTombstones {
    private static let key = "syncRemovedShows"

    static var all: [SyncedShow] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SyncedShow].self, from: data)) ?? []
    }

    static func set(_ shows: [SyncedShow]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shows), forKey: key)
    }

    static func add(_ podcast: Podcast) {
        let key = PodcastDiscovery.normalize(podcast.feedURL)
        var shows = all.filter { URL(string: $0.feedURL).map(PodcastDiscovery.normalize) != key }
        shows.append(SyncedShow(feedURL: podcast.feedURL.absoluteString, title: podcast.title, speed: podcast.playbackSpeed,
                                introSkip: podcast.introSkipSeconds, updatedAt: Date.now.timeIntervalSince1970, removed: true,
                                scanPolicy: podcast.scanPolicyRaw, trimSilence: podcast.trimSilence,
                                voiceBoost: podcast.voiceBoost))
        set(shows)
    }

    static func remove(_ feedURL: URL) {
        let key = PodcastDiscovery.normalize(feedURL)
        set(all.filter { URL(string: $0.feedURL).map(PodcastDiscovery.normalize) != key })
    }
}
