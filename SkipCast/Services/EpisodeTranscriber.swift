import Foundation
import AVFoundation
import Speech
import PodcastCore

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case onDeviceUnavailable
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition permission is needed to find ads. Enable it in Settings."
        case .onDeviceUnavailable: "On-device speech recognition isn’t available on this device or language."
        case .unreadableAudio: "The audio file couldn’t be read."
        }
    }
}

/// Turns a downloaded episode into a word-level transcript, entirely on the
/// device. Audio never leaves the phone.
///
/// The file is fed to the recogniser in chunks: one long request tends to
/// lose earlier text and reset its timestamps, whereas short chunks keep every
/// word and bound any timing error to a single chunk.
struct EpisodeTranscriber {
    var locale = Locale(identifier: "en-US")
    var chunkLength: TimeInterval = 60

    struct Outcome {
        /// The end of the file was reached (false: stopped early at the caller's request).
        var finished: Bool
        /// The iOS 26 long-form engine did the work, rather than the classic recogniser.
        var fastEngine: Bool
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes from `startTime` to the end, handing over each chunk as it
    /// is finished so results can be used while the scan is still running.
    ///
    /// - Parameter onChunk: receives the chunk's words, the time transcribed up
    ///   to, and the fraction of the file done. Return false to stop early
    ///   (the scan can be resumed later from the reported time).
    /// - Returns: whether the end of the file was reached, and which engine ran.
    func transcribe(_ url: URL, from startTime: TimeInterval = 0,
                    onChunk: @MainActor ([TranscriptSegment], TimeInterval, Double) -> Bool) async throws -> Outcome {
        guard await Self.requestAuthorization() else { throw TranscriptionError.notAuthorized }

        #if compiler(>=6.2)
        // iOS 26's long-form engine is far quicker than the classic recogniser.
        // If it can't be set up (unsupported device, model not downloadable),
        // carry on with the classic one below.
        if #available(iOS 26.0, *), let engine = try? await LongFormTranscriber.prepare(locale: locale) {
            return Outcome(finished: try await engine.transcribe(url, from: startTime, onChunk: onChunk), fastEngine: true)
        }
        #endif
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable }
        guard let file = try? AVAudioFile(forReading: url) else { throw TranscriptionError.unreadableAudio }

        let format = file.processingFormat
        let totalFrames = file.length
        let chunkFrames = AVAudioFramePosition(chunkLength * format.sampleRate)
        var chunkStart = min(totalFrames, max(0, AVAudioFramePosition(startTime * format.sampleRate)))

        while chunkStart < totalFrames {
            try Task.checkCancellation()
            let offset = Double(chunkStart) / format.sampleRate
            let frames = min(chunkFrames, totalFrames - chunkStart)
            let words = try await recognizeChunk(file: file, start: chunkStart, frames: frames, recognizer: recognizer)
            chunkStart += frames
            let shifted = words.map { TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
            let keepGoing = await onChunk(shifted, Double(chunkStart) / format.sampleRate, Double(chunkStart) / Double(totalFrames))
            if !keepGoing { return Outcome(finished: false, fastEngine: false) }
        }
        return Outcome(finished: true, fastEngine: false)
    }

    private func recognizeChunk(file: AVAudioFile, start: AVAudioFramePosition, frames: AVAudioFramePosition,
                                recognizer: SFSpeechRecognizer) async throws -> [TranscriptSegment] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        // Queue the whole chunk; the recogniser consumes it at its own pace.
        file.framePosition = start
        var remaining = frames
        let step = AVAudioFrameCount(file.processingFormat.sampleRate / 2)
        while remaining > 0 {
            let count = min(step, AVAudioFrameCount(remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
            do {
                try file.read(into: buffer, frameCount: count)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            request.append(buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        request.endAudio()

        let collector = Collector()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                collector.continuation = continuation
                collector.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        // On-device recognition finalises speech utterance by utterance and
                        // then starts a fresh transcription, so bank each finalised batch.
                        if result.speechRecognitionMetadata != nil || result.isFinal {
                            collector.bank(result.bestTranscription.segments)
                        }
                        if result.isFinal { collector.finish() }
                    }
                    // A chunk of music or silence ends with a "no speech" error; that's fine.
                    if error != nil { collector.finish() }
                }
            }
        } onCancel: {
            collector.task?.cancel()
            collector.finish()
        }
    }

    /// Accumulates finalised words from recognition callbacks, which arrive on
    /// an arbitrary queue.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var words: [TranscriptSegment] = []
        private var finished = false
        var continuation: CheckedContinuation<[TranscriptSegment], Never>?
        var task: SFSpeechRecognitionTask?

        func bank(_ segments: [SFTranscriptionSegment]) {
            lock.lock()
            defer { lock.unlock() }
            guard let first = segments.first else { return }
            let lastEnd = words.last?.end ?? 0
            // Timestamps are normally relative to the start of the audio. If a batch
            // appears to restart from zero, place it after what we already have.
            let shift = first.timestamp + 0.5 < lastEnd ? lastEnd : 0
            for segment in segments {
                let start = segment.timestamp + shift
                // Skip words already banked from an earlier, overlapping result.
                guard shift > 0 || start >= lastEnd - 0.05 else { continue }
                words.append(TranscriptSegment(start: start, end: start + segment.duration, text: segment.substring))
            }
        }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let result = words
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}
