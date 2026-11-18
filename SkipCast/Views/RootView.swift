import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Library.self) private var library
    @State private var showingPlayer = false
    /// Reopen on the tab the user was last on.
    @AppStorage("selectedTab") private var selectedTab = 0
    @State private var demoPodcast: Podcast?

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            DiscoverView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Discover", systemImage: "sparkle.magnifyingglass") }
                .tag(1)
            DownloadsView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .tag(2)
            SettingsView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .sheet(isPresented: $showingPlayer) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .sheet(item: $demoPodcast) { podcast in
            NavigationStack { PodcastDetailView(podcast: podcast) }
        }
        .task { await openDemoScreenIfRequested() }
        #endif
        .alert("Something went wrong", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.lastError ?? "")
        }
    }
}

#if DEBUG
extension RootView {
    /// Debug builds launched with `-demoScreen player` or `-demoScreen show`
    /// open straight on that screen, so screenshots can be taken unattended.
    fileprivate func openDemoScreenIfRequested() async {
        guard let screen = UserDefaults.standard.string(forKey: "demoScreen") else { return }
        for _ in 0..<60 {
            if let podcast = library.podcasts().first(where: { $0.title.contains("Huberman") }),
               let episode = podcast.sortedEpisodes.first(where: { $0.duration > 3600 }) ?? podcast.sortedEpisodes.first {
                if screen == "player" {
                    player.play(episode)
                    showingPlayer = true
                } else {
                    demoPodcast = podcast
                }
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
#endif

private struct MiniPlayerModifier: ViewModifier {
    @Environment(PlayerEngine.self) private var player
    @Binding var showingPlayer: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.episode != nil {
                MiniPlayerView()
                    .onTapGesture { showingPlayer = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: player.episode?.uid)
    }
}

extension View {
    func miniPlayer(showingPlayer: Binding<Bool>) -> some View {
        modifier(MiniPlayerModifier(showingPlayer: showingPlayer))
    }
}

struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let episode = player.episode {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(url: episode.displayArtworkURL, cornerRadius: 8, maxPixel: 200)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let skip = player.lastSkip {
                            Label("\(skip.label) · \(Format.length(skip.to - skip.from))", systemImage: "forward.end.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        } else {
                            Text(episode.podcast?.title ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skip(by: 30) } label: {
                        Image(systemName: "goforward.30")
                            .font(.title3)
                            .frame(width: 36, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Forward 30 seconds")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(.primary)

                GeometryReader { proxy in
                    Rectangle()
                        .fill(.orange)
                        .frame(width: proxy.size.width * (player.duration > 0 ? min(1, player.currentTime / player.duration) : 0))
                }
                .frame(height: 2)
            }
            .background(.regularMaterial)
            .contentShape(Rectangle())
        }
    }
}
