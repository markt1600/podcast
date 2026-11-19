#if compiler(>=6.2)
import Foundation
import AVFoundation
import CoreMedia
import Speech
import OSLog
import PodcastCore

private let log = Logger(subsystem: "com.skipcast.app", category: "transcription")

/// Transcribes an episode with the long-form speech engine introduced in
/// iOS 26 (`SpeechAnalyzer`), which runs on the device and is built for
/// recordings of this length.
@available(iOS 26.0, *)
struct LongFormTranscriber {
    private let transcriber: Speech.SpeechTranscriber
    private let format: AVAudioFormat

    /// Checks that the engine can run here and makes sure its language model
    /// is installed (a one-time download managed by iOS).
    static func prepare(locale: Locale) async throws -> LongFormTranscriber {
        guard Speech.SpeechTranscriber.isAvailable,
              let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.onDeviceUnavailable
        }
        let transcriber = Speech.SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                                   attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log.info("Downloading speech model")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.onDeviceUnavailable
        }
        return LongFormTranscriber(transcriber: transcriber, format: format)
    }

    /// Same contract as `EpisodeTranscriber.transcribe`.
    func transcribe(_ url: URL, from startTime: TimeInterval,
                    onProgress: @escaping @Sendable (Double) -> Void,
                    onChunk: @MainActor ([TranscriptSegment], TimeInterval, Double) -> Bool) async throws -> Bool {
        guard let file = try? AVAudioFile(forReading: url),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw TranscriptionError.unreadableAudio
        }
        let sourceRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sourceRate
        file.framePosition = min(file.length, max(0, AVAudioFramePosition(startTime * sourceRate)))

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let progress = Progress(startTime)
        // The engine reports how far it has got even when nobody is speaking;
        // transcription results alone say nothing during music or silence.
        await analyzer.setVolatileRangeChangedHandler { range, _, _ in
            let reached = range.end.seconds
            if reached.isFinite { progress.advance(to: reached) }
        }
        let started = Date.now

        // Feeds audio a little ahead of the engine. Reading the whole file up
        // front would hold hours of decoded audio in memory.
        let feeder = Task.detached(priority: .utility) { [format] in
            defer { continuation.finish() }
            let step = AVAudioFrameCount(sourceRate * 10)
            var fed = startTime
            var first = true
            while !Task.isCancelled, file.framePosition < file.length {
                // Stay about two minutes ahead of the engine. If it shows no
                // progress for a second, feed it anyway: a long stretch without
                // speech must never leave both sides waiting on each other.
                var waited = 0.0
                var seen = progress.value
                while fed - progress.value > 120, waited < 1 {
                    try? await Task.sleep(for: .milliseconds(40))
                    if Task.isCancelled { return }
                    if progress.value > seen {
                        seen = progress.value
                        waited = 0
                    } else {
                        waited += 0.04
                    }
                }
                guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step),
                      (try? file.read(into: source, frameCount: step)) != nil, source.frameLength > 0,
                      let converted = Self.convert(source, with: converter, to: format) else { return }
                // The first buffer carries the time-code, so results are in episode time
                // even when resuming part-way through.
                let time = first ? CMTime(seconds: startTime, preferredTimescale: 600) : nil
                continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: time))
                first = false
                fed += Double(source.frameLength) / sourceRate
                if duration > 0 { onProgress(min(1, max(progress.value, fed - 120) / duration)) }
            }
        }
        let analysis = Task {
            if let last = try await analyzer.analyzeSequence(inputs) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }
        defer {
            feeder.cancel()
            analysis.cancel()
        }

        var pending: [TranscriptSegment] = []
        var lastReport = startTime
        do {
            for try await result in transcriber.results where result.isFinal {
                pending += Self.words(in: result)
                let reached = result.range.end.seconds
                progress.advance(to: reached)
                // Hand over about a minute of audio at a time.
                guard reached - lastReport >= 60 else { continue }
                lastReport = reached
                let keepGoing = await onChunk(pending, reached, duration > 0 ? min(1, reached / duration) : 0)
                pending = []
                if !keepGoing {
                    await analyzer.cancelAndFinishNow()
                    return false
                }
            }
            try await analysis.value
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        _ = await onChunk(pending, duration, 1)
        let elapsed = Date.now.timeIntervalSince(started)
        log.info("Transcribed \(Int(duration - startTime))s of audio in \(Int(elapsed))s")
        return true
    }

    /// Word-level timings from a result's attributed text.
    private static func words(in result: Speech.SpeechTranscriber.Result) -> [TranscriptSegment] {
        var words: [TranscriptSegment] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            words.append(TranscriptSegment(start: range.start.seconds, end: range.end.seconds, text: text))
        }
        if words.isEmpty {
            // No per-word timings: fall back to the timing of the whole phrase.
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                words.append(TranscriptSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
            }
        }
        return words
    }

    private static func convert(_ source: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// How far the engine has got, shared between the feeding and reading sides.
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Double

        init(_ value: Double) {
            stored = value
        }

        var value: Double {
            lock.withLock { stored }
        }

        /// Progress only moves forwards, whichever source reports it.
        func advance(to newValue: Double) {
            lock.withLock { stored = max(stored, newValue) }
        }
    }
}
#endif
