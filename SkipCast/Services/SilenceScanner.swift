import Foundation
import AVFoundation
import Accelerate
import PodcastCore

/// Measures the loudness of a downloaded episode to find its pauses. This
/// only decodes the audio (no speech recognition), so it takes seconds.
enum SilenceScanner {
    static func scan(_ url: URL) -> [ClosedRange<TimeInterval>] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let window = 0.05
        let windowFrames = max(1, Int(format.sampleRate * window))
        let chunk = AVAudioFrameCount(windowFrames * 200)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }

        var levels: [Float] = []
        levels.reserveCapacity(Int(Double(file.length) / format.sampleRate / window) + 1)
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0,
                  let samples = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            var offset = 0
            while offset < frames {
                let count = min(windowFrames, frames - offset)
                var rms: Float = 0
                vDSP_rmsqv(samples[0] + offset, 1, &rms, vDSP_Length(count))
                levels.append(20 * log10(max(rms, 1e-7)))
                offset += count
            }
        }
        return SilenceFinder.silences(levels: levels, window: window)
    }
}
