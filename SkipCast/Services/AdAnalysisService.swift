import Foundation
import SwiftData
import Observation
import PodcastCore

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
    @ObservationIgnored private var queue: [Episode] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
    }

    /// Instant pass over show notes. Safe to call repeatedly.
    func quickScan(_ episode: Episode) {
        guard episode.analysisState == .none else { return }
        var evidence = EpisodeEvidence()
        evidence.showNotes = episode.summary
        evidence.duration = episode.duration > 0 ? episode.duration : nil
        let analysis = EpisodeAnalyzer().analyze(evidence)
        guard !analysis.segments.isEmpty || analysis.contentStart != nil else { return }
        episode.adSegments = analysis.segments
        episode.contentStart = analysis.contentStart
        episode.analysisIsFileSpecific = false
        episode.analysisState = .done
        episode.analysisNote = "From the show notes. Download the episode for exact timing."
    }

    /// Queues a full scan of a downloaded episode.
    func enqueue(_ episode: Episode, force: Bool = false) {
        guard force || !episode.analysisIsFileSpecific || episode.analysisState != .done else { return }
        guard episode.localFileURL != nil || episode.transcriptURL != nil || episode.chaptersURL != nil else {
            quickScan(episode)
            return
        }
        guard !queue.contains(where: { $0.uid == episode.uid }) else { return }
        if episode.analysisState != .done { episode.analysisState = .queued }
        queue.append(episode)
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

    func isWorking(on episode: Episode) -> Bool {
        progress[episode.uid] != nil || queue.contains { $0.uid == episode.uid }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            // One at a time: transcription is CPU heavy.
            while !queue.isEmpty {
                let episode = queue.removeFirst()
                guard !episode.isDeleted else { continue }
                await analyze(episode)
            }
            worker = nil
        }
    }

    private func analyze(_ episode: Episode) async {
        let hadQuickResult = episode.analysisState == .done
        if !hadQuickResult { episode.analysisState = .analyzing }
        let uid = episode.uid
        var evidence = EpisodeEvidence()
        evidence.showNotes = episode.summary
        evidence.duration = episode.duration > 0 ? episode.duration : nil
        var note: String?
        var fileSpecific = false

        if let file = episode.localFileURL {
            do {
                progress[uid] = 0
                evidence.transcript = try await SpeechTranscriber().transcribe(file) { fraction in
                    Task { @MainActor in self.progress[uid] = fraction }
                }
                fileSpecific = true
            } catch {
                note = error.localizedDescription
            }
            progress[uid] = nil
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
        if fileSpecific { episode.fingerprint = analysis.fingerprint }
        episode.analysisIsFileSpecific = fileSpecific
        episode.analysisState = .done
        episode.analysisNote = fileSpecific ? nil : (note ?? "From the publisher’s notes. Download the episode for exact timing.")
        try? context.save()
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
