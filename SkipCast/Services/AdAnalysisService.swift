import Foundation
import SwiftData
import Observation
import PodcastCore
import OSLog

private let log = Logger(subsystem: "com.skipcast.app", category: "scan")

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
    /// Episodes the user has asked to be scanned again, until that scan finishes.
    private(set) var rescanning: Set<String> = []
    /// Transcripts of scans that were set aside for a more urgent episode.
    @ObservationIgnored private var partials: [String: [TranscriptSegment]] = [:]
    @ObservationIgnored private var queue: [Episode] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var priorityUID: String?
    @ObservationIgnored private var isPublishingPartial = false

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

    /// Works out the intro again from what is already known about the episode
    /// (its ad breaks and show notes), without listening to it. Lets episodes
    /// scanned by an older version benefit from better intro rules.
    func refreshIntro(_ episode: Episode) {
        guard episode.contentStart == nil, episode.analysisState == .done else { return }
        episode.contentStart = IntroDetector().contentStart(in: [], ads: episode.adSegments,
                                                            chapters: ShowNotes.chapters(from: episode.summary),
                                                            episodeTitle: episode.title)
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

    /// Throws away what is known about an episode's ads and scans its audio
    /// afresh. Until the new scan finishes the episode counts as unscanned.
    func rescan(_ episode: Episode) {
        let uid = episode.uid
        // Already being scanned or waiting: nothing to add.
        guard currentUID != uid, !queue.contains(where: { $0.uid == uid }) else { return }
        partials[uid] = nil
        scannedUpTo[uid] = nil
        episode.adSegments = []
        episode.contentStart = nil
        episode.analysisIsFileSpecific = false
        episode.scanFailure = nil
        episode.analysisNote = nil
        episode.analysisState = .none
        rescanning.insert(uid)
        enqueue(episode, force: true)
        // Nothing to scan after all (the file is gone): don't leave it marked pending.
        if !queue.contains(where: { $0.uid == uid }) { rescanning.remove(uid) }
        try? context.save()
    }

    /// Queues every downloaded episode that still needs its audio scanned.
    ///
    /// The queue itself lives in memory, so this runs at each launch to pick up
    /// whatever was waiting, part-way through, or had failed when the app last
    /// exited. (`enqueue` leaves out episodes that don't need a scan.)
    func resume() {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.downloadStateRaw == 2 && !$0.analysisIsFileSpecific },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
        for episode in (try? context.fetch(descriptor)) ?? [] {
            if episode.analysisState == .queued || episode.analysisState == .analyzing { episode.analysisState = .none }
            enqueue(episode)
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
        // Reading the count ties views to changes in the queue, which is not
        // itself observed.
        _ = waitingCount
        return progress[episode.uid] != nil || queue.contains { $0.uid == episode.uid }
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
                // Set aside for a more urgent episode? Then it is still pending.
                if !queue.contains(where: { $0.uid == episode.uid }) { rescanning.remove(episode.uid) }
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

        if let file = episode.localFileURL {
            do {
                // Pick up where an interrupted scan of this episode left off.
                var words = partials[uid] ?? []
                progress[uid] = scannedUpTo[uid].map { episode.duration > 0 ? $0 / episode.duration : 0 } ?? 0
                // Loaded once per scan: it is the same for every interim result.
                evidence.reference = referenceFingerprints(excluding: uid)
                let startedAt = Date.now
                let startedFrom = scannedUpTo[uid] ?? 0
                var lastPublish = Date.now
                let outcome = try await EpisodeTranscriber().transcribe(file, from: startedFrom, onProgress: { fraction in
                    // Keeps the progress bar moving through music and silence,
                    // where no words (and so no chunks) arrive.
                    Task { @MainActor in
                        if let shown = self.progress[uid], fraction > shown { self.progress[uid] = fraction }
                    }
                }) { chunk, upTo, fraction in
                    words += chunk
                    self.progress[uid] = max(fraction, self.progress[uid] ?? 0)
                    self.scannedUpTo[uid] = upTo
                    // Now and then, publish what has been found so far, so skipping
                    // works on the part already scanned. Paced by the clock, not by
                    // audio covered: the fast engine gets through minutes of audio a
                    // second, and re-analysing that often would slow the scan itself.
                    if Date.now.timeIntervalSince(lastPublish) >= 20 {
                        lastPublish = .now
                        self.publishPartial(words, base: evidence, for: episode)
                    }
                    // Step aside if the user has started playing a different episode.
                    if let urgent = self.priorityUID, urgent != uid, self.queue.contains(where: { $0.uid == urgent }) {
                        return false
                    }
                    return true
                }
                progress[uid] = nil
                let finished = outcome.finished
                if finished {
                    let elapsed = max(1, Date.now.timeIntervalSince(startedAt))
                    let covered = max(0, (scannedUpTo[uid] ?? startedFrom) - startedFrom)
                    episode.scanInfo = "Scanned \(Format.length(covered)) of audio in \(Format.length(elapsed)), \(Int((covered / elapsed).rounded()))× speed"
                        + (outcome.fastEngine ? "" : " (classic speech engine)")
                    log.info("\(episode.scanInfo ?? "", privacy: .public)")
                }
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
                log.error("Scan of \(episode.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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

        if evidence.reference.isEmpty { evidence.reference = referenceFingerprints(excluding: uid) }
        let analysis = await Task.detached(priority: .utility) { [evidence] in
            EpisodeAnalyzer().analyze(evidence)
        }.value
        guard !episode.isDeleted else { return }

        if evidence.transcript.isEmpty && analysis.segments.isEmpty && analysis.contentStart == nil {
            episode.scanFailure = note
            if !hadQuickResult {
                episode.analysisState = .unavailable
                episode.analysisNote = note ?? "Download the episode to scan it for ads."
            } else if let note {
                episode.analysisNote = note
            }
            return
        }
        episode.scanFailure = fileSpecific ? nil : note
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
        episode.analysisNote = fileSpecific ? nil : (note ?? "From the publisher’s notes. Download the episode for exact timing.")
        try? context.save()
    }

    /// Analyses the part transcribed so far and stores the result, leaving the
    /// episode marked as still being scanned.
    private func publishPartial(_ words: [TranscriptSegment], base: EpisodeEvidence, for episode: Episode) {
        // One interim analysis at a time; the next one will cover more anyway.
        guard !isPublishingPartial else { return }
        isPublishingPartial = true
        var evidence = base
        evidence.transcript = words
        Task {
            defer { isPublishingPartial = false }
            let analysis = await Task.detached(priority: .utility) { [evidence] in
                EpisodeAnalyzer().analyze(evidence)
            }.value
            // The full result may have landed in the meantime.
            guard !episode.isDeleted, episode.analysisState != .done || !episode.analysisIsFileSpecific else { return }
            episode.adSegments = analysis.segments
            episode.contentStart = analysis.contentStart
        }
    }

    /// Fingerprints of recently analysed episodes. Sponsor reads and intros
    /// recur from one episode to the next, and inserted ads recur across shows.
    private func referenceFingerprints(excluding uid: String) -> Set<UInt64> {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.fingerprintData != nil && $0.uid != uid },
                                                  sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
        descriptor.fetchLimit = 8
        var reference = Set<UInt64>()
        for episode in (try? context.fetch(descriptor)) ?? [] {
            reference.formUnion(episode.fingerprint)
        }
        return reference
    }
}
