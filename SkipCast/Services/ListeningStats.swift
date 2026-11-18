import Foundation
import Observation

/// How much listening time the app has saved by skipping ads and intros and
/// by hurrying through silences.
@MainActor
@Observable
final class ListeningStats {
    struct Totals: Codable, Equatable {
        var adSeconds = 0.0
        var adCount = 0
        var introSeconds = 0.0
        var silenceSeconds = 0.0

        var total: Double { adSeconds + introSeconds + silenceSeconds }
    }

    private(set) var allTime = Totals()
    private(set) var byMonth: [String: Totals] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var unsaved = false
    private static let key = "listeningStats"

    var thisMonth: Totals { byMonth[Self.monthKey(.now)] ?? Totals() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            allTime = stored.allTime
            byMonth = stored.byMonth
        }
    }

    /// An automatic skip. Pass a negative duration to take one back (Undo).
    func recordSkip(isAd: Bool, seconds: Double) {
        update { totals in
            if isAd {
                totals.adSeconds = max(0, totals.adSeconds + seconds)
                totals.adCount = max(0, totals.adCount + (seconds >= 0 ? 1 : -1))
            } else {
                totals.introSeconds = max(0, totals.introSeconds + seconds)
            }
        }
        save()
    }

    /// Time saved in one trimmed pause. These come many times a minute, so
    /// they are written to disk in batches by `flush()`.
    func recordSilence(seconds: Double) {
        update { $0.silenceSeconds += seconds }
        unsaved = true
    }

    func flush() {
        if unsaved { save() }
    }

    private func update(_ change: (inout Totals) -> Void) {
        change(&allTime)
        change(&byMonth[Self.monthKey(.now), default: Totals()])
    }

    private func save() {
        unsaved = false
        if let data = try? JSONEncoder().encode(Stored(allTime: allTime, byMonth: byMonth)) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private struct Stored: Codable {
        var allTime: Totals
        var byMonth: [String: Totals]
    }

    private static func monthKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
