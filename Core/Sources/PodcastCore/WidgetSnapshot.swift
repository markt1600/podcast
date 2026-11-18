import Foundation

/// What the home-screen and lock-screen widgets show. The app writes this
/// into storage it shares with the widget extension; the widgets only read it.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var title: String
        public var show: String
        public var duration: Double
        public var position: Double

        public init(title: String, show: String, duration: Double, position: Double) {
            self.title = title
            self.show = show
            self.duration = duration
            self.position = position
        }

        public var remaining: Double { max(0, duration - position) }
        public var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    }

    /// The episode loaded in the player, or the one most recently played.
    public var current: Item?
    public var isPlaying: Bool
    /// Episodes ready to play, newest first.
    public var upNext: [Item]
    public var savedThisMonth: Double
    public var savedAllTime: Double
    public var adsSkipped: Int
    public var updatedAt: Date

    public init(current: Item? = nil, isPlaying: Bool = false, upNext: [Item] = [], savedThisMonth: Double = 0,
                savedAllTime: Double = 0, adsSkipped: Int = 0, updatedAt: Date = Date()) {
        self.current = current
        self.isPlaying = isPlaying
        self.upNext = upNext
        self.savedThisMonth = savedThisMonth
        self.savedAllTime = savedAllTime
        self.adsSkipped = adsSkipped
        self.updatedAt = updatedAt
    }

    /// Storage group shared by the app and its widgets.
    public static let appGroup = "group.com.marktan.skipcast"
    /// Opening this URL brings up the app and resumes playback.
    public static let resumeURL = URL(string: "skipcast://resume")!

    #if os(iOS) || os(macOS)
    /// Nil when the app group isn't available (for example an unsigned build).
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static var artworkURL: URL? {
        containerURL?.appendingPathComponent("widget-artwork.jpg")
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = containerURL?.appendingPathComponent("widget.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func save() {
        guard let url = Self.containerURL?.appendingPathComponent("widget.json"),
              let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
    #endif
}
