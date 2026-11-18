import Foundation
import SwiftData
import UIKit
import WidgetKit
import PodcastCore

/// Keeps the home-screen and lock-screen widgets up to date by writing a
/// small snapshot of what's playing into storage shared with the widget
/// extension, and asking the widgets to redraw.
@MainActor
final class WidgetBridge {
    private let context: ModelContext
    private let player: PlayerEngine
    private let stats: ListeningStats
    private var pending: Task<Void, Never>?
    private var artworkSource: URL?

    init(context: ModelContext, player: PlayerEngine, stats: ListeningStats) {
        self.context = context
        self.player = player
        self.stats = stats
    }

    /// Refreshes the widgets shortly; bursts of changes become one update.
    func update() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    /// The episode in the player, or failing that the one last listened to.
    func currentEpisode() -> Episode? {
        if let playing = player.episode { return playing }
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.lastPlayedAt != nil && !$0.isPlayed },
                                                  sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func upNext(limit: Int) -> [Episode] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isPlayed && ($0.position > 0 || $0.downloadStateRaw == 2) },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private func write() {
        // No shared storage (for example an unsigned build): nothing to do.
        guard WidgetSnapshot.containerURL != nil else { return }
        let current = currentEpisode()
        var snapshot = WidgetSnapshot()
        snapshot.current = current.map { episode in
            let isLoaded = player.episode?.uid == episode.uid
            return WidgetSnapshot.Item(title: episode.title, show: episode.podcast?.title ?? "",
                                       duration: isLoaded && player.duration > 0 ? player.duration : episode.duration,
                                       position: isLoaded ? player.currentTime : episode.position)
        }
        snapshot.isPlaying = player.isPlaying
        snapshot.upNext = upNext(limit: 4).map {
            WidgetSnapshot.Item(title: $0.title, show: $0.podcast?.title ?? "", duration: $0.duration, position: $0.position)
        }
        snapshot.savedThisMonth = stats.thisMonth.total
        snapshot.savedAllTime = stats.allTime.total
        snapshot.adsSkipped = stats.allTime.adCount
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
        updateArtwork(for: current ?? upNext(limit: 1).first)
    }

    /// Copies the episode's artwork, scaled down, to where the widget can read it.
    private func updateArtwork(for episode: Episode?) {
        let source = episode?.displayArtworkURL
        guard source != artworkSource, let destination = WidgetSnapshot.artworkURL else { return }
        artworkSource = source
        guard let source else {
            try? FileManager.default.removeItem(at: destination)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        Task {
            guard let image = await ArtworkLoader.shared.image(for: source, maxPixel: 300),
                  let data = image.jpegData(compressionQuality: 0.8), artworkSource == source else { return }
            try? data.write(to: destination, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
