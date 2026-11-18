import Foundation

/// A subscription as shared between a user's devices.
public struct SyncedShow: Codable, Equatable, Sendable {
    public var feedURL: String
    public var title: String
    /// The show's own playback speed; nil means "use the default".
    public var speed: Double?
    public var introSkip: Double
    /// When this record last changed, in seconds since 1970.
    public var updatedAt: TimeInterval
    /// True once the user has unsubscribed; kept so the removal reaches other devices.
    public var removed: Bool

    public init(feedURL: String, title: String, speed: Double?, introSkip: Double, updatedAt: TimeInterval, removed: Bool = false) {
        self.feedURL = feedURL
        self.title = title
        self.speed = speed
        self.introSkip = introSkip
        self.updatedAt = updatedAt
        self.removed = removed
    }
}

/// How far into an episode the user is.
public struct SyncedProgress: Codable, Equatable, Sendable {
    public var position: Double
    public var played: Bool
    public var updatedAt: TimeInterval

    public init(position: Double, played: Bool, updatedAt: TimeInterval) {
        self.position = position
        self.played = played
        self.updatedAt = updatedAt
    }
}

/// Reconciles what this device knows with what iCloud holds. Every record
/// carries the time it was last changed, and the newer one wins, so two
/// devices that both apply this end up agreeing.
public enum SyncMerge {
    public static func mergeShows(local: [SyncedShow], remote: [SyncedShow]) -> [SyncedShow] {
        var byFeed: [String: SyncedShow] = [:]
        for show in local + remote {
            guard let url = URL(string: show.feedURL) else { continue }
            let key = PodcastDiscovery.normalize(url)
            if let existing = byFeed[key], existing.updatedAt >= show.updatedAt { continue }
            byFeed[key] = show
        }
        return byFeed.values.sorted { $0.feedURL < $1.feedURL }
    }

    /// Merges per-episode progress for one show, keyed by episode GUID, keeping
    /// only the most recently touched entries so the record stays small.
    public static func mergeProgress(local: [String: SyncedProgress], remote: [String: SyncedProgress],
                                     limit: Int = 150) -> [String: SyncedProgress] {
        var merged = remote
        for (guid, progress) in local {
            if let existing = merged[guid], existing.updatedAt >= progress.updatedAt { continue }
            merged[guid] = progress
        }
        guard merged.count > limit else { return merged }
        let newest = merged.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    /// Storage key for one show's progress record.
    public static func progressKey(forFeed url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in PodcastDiscovery.normalize(url).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "progress." + String(hash, radix: 16)
    }
}
