import SwiftUI
import SwiftData

struct DownloadsView: View {
    @Query(filter: #Predicate<Episode> { $0.downloadStateRaw != 0 }, sort: \Episode.pubDate, order: .reverse)
    private var episodes: [Episode]
    @Environment(AdAnalysisService.self) private var analysis

    var body: some View {
        NavigationStack {
            Group {
                if episodes.isEmpty {
                    ContentUnavailableView("Nothing downloaded", systemImage: "arrow.down.circle",
                                           description: Text("New episodes of shows you follow are downloaded automatically."))
                } else {
                    List {
                        Section {
                            scanSummary
                        }
                        ForEach(episodes) { episode in
                            EpisodeRow(episode: episode)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
        }
    }

    /// Overall state of the ad scan across everything downloaded.
    @ViewBuilder private var scanSummary: some View {
        let downloaded = episodes.filter { $0.downloadState == .downloaded }
        let scanned = downloaded.filter { $0.analysisState == .done && $0.analysisIsFileSpecific }.count
        VStack(alignment: .leading, spacing: 6) {
            Label("\(scanned) of \(downloaded.count) episodes scanned for ads", systemImage: "waveform.badge.magnifyingglass")
                .font(.subheadline.weight(.semibold))
            if let uid = analysis.currentUID, let current = episodes.first(where: { $0.uid == uid }) {
                ProgressView(value: analysis.progress[uid] ?? 0)
                    .tint(.orange)
                Text("Now scanning “\(current.title)”" + (analysis.waitingCount > 0 ? " · \(analysis.waitingCount) waiting" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if scanned < downloaded.count {
                Text("You can play any episode now. The one you play is scanned first, and ads are skipped as soon as the scan has passed them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
