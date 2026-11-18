import SwiftUI
import SwiftData

struct DownloadsView: View {
    @Query(filter: #Predicate<Episode> { $0.downloadStateRaw != 0 }, sort: \Episode.pubDate, order: .reverse)
    private var episodes: [Episode]

    var body: some View {
        NavigationStack {
            Group {
                if episodes.isEmpty {
                    ContentUnavailableView("Nothing downloaded", systemImage: "arrow.down.circle",
                                           description: Text("New episodes of shows you follow are downloaded automatically."))
                } else {
                    List(episodes) { episode in
                        EpisodeRow(episode: episode)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
        }
    }
}
