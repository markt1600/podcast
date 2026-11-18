import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @Query(filter: #Predicate<Episode> { !$0.isPlayed && ($0.position > 0 || $0.downloadStateRaw == 2) },
           sort: \Episode.pubDate, order: .reverse) private var upNext: [Episode]

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if podcasts.isEmpty {
                    ContentUnavailableView("No shows yet", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Find something to listen to in the Discover tab."))
                        .padding(.top, 80)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        if !upNext.isEmpty {
                            upNextSection
                        }
                        Text("Shows")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(podcasts) { podcast in
                                NavigationLink(value: podcast) {
                                    ShowTile(title: podcast.title,
                                             subtitle: podcast.latestEpisodeDate.map(Format.date) ?? "",
                                             artworkURL: podcast.artworkURL,
                                             badge: readyCounts[podcast.persistentModelID] ?? 0,
                                             subtitleSymbol: latestIsDownloaded(podcast) ? "arrow.down.circle.fill" : nil)
                                        .accessibilityLabel(tileLabel(for: podcast))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Unsubscribe", systemImage: "trash", role: .destructive) {
                                        library.unsubscribe(podcast)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Podcast.self) { PodcastDetailView(podcast: $0) }
            .refreshable { await library.refreshAll() }
            .toolbar {
                if library.isRefreshing {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
        }
    }

    /// Episodes ready to play (downloaded or in progress) per show, for the tile
    /// badges. Derived from the Up Next query rather than walking every show's
    /// full back catalogue on each redraw.
    private var readyCounts: [PersistentIdentifier: Int] {
        var counts: [PersistentIdentifier: Int] = [:]
        for episode in upNext {
            if let id = episode.podcast?.persistentModelID { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Whether the show's newest episode is on the device, ready to play.
    private func latestIsDownloaded(_ podcast: Podcast) -> Bool {
        guard let latest = podcast.latestEpisodeDate else { return false }
        return upNext.contains {
            $0.downloadState == .downloaded && $0.pubDate == latest
                && $0.podcast?.persistentModelID == podcast.persistentModelID
        }
    }

    private func tileLabel(for podcast: Podcast) -> String {
        var parts = [podcast.title]
        if let latest = podcast.latestEpisodeDate {
            parts.append("latest episode \(Format.date(latest))" + (latestIsDownloaded(podcast) ? ", downloaded" : ""))
        }
        return parts.joined(separator: ", ")
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next")
                .font(.title3.weight(.bold))
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(upNext.prefix(12)) { episode in
                        Button { player.play(episode) } label: {
                            UpNextCard(episode: episode)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct UpNextCard: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: episode.displayArtworkURL, cornerRadius: 10, maxPixel: 300)
                .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.podcast?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(episode.position > 0 ? "\(Format.length(episode.remaining)) left" : Format.length(episode.duration))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 280, height: 96)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
