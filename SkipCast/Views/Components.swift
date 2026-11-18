import SwiftUI
import PodcastCore

/// Podcast cover art with a tinted placeholder while loading.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 10
    var maxPixel = 400

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [.orange.opacity(0.5), .pink.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ArtworkLoader.shared.image(for: url, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

enum Format {
    /// 1:02:03 or 2:03.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1 hr 5 min", "42 min", "30 sec".
    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) sec" }
        let (h, m) = (total / 3600, total / 60 % 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    static func speed(_ speed: Double) -> String {
        let text = String(format: "%.2f", speed)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return text + "×"
    }

    static func date(_ date: Date) -> String {
        guard date > .distantPast else { return "" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

/// A square show tile for grids and carousels.
struct ShowTile: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    var badge: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: artworkURL, cornerRadius: 14)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.orange, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A horizontally scrolling row of shows from the directory.
struct ShowCarousel: View {
    let title: String
    let shows: [PodcastSearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            ShowTile(title: show.title, subtitle: show.author, artworkURL: show.artworkURL)
                                .frame(width: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
