import Foundation
import SwiftData

enum ScanPolicy: Int, CaseIterable {
    /// Scan until the show proves to be ad-free.
    case automatic
    case always
    case never

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .always: "Always scan"
        case .never: "Never scan"
        }
    }
}

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: URL
    var title: String
    var author: String
    var summary: String
    var artworkURL: URL?
    /// Top-level directory theme, used for recommendations.
    var themeID: Int?
    var subscribedAt: Date
    var lastRefreshed: Date?
    /// Publication date of the newest episode, kept here so the library can
    /// show it without loading every episode.
    var latestEpisodeDate: Date?
    /// Manual "always skip the first N seconds" for this show; 0 = off.
    var introSkipSeconds: Double = 0
    /// This show's own playback speed; nil plays it at the default speed.
    var playbackSpeed: Double?
    /// The user's choice about scanning this show for ads; see `ScanPolicy`.
    var scanPolicyRaw: Int = 0
    /// Fully scanned episodes in a row in which no ads were found.
    var cleanScanStreak: Int = 0
    /// Scanning was stopped automatically because the show appears to be ad-free.
    var scanAutoPaused: Bool = false
    var scanPausedAt: Date?
    /// When the subscription or its settings last changed, for iCloud sync.
    var syncUpdatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    init(feedURL: URL, title: String, author: String, summary: String, artworkURL: URL?, themeID: Int?) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.themeID = themeID
        self.subscribedAt = .now
    }

    var scanPolicy: ScanPolicy {
        get { ScanPolicy(rawValue: scanPolicyRaw) ?? .automatic }
        set { scanPolicyRaw = newValue.rawValue }
    }

    /// Whether downloaded episodes of this show should be scanned for ads.
    var shouldScanForAds: Bool {
        switch scanPolicy {
        case .always: true
        case .never: false
        case .automatic: !scanAutoPaused
        }
    }

    /// Updates the automatic rule after an episode has been fully scanned.
    /// Three clean episodes in a row and the show is treated as ad-free.
    func recordScan(foundAds: Bool) {
        if foundAds {
            cleanScanStreak = 0
            scanAutoPaused = false
        } else {
            cleanScanStreak += 1
            if cleanScanStreak >= Podcast.cleanScansBeforePause, !scanAutoPaused {
                scanAutoPaused = true
                scanPausedAt = .now
            }
        }
    }

    /// Shows change: once a month, let one episode of a paused show be scanned.
    /// A clean result pauses it again straight away.
    func resumeScanningIfDue() {
        guard scanAutoPaused, let since = scanPausedAt, Date.now.timeIntervalSince(since) > 30 * 86_400 else { return }
        scanAutoPaused = false
        cleanScanStreak = Podcast.cleanScansBeforePause - 1
    }

    static let cleanScansBeforePause = 3

    var sortedEpisodes: [Episode] {
        episodes.sorted { $0.pubDate > $1.pubDate }
    }
}
