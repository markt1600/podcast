import SwiftUI
import SwiftData

struct PodcastDetailView: View {
    @Bindable var podcast: Podcast
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AdAnalysisService.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    @State private var showingAll = false
    @State private var confirmingUnsubscribe = false

    var body: some View {
        let episodes = podcast.sortedEpisodes
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section("Episodes") {
                ForEach(showingAll ? episodes : Array(episodes.prefix(30))) { episode in
                    EpisodeRow(episode: episode, showsArtwork: false)
                }
                if !showingAll, episodes.count > 30 {
                    Button("Show all \(episodes.count) episodes") { showingAll = true }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await library.refresh(podcast) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Speed", selection: $podcast.playbackSpeed) {
                        Text("Default (\(Format.speed(settings.playbackSpeed)))").tag(Double?.none)
                        ForEach(AppSettings.speeds, id: \.self) { speed in
                            Text(Format.speed(speed)).tag(Double?.some(speed))
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Ad scanning", selection: $podcast.scanPolicyRaw) {
                        ForEach(ScanPolicy.allCases, id: \.rawValue) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Skip intro", selection: $podcast.introSkipSeconds) {
                        Text("Automatic").tag(0.0)
                        ForEach([15.0, 30, 45, 60, 90, 120, 180, 300], id: \.self) { seconds in
                            Text("First \(Format.length(seconds))").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("Mark all played", systemImage: "checkmark.circle") {
                        for episode in podcast.episodes where !episode.isPlayed { library.markPlayed(episode, played: true) }
                    }
                    Button("Unsubscribe", systemImage: "trash", role: .destructive) { confirmingUnsubscribe = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onChange(of: podcast.playbackSpeed) { library.showSettingsChanged(podcast) }
        .onChange(of: podcast.introSkipSeconds) { library.showSettingsChanged(podcast) }
        .onChange(of: podcast.scanPolicyRaw) {
            library.showSettingsChanged(podcast)
            if podcast.shouldScanForAds {
                analysis.enqueueDownloads(of: podcast)
            } else {
                analysis.dropWaiting(for: podcast)
            }
        }
        .confirmationDialog("Unsubscribe from \(podcast.title)?", isPresented: $confirmingUnsubscribe, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) {
                library.unsubscribe(podcast)
                dismiss()
            }
        } message: {
            Text("Downloaded episodes will be deleted.")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(url: podcast.artworkURL, cornerRadius: 20, maxPixel: 700)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            Text(podcast.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if !podcast.author.isEmpty {
                Text(podcast.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !podcast.shouldScanForAds {
                Label(podcast.scanPolicy == .never ? "Ad scanning is off for this show"
                        : "No ads found in this show, so its episodes aren’t scanned",
                      systemImage: "checkmark.seal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if !podcast.summary.isEmpty {
                Text(podcast.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
