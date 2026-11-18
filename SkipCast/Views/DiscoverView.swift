import SwiftUI
import SwiftData
import PodcastCore

struct DiscoverView: View {
    @Query private var podcasts: [Podcast]
    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var recommended: [PodcastSearchResult] = []
    @State private var top: [PodcastSearchResult] = []
    @State private var feedURLText = ""
    @State private var showingAddByURL = false
    @State private var addedByURL: PodcastSearchResult?

    private let themeColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browse
                } else {
                    searchResults
                }
            }
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Shows, hosts, topics")
            .navigationDestination(for: PodcastSearchResult.self) { PodcastPreviewView(show: $0) }
            .navigationDestination(for: PodcastTheme.self) { ThemeView(theme: $0) }
            .navigationDestination(item: $addedByURL) { PodcastPreviewView(show: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add by URL", systemImage: "link.badge.plus") { showingAddByURL = true }
                }
            }
            .alert("Add a show by feed URL", isPresented: $showingAddByURL) {
                TextField("https://example.com/feed.xml", text: $feedURLText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Cancel", role: .cancel) {}
                Button("Open") {
                    if let url = URL(string: feedURLText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true {
                        addedByURL = PodcastSearchResult(id: abs(url.hashValue), title: url.host() ?? "Podcast", author: "",
                                                         feedURL: url, artworkURL: nil, genre: nil, episodeCount: nil)
                    }
                }
            }
            .task(id: query) { await search() }
            .task(id: subscriptionKey) { await loadRecommendations() }
            .task {
                if top.isEmpty { top = (try? await DirectoryService.topShows(themeID: nil)) ?? [] }
            }
        }
    }

    /// Changes whenever the set of subscriptions does.
    private var subscriptionKey: String {
        podcasts.map(\.feedURL.absoluteString).sorted().joined(separator: "|")
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !recommended.isEmpty {
                ShowCarousel(title: "Because of what you follow", shows: recommended)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Browse by theme")
                    .font(.title3.weight(.bold))
                LazyVGrid(columns: themeColumns, spacing: 12) {
                    ForEach(Array(PodcastTheme.all.enumerated()), id: \.element.id) { index, theme in
                        NavigationLink(value: theme) {
                            ThemeCard(theme: theme, hue: Double(index) / Double(PodcastTheme.all.count))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            if !top.isEmpty {
                ShowCarousel(title: "Popular right now", shows: top)
            }
        }
        .padding(.vertical)
    }

    @ViewBuilder private var searchResults: some View {
        if isSearching && results.isEmpty {
            ProgressView().padding(.top, 60)
        } else if results.isEmpty {
            ContentUnavailableView(searchFailed ? "Couldn’t reach the directory" : "No shows found", systemImage: searchFailed ? "wifi.slash" : "magnifyingglass",
                                   description: Text(searchFailed ? "Check your connection and try again." : "Try a different name or topic."))
                .padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(results) { show in
                    NavigationLink(value: show) {
                        HStack(spacing: 12) {
                            ArtworkView(url: show.artworkURL, cornerRadius: 10, maxPixel: 240)
                                .frame(width: 68, height: 68)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(show.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(show.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let genre = show.genre {
                                    Text(genre)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            return
        }
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await DirectoryService.search(term)
            guard !Task.isCancelled else { return }
            results = found
            searchFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchFailed = true
        }
    }

    private func loadRecommendations() async {
        let themes = podcasts.compactMap(\.themeID)
        guard !themes.isEmpty else {
            recommended = []
            return
        }
        let picks = await DirectoryService.recommendations(subscribedThemeIDs: themes, subscribedFeedURLs: Set(podcasts.map(\.feedURL)))
        if !Task.isCancelled { recommended = picks }
    }
}

private struct ThemeCard: View {
    let theme: PodcastTheme
    let hue: Double

    var body: some View {
        HStack {
            Text(theme.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Image(systemName: theme.symbol)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(
            LinearGradient(colors: [Color(hue: hue, saturation: 0.65, brightness: 0.8), Color(hue: hue + 0.06, saturation: 0.8, brightness: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

/// Top shows for one theme.
struct ThemeView: View {
    let theme: PodcastTheme
    @State private var shows: [PodcastSearchResult] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            if !loaded {
                ProgressView().padding(.top, 60)
            } else if shows.isEmpty {
                ContentUnavailableView("Couldn’t load shows", systemImage: "wifi.slash")
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            ShowTile(title: show.title, subtitle: show.author, artworkURL: show.artworkURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(theme.name)
        .task {
            guard !loaded else { return }
            shows = (try? await DirectoryService.topShows(themeID: theme.id, limit: 60)) ?? []
            loaded = true
        }
    }
}

/// A directory show before subscribing: artwork, description, recent episodes.
struct PodcastPreviewView: View {
    let show: PodcastSearchResult
    @Environment(Library.self) private var library
    @Query private var podcasts: [Podcast]
    @State private var feed: ParsedFeed?
    @State private var failed = false
    @State private var isSubscribing = false

    private var subscribed: Podcast? {
        let key = PodcastDiscovery.normalize(show.feedURL)
        return podcasts.first { PodcastDiscovery.normalize($0.feedURL) == key }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(url: show.artworkURL ?? feed?.artworkURL, cornerRadius: 20, maxPixel: 700)
                        .frame(width: 200, height: 200)
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                    Text(feed?.title.isEmpty == false ? feed!.title : show.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(show.author.isEmpty ? (feed?.author ?? "") : show.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    subscribeButton
                    if let summary = feed?.summary, !summary.isEmpty {
                        Text(RSSParser.plainText(summary))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
                .listRowSeparator(.hidden)
            }
            if let subscribed {
                Section("Episodes") {
                    ForEach(subscribed.sortedEpisodes.prefix(20)) { EpisodeRow(episode: $0, showsArtwork: false) }
                }
            } else if let feed {
                Section("Recent episodes") {
                    ForEach(Array(feed.episodes.prefix(15).enumerated()), id: \.offset) { _, episode in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(episode.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text([episode.pubDate.map(Format.date) ?? "", episode.duration.map(Format.length) ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if failed {
                ContentUnavailableView("Couldn’t load this show’s feed", systemImage: "exclamationmark.triangle")
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard feed == nil else { return }
            do {
                feed = try await DirectoryService.fetchFeed(show.feedURL)
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder private var subscribeButton: some View {
        if subscribed != nil {
            Label("Subscribed", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(.quaternary, in: Capsule())
        } else {
            Button {
                isSubscribing = true
                Task {
                    do {
                        try await library.subscribe(feedURL: show.feedURL, directoryEntry: show, feed: feed)
                    } catch {
                        library.lastError = "Couldn’t subscribe: \(error.localizedDescription)"
                    }
                    isSubscribing = false
                }
            } label: {
                Label(isSubscribing ? "Subscribing…" : "Subscribe", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(isSubscribing)
        }
    }
}
