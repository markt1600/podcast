import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let speeds: [Double] = [1.0, 1.25, 1.3, 1.4, 1.5, 1.75, 2.0]
    /// Episodes downloaded when a show is first added. Deliberately small, so
    /// a new subscription doesn't pull gigabytes or queue hours of scanning.
    static let firstSyncCount = 3

    var skipAds: Bool { didSet { save(skipAds, "skipAds") } }
    var skipIntros: Bool { didSet { save(skipIntros, "skipIntros") } }
    var playbackSpeed: Double { didSet { save(playbackSpeed, "playbackSpeed") } }
    /// Defaults for shows that haven't been given their own setting.
    var trimSilence: Bool { didSet { save(trimSilence, "trimSilence") } }
    var voiceBoost: Bool { didSet { save(voiceBoost, "voiceBoost") } }
    /// Number of newest unplayed episodes kept downloaded per show.
    var keepCount: Int { didSet { save(keepCount, "keepCount") } }
    var autoDownload: Bool { didSet { save(autoDownload, "autoDownload") } }
    var autoDeletePlayed: Bool { didSet { save(autoDeletePlayed, "autoDeletePlayed") } }
    /// Find ads automatically as soon as an episode finishes downloading.
    var autoAnalyze: Bool { didSet { save(autoAnalyze, "autoAnalyze") } }
    var downloadOnCellular: Bool { didSet { save(downloadOnCellular, "downloadOnCellular") } }
    /// Detections below this confidence are shown but not skipped.
    var minimumAdConfidence: Double { didSet { save(minimumAdConfidence, "minimumAdConfidence") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "skipAds": true, "skipIntros": true, "playbackSpeed": 1.3, "keepCount": 10, "autoDownload": true,
            "autoDeletePlayed": true, "autoAnalyze": true, "downloadOnCellular": true, "minimumAdConfidence": 0.5,
        ])
        skipAds = defaults.bool(forKey: "skipAds")
        skipIntros = defaults.bool(forKey: "skipIntros")
        playbackSpeed = defaults.double(forKey: "playbackSpeed")
        trimSilence = defaults.bool(forKey: "trimSilence")
        voiceBoost = defaults.bool(forKey: "voiceBoost")
        keepCount = defaults.integer(forKey: "keepCount")
        autoDownload = defaults.bool(forKey: "autoDownload")
        autoDeletePlayed = defaults.bool(forKey: "autoDeletePlayed")
        autoAnalyze = defaults.bool(forKey: "autoAnalyze")
        downloadOnCellular = defaults.bool(forKey: "downloadOnCellular")
        minimumAdConfidence = defaults.double(forKey: "minimumAdConfidence")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
