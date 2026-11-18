import Foundation
import SwiftData
import Observation
import PodcastCore

/// Shares subscriptions, per-show settings and listening progress between
/// the user's devices through iCloud's key-value store.
///
/// Only small records travel: the list of shows, and for each show the
/// position and played state of episodes that have actually been touched.
/// Audio files and ad scans stay on each device.
@MainActor
@Observable
final class CloudSync {
    private let context: ModelContext
    private let library: Library
    @ObservationIgnored private let store = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// The episode being played; its position is this device's to decide.
    @ObservationIgnored var currentEpisodeUID: () -> String? = { nil }

    private(set) var lastSync: Date?

    /// False when the device isn't signed in to iCloud (or the app was built
    /// without the iCloud capability), in which case nothing leaves the device.
    var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    init(context: ModelContext, library: Library) {
        self.context = context
        self.library = library
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0.5) }
        }
        store.synchronize()
    }

    /// Syncs shortly, coalescing bursts of changes into one pass.
    func schedule(after seconds: Double = 3) {
        // Changes made while applying a sync are the sync itself.
        guard !isSyncing else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await syncShows()
        syncProgress()
        try? context.save()
        store.synchronize()
        lastSync = .now
    }

    // MARK: - Subscriptions and show settings

    private func syncShows() async {
        let local = library.podcasts().map {
            SyncedShow(feedURL: $0.feedURL.absoluteString, title: $0.title, speed: $0.playbackSpeed,
                       introSkip: $0.introSkipSeconds, updatedAt: $0.syncUpdatedAt.timeIntervalSince1970,
                       scanPolicy: $0.scanPolicyRaw)
        } + SyncTombstones.all
        let remote: [SyncedShow] = read("shows") ?? []
        let merged = SyncMerge.mergeShows(local: local, remote: remote)

        for show in merged {
            guard let url = URL(string: show.feedURL) else { continue }
            let existing = library.podcast(feedURL: url)
            if show.removed {
                if let existing { library.unsubscribe(existing) }
            } else if let existing {
                if show.updatedAt > existing.syncUpdatedAt.timeIntervalSince1970 + 0.5 { apply(show, to: existing) }
            } else if let added = try? await library.subscribe(feedURL: url) {
                apply(show, to: added)
            }
        }
        SyncTombstones.set(merged.filter(\.removed))
        if merged != remote { write(merged, "shows") }
    }

    private func apply(_ show: SyncedShow, to podcast: Podcast) {
        podcast.playbackSpeed = show.speed
        podcast.introSkipSeconds = show.introSkip
        if let policy = show.scanPolicy { podcast.scanPolicyRaw = policy }
        podcast.syncUpdatedAt = Date(timeIntervalSince1970: show.updatedAt)
    }

    // MARK: - Listening progress

    private func syncProgress() {
        let playing = currentEpisodeUID()
        let touched = (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.stateUpdatedAt != nil }))) ?? []
        var touchedByShow: [PersistentIdentifier: [Episode]] = [:]
        for episode in touched {
            if let id = episode.podcast?.persistentModelID { touchedByShow[id, default: []].append(episode) }
        }

        for podcast in library.podcasts() {
            let key = SyncMerge.progressKey(forFeed: podcast.feedURL)
            let remote: [String: SyncedProgress] = read(key) ?? [:]
            var local: [String: SyncedProgress] = [:]
            var episodes: [String: Episode] = [:]
            for episode in touchedByShow[podcast.persistentModelID] ?? [] {
                guard let changed = episode.stateUpdatedAt else { continue }
                episodes[episode.guid] = episode
                local[episode.guid] = SyncedProgress(position: episode.position, played: episode.isPlayed,
                                                     updatedAt: changed.timeIntervalSince1970)
            }
            guard !remote.isEmpty || !local.isEmpty else { continue }
            let merged = SyncMerge.mergeProgress(local: local, remote: remote)

            for (guid, progress) in merged {
                if let mine = local[guid], progress.updatedAt <= mine.updatedAt + 0.5 { continue }
                // Progress from another device for an episode untouched here.
                guard let episode = episodes[guid] ?? podcast.episodes.first(where: { $0.guid == guid }),
                      episode.uid != playing else { continue }
                episode.position = progress.position
                episode.isPlayed = progress.played
                episode.stateUpdatedAt = Date(timeIntervalSince1970: progress.updatedAt)
            }
            if merged != remote { write(merged, key) }
        }
    }

    // MARK: - Storage

    private func read<Value: Decodable>(_ key: String) -> Value? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func write<Value: Encodable>(_ value: Value, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { store.set(data, forKey: key) }
    }
}
