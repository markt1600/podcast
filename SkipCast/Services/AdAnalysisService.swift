import Foundation
import SwiftData
import Observation
import PodcastCore
import CryptoKit

/// Works out where the ads and the intro are in an episode.
///
/// Two passes:
///  * a quick scan of the publisher's show notes and chapter markers, which
///    is instant and works for streaming, but is only as good as the notes;
///  * a full scan that transcribes the downloaded file on the device, which
///    measures the exact audio that will be played.
@MainActor
@Observable
final class AdAnalysisService {
    private let context: ModelContext

    /// Fraction of the current episode transcribed, by episode uid.
    private(set) var progress: [String: Double] = [:]
    /// How far into the audio the scan has got, in seconds, by episode uid.
    /// Ads before this point are already known and will be skipped.
    private(set) var scannedUpTo: [String: Double] = [:]
    /// The episode being scanned right now, and how many are waiting.
    private(set) var currentUID: String?
    private(set) var waitingCount = 0
    /// Transcripts of scans that were set aside for a more urgent episode.
    @ObservationIgnored private var partials: [String: [TranscriptSegment]] = [:]
    @ObservationIgnored private var queue: [Episode] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var priorityUID: String?
    /// Looks up, and publishes, scan results shared between the user's devices.
    @ObservationIgnored var sharedScan: ((String) -> SharedScan?)?
    @ObservationIgnored var shareScan: ((SharedScan, String) -> Void)?

    init(context: ModelContext) {
        self.context = context
    }

    /// Instant pass over show notes. Safe to call repeatedly.
    func quickScan(_ episode: Episode) {
        guard episode.analysisState == .none else { return }
        let analysis = EpisodeAnalyzer().analyze(baseEvidence(for: episode))
        guard !analysis.segments.isEmpty || analysis.contentStart != nil else { return }
        episode.adSegments = analysis.segments
        episode.contentStart = analysis.contentStart
        episode.analysisIsFileSpecific = false
        episode.analysisState = .done
        episode.analysisNote = analysis.segments.contains { $0.kind == .ad }
            ? "Sponsor breaks are listed in the show notes, so no scan is needed."
            : "From the show notes. Download the episode to find its ads."
    }

    private func baseEvidence(for episode: Episode) -> EpisodeEvidence {
        var evidence = EpisodeEvidence()
        evidence.showNotes = episode.summary
        evidence.duration = episode.duration > 0 ? episode.duration : nil
        evidence.episodeTitle = episode.title
        evidence.showName = [episode.podcast?.title, episode.podcast?.author].compactMap { $0 }.joined(separator: " ")
        return evidence
    }

    /// Moves an episode to the front of the scan queue (it is about to be played).
    func prioritize(_ episode: Episode) {
        priorityUID = episode.uid
        if episode.downloadState == .downloaded { enqueue(episode) }
    }

    /// Queues a full scan of a downloaded episode.
    func enqueue(_ episode: Episode, force: Bool = false) {
        guard force || !episode.analysisIsFileSpecific || episode.analysisState != .done else { return }
        guard episode.localFileURL != nil || episode.transcriptURL != nil || episode.chaptersURL != nil else {
            quickScan(episode)
            return
        }
        guard !queue.contains(where: { $0.uid == episode.uid }) else { return }
        // Use what the show notes say straight away.
        quickScan(episode)
        // When the notes list the sponsor breaks themselves, that is the answer:
        // scanning the audio would spend minutes of battery to learn the same thing.
        // (A scan can still be asked for by hand, and runs anyway if playback
        // finds the audio doesn't match the notes.)
        if !force, episode.adsKnownFromNotes { return }
        // Nor is there any point listening to a show that doesn't carry ads.
        if !force, let podcast = episode.podcast {
            podcast.resumeScanningIfDue()
            if !podcast.shouldScanForAds { return }
        }
        if episode.analysisState != .done { episode.analysisState = .queued }
        queue.append(episode)
        waitingCount = queue.count
        startWorkerIfNeeded()
    }

    /// Re-queues work that was interrupted when the app last exited.
    func resume() {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.analysisStateRaw == 1 || $0.analysisStateRaw == 2 })
        for episode in (try? context.fetch(descriptor)) ?? [] {
            episode.analysisState = .none
            if episode.downloadState == .downloaded { enqueue(episode) }
        }
    }

    /// Removes a show's episodes from the queue (it has been found, or declared, ad-free).
    func dropWaiting(for podcast: Podcast) {
        for episode in queue where episode.podcast?.persistentModelID == podcast.persistentModelID {
            if episode.analysisState == .queued { episode.analysisState = .none }
        }
        queue.removeAll { $0.podcast?.persistentModelID == podcast.persistentModelID }
        waitingCount = queue.count
    }

    /// Queues a show's downloaded episodes after scanning has been switched back on.
    func enqueueDownloads(of podcast: Podcast) {
        for episode in podcast.sortedEpisodes where episode.downloadState == .downloaded {
            enqueue(episode)
        }
    }

    func isWorking(on episode: Episode) -> Bool {
        progress[episode.uid] != nil || queue.contains { $0.uid == episode.uid }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            // One at a time: transcription is CPU heavy.
            while !queue.isEmpty {
                // The episode being played first, then newest first: with a big
                // backlog those are the ones most likely to be listened to next.
                let index = queue.firstIndex { $0.uid == priorityUID }
                    ?? queue.indices.max { queue[$0].pubDate < queue[$1].pubDate } ?? 0
                let episode = queue.remove(at: index)
                waitingCount = queue.count
                guard !episode.isDeleted else { continue }
                currentUID = episode.uid
                await analyze(episode)
                currentUID = nil
            }
            worker = nil
        }
    }

    private func analyze(_ episode: Episode) async {
        let hadQuickResult = episode.analysisState == .done
        if !hadQuickResult { episode.analysisState = .analyzing }
        let uid = episode.uid
        var evidence = baseEvidence(for: episode)
        var note: String?
        var fileSpecific = false

        // Another of the user's devices may already have scanned this very file.
        // Inserted ads make downloads differ, so the match is on the audio itself.
        var audioKey: String?
        if let file = episode.localFileURL {
            audioKey = await Task.detached(priority: .utility) { Self.audioKey(for: file) }.value
            if let audioKey, let shared = sharedScan?(audioKey), !episode.isDeleted {
                episode.adSegments = shared.segments
                episode.contentStart = shared.contentStart
                episode.analysisIsFileSpecific = true
                episode.analysisState = .done
                episode.analysisNote = "Scanned on another of your devices."
                episode.podcast?.recordScan(foundAds: shared.segments.contains { $0.kind == .ad })
                try? context.save()
                return
            }
        }

        if let file = episode.localFileURL {
            do {
                // Pick up where an interrupted scan of this episode left off.
                var words = partials[uid] ?? []
                progress[uid] = scannedUpTo[uid].map { episode.duration > 0 ? $0 / episode.duration : 0 } ?? 0
                var chunksSincePublish = 0
                let finished = try await EpisodeTranscriber().transcribe(file, from: scannedUpTo[uid] ?? 0) { chunk, upTo, fraction in
                    words += chunk
                    self.progress[uid] = fraction
                    self.scannedUpTo[uid] = upTo
                    // Every few minutes of audio, publish what has been found so far,
                    // so skipping works on the part already scanned.
                    chunksSincePublish += 1
                    if chunksSincePublish >= 4 {
                        chunksSincePublish = 0
                        self.publishPartial(words, base: evidence, for: episode)
                    }
                    // Step aside if the user has started playing a different episode.
                    if let urgent = self.priorityUID, urgent != uid, self.queue.contains(where: { $0.uid == urgent }) {
                        return false
                    }
                    return true
                }
                progress[uid] = nil
                guard finished else {
                    partials[uid] = words
                    if !episode.isDeleted {
                        if episode.analysisState != .done { episode.analysisState = .queued }
                        queue.append(episode)
                        waitingCount = queue.count
                    }
                    return
                }
                partials[uid] = nil
                scannedUpTo[uid] = nil
                evidence.transcript = words
                fileSpecific = true
            } catch {
                note = error.localizedDescription
                progress[uid] = nil
            }
        }

        if evidence.transcript.isEmpty, let url = episode.transcriptURL, let type = episode.transcriptType,
           let (data, _) = try? await DirectoryService.session.data(from: url) {
            evidence.transcript = TranscriptParser.parse(data, type: type) ?? []
            evidence.transcriptMatchesAudio = false
        }
        if let url = episode.chaptersURL, let (data, _) = try? await DirectoryService.session.data(from: url) {
            evidence.chapters = TranscriptParser.parseChapters(data)
        }
        guard !episode.isDeleted else { return }

        evidence.reference = referenceFingerprints(excluding: uid)
        let analysis = await Task.detached(priority: .utility) { [evidence] in
            EpisodeAnalyzer().analyze(evidence)
        }.value
        guard !episode.isDeleted else { return }

        if evidence.transcript.isEmpty && analysis.segments.isEmpty && analysis.contentStart == nil {
            if !hadQuickResult {
                episode.analysisState = .unavailable
                episode.analysisNote = note ?? "Download the episode to scan it for ads."
            } else if let note {
                episode.analysisNote = note
            }
            return
        }
        episode.adSegments = analysis.segments
        episode.contentStart = analysis.contentStart
        if fileSpecific {
            episode.fingerprint = analysis.fingerprint
            if let podcast = episode.podcast {
                podcast.recordScan(foundAds: analysis.segments.contains { $0.kind == .ad })
                // Just concluded the show is ad-free: drop its other waiting episodes.
                if !podcast.shouldScanForAds { dropWaiting(for: podcast) }
            }
        }
        episode.analysisIsFileSpecific = fileSpecific
        episode.analysisState = .done
        if fileSpecific, let audioKey {
            shareScan?(SharedScan(segments: analysis.segments, contentStart: analysis.contentStart,
                                  savedAt: Date.now.timeIntervalSince1970), audioKey)
        }
        episode.analysisNote = fileSpecific ? nil : (note ?? "From the publisher’s notes. Download the episode for exact timing.")
        try? context.save()
    }

    /// Analyses the part transcribed so far and stores the result, leaving the
    /// episode marked as still being scanned.
    private func publishPartial(_ words: [TranscriptSegment], base: EpisodeEvidence, for episode: Episode) {
        var evidence = base
        evidence.transcript = words
        evidence.reference = referenceFingerprints(excluding: episode.uid)
        Task {
            let analysis = await Task.detached(priority: .utility) { [evidence] in
                EpisodeAnalyzer().analyze(evidence)
            }.value
            // The full result may have landed in the meantime.
            guard !episode.isDeleted, episode.analysisState != .done || !episode.analysisIsFileSpecific else { return }
            episode.adSegments = analysis.segments
            episode.contentStart = analysis.contentStart
        }
    }

    /// Identifies an audio file by its size and samples of its content, cheaply
    /// enough to run on every download. Two downloads of an episode with
    /// different inserted ads get different keys.
    nonisolated static func audioKey(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        let sample: UInt64 = 1 << 20
        // Start, middle and end: wherever an ad was inserted, at least the size or
        // one of these moves.
        for offset in Set([0, size / 2, size > sample ? size - sample : 0]).sorted() {
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Int(sample)) else { continue }
            hasher.update(data: data)
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprints of recently analysed episodes. Sponsor reads and intros
    /// recur from one episode to the next, and inserted ads recur across shows.
    private func referenceFingerprints(excluding uid: String) -> Set<UInt64> {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.fingerprintData != nil && $0.uid != uid },
                                                  sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
        descriptor.fetchLimit = 12
        var reference = Set<UInt64>()
        for episode in (try? context.fetch(descriptor)) ?? [] {
            reference.formUnion(episode.fingerprint)
        }
        return reference
    }
}
