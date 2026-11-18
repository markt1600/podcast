import WidgetKit
import SwiftUI
import PodcastCore

@main
struct SkipCastWidgetBundle: WidgetBundle {
    var body: some Widget {
        ListeningWidget()
        TimeSavedWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let artwork: UIImage?
}

/// The widgets show whatever the app last recorded; the app asks for a
/// reload whenever that changes, so there is no schedule of their own.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> SnapshotEntry {
        let artwork = WidgetSnapshot.artworkURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? WidgetSnapshot(), artwork: artwork)
    }
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        current: Item(title: "How to Sleep Better", show: "A Podcast", duration: 3600, position: 1260),
        isPlaying: true,
        upNext: [Item(title: "The Next Episode", show: "Another Show", duration: 2700, position: 0)],
        savedThisMonth: 5400, savedAllTime: 21_600, adsSkipped: 42)
}

enum WidgetFormat {
    /// "1 hr 5 min", "42 min".
    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(0, total)) sec" }
        let (hours, minutes) = (total / 3600, total / 60 % 60)
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
}

// MARK: - Now playing / up next

struct ListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ListeningWidget", provider: SnapshotProvider()) { entry in
            ListeningWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetSnapshot.resumeURL)
        }
        .configurationDisplayName("Now Playing")
        .description("The episode you’re on and what’s up next. Tap to resume.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct ListeningWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var item: WidgetSnapshot.Item? { entry.snapshot.current ?? entry.snapshot.upNext.first }
    private var symbol: String { entry.snapshot.isPlaying ? "pause.fill" : "play.fill" }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(item?.title ?? "Nothing playing", systemImage: symbol)
        case .accessoryCircular:
            Gauge(value: item?.progress ?? 0) {
                Image(systemName: symbol)
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(item?.show ?? "SkipCast", systemImage: symbol)
                    .font(.caption2)
                    .lineLimit(1)
                Text(item?.title ?? "Nothing playing")
                    .font(.headline)
                    .lineLimit(1)
                if let item, item.duration > 0 {
                    Text("\(WidgetFormat.length(item.remaining)) left")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 12) {
                artwork.frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 4) {
                    details
                    Spacer(minLength: 0)
                    if let next = entry.snapshot.upNext.first(where: { $0 != item }) {
                        Text("Next: \(next.title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    artwork.frame(width: 56, height: 56)
                    Spacer()
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                details
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let item {
            Text(item.show)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if item.duration > 0 {
                ProgressView(value: item.progress)
                    .tint(.orange)
                Text("\(WidgetFormat.length(item.remaining)) left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing playing")
                .font(.subheadline.weight(.semibold))
            Text("Open SkipCast to pick an episode.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = entry.artwork {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Time saved

struct TimeSavedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimeSavedWidget", provider: SnapshotProvider()) { entry in
            TimeSavedWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Time Saved")
        .description("Listening time saved by skipping ads and intros and trimming silence.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct TimeSavedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Time saved", systemImage: "forward.end.fill")
                    .font(.caption2)
                Text(WidgetFormat.length(entry.snapshot.savedThisMonth))
                    .font(.headline)
                Text("this month")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Time saved", systemImage: "forward.end.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
                Text(WidgetFormat.length(entry.snapshot.savedThisMonth))
                    .font(.title2.weight(.bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("this month")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(entry.snapshot.adsSkipped) ads skipped · \(WidgetFormat.length(entry.snapshot.savedAllTime)) in all")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
