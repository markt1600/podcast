import Foundation
import SwiftData
import PodcastCore

enum DownloadState: Int {
    case none, downloading, downloaded
}

enum AnalysisState: Int {
    /// Not looked at yet.
    case none
    case queued
    case analyzing
    case done
    /// Could not be analysed; `analysisNote` says why.
    case unavailable
}

@Model
final class Episode {
    /// Stable local identifier (feed GUIDs are not unique across shows).
    @Attribute(.unique) var uid: String
    var guid: String
    var title: String
    var summary: String
    var pubDate: Date
    var duration: Double
    var audioURL: URL
    var fileSize: Int64
    var artworkURL: URL?
    var transcriptURL: URL?
    var transcriptType: String?
    var chaptersURL: URL?

    var position: Double = 0
    var isPlayed: Bool = false
    var lastPlayedAt: Date?
    /// When position or played state last changed on any device, for iCloud sync.
    var stateUpdatedAt: Date?

    var downloadStateRaw: Int = 0
    var localFileName: String?

    var analysisStateRaw: Int = 0
    var analysisNote: String?
    /// JSON-encoded `[AdSegment]`.
    var adSegmentsData: Data?
    /// Where the episode proper begins, after intro and pre-roll; nil if unknown.
    var contentStart: Double?
    /// True when the ad timings were measured on the downloaded file and are
    /// therefore only valid for that exact file.
    var analysisIsFileSpecific: Bool = false
    /// How the last full scan went, e.g. "Scanned at 40× speed (fast engine)".
    var scanInfo: String?
    /// Why the last attempt to scan the audio failed; nil if it hasn't failed.
    var scanFailure: String?
    /// Set when playback showed that this audio does not line up with the
    /// show-notes timestamps (ads were inserted), so they must not be trusted.
    var notesTimingsUnreliable: Bool = false

    /// Transcript fingerprint (`[UInt64]` bytes), kept so later episodes can be
    /// checked for sponsor reads and intros repeated from this one.
    @Attribute(.externalStorage) var fingerprintData: Data?

    /// Pauses found in the downloaded audio, as start/end pairs of seconds.
    @Attribute(.externalStorage) var silenceData: Data?
    /// `SilenceScanner.version` that produced `silenceData`.
    var silenceVersion: Int = 0

    var podcast: Podcast?

    init(guid: String, title: String, summary: String, pubDate: Date, duration: Double, audioURL: URL, fileSize: Int64) {
        self.uid = UUID().uuidString
        self.guid = guid
        self.title = title
        self.summary = summary
        self.pubDate = pubDate
        self.duration = duration
        self.audioURL = audioURL
        self.fileSize = fileSize
    }

    var downloadState: DownloadState {
        get { DownloadState(rawValue: downloadStateRaw) ?? .none }
        set { downloadStateRaw = newValue.rawValue }
    }

    var analysisState: AnalysisState {
        get { AnalysisState(rawValue: analysisStateRaw) ?? .none }
        set { analysisStateRaw = newValue.rawValue }
    }

    var adSegments: [AdSegment] {
        get { adSegmentsData.flatMap { try? JSONDecoder().decode([AdSegment].self, from: $0) } ?? [] }
        set { adSegmentsData = try? JSONEncoder().encode(newValue) }
    }

    var fingerprint: [UInt64] {
        get {
            guard let fingerprintData else { return [] }
            return fingerprintData.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count - 7, by: 8).map { bytes.loadUnaligned(fromByteOffset: $0, as: UInt64.self) }
            }
        }
        set { fingerprintData = newValue.withUnsafeBufferPointer { Data(buffer: $0) } }
    }

    var silences: [ClosedRange<Double>] {
        get {
            guard let silenceData else { return [] }
            let values: [Double] = silenceData.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count - 7, by: 8).map { bytes.loadUnaligned(fromByteOffset: $0, as: Double.self) }
            }
            return stride(from: 0, to: values.count - 1, by: 2).compactMap {
                values[$0] <= values[$0 + 1] ? values[$0]...values[$0 + 1] : nil
            }
        }
        set {
            let values = newValue.flatMap { [$0.lowerBound, $0.upperBound] }
            silenceData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    /// The publisher's own show notes list this episode's sponsor breaks, so
    /// there is no need to listen to the audio to find them.
    var adsKnownFromNotes: Bool {
        analysisState == .done && !analysisIsFileSpecific && !notesTimingsUnreliable
            && adSegments.contains { $0.kind == .ad }
    }

    /// The show is treated as ad-free, so this episode is not scanned.
    var scanSkippedForShow: Bool {
        !analysisIsFileSpecific && podcast?.shouldScanForAds == false
    }

    /// Nothing more to find out: scanned, listed in the show notes, or an ad-free show.
    var adsLocated: Bool {
        (analysisState == .done && analysisIsFileSpecific) || adsKnownFromNotes || scanSkippedForShow
    }

    /// Segments that playback should jump over given the user's preferences.
    func skippableSegments(ads: Bool, boilerplate: Bool) -> [AdSegment] {
        adSegments.filter { $0.kind == .ad ? ads : boilerplate }
    }

    var localFileURL: URL? {
        guard downloadState == .downloaded, let localFileName else { return nil }
        let url = Episode.downloadsDirectory.appendingPathComponent(localFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var displayArtworkURL: URL? {
        artworkURL ?? podcast?.artworkURL
    }

    var remaining: Double {
        max(0, duration - position)
    }

    var progress: Double {
        duration > 0 ? min(1, position / duration) : 0
    }

    static let downloadsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}
