import Foundation
import AVFoundation
import MediaToolbox

/// Evens out speech loudness: quiet voices come up, loud ones are held back,
/// so everyone is audible at one volume setting (a compressor with make-up
/// gain, applied to the audio as it plays).
enum VoiceBoost {
    /// An audio mix that applies the boost to the given track, or nil if the
    /// processing tap can't be created.
    static func audioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: { _, _, storageOut in
                storageOut.pointee = Unmanaged.passRetained(Compressor()).toOpaque()
            },
            finalize: { tap in
                Unmanaged<Compressor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let compressor = Unmanaged<Compressor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                compressor.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let compressor = Unmanaged<Compressor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                compressor.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Runs on the audio thread: no allocation, no locks.
    private final class Compressor {
        private var usable = false
        private var interleaved = false
        private var channels = 1
        private var envelope: Float = 0
        private var attack: Float = 0
        private var release: Float = 0

        // Speech sits around -24 dBFS and above; compress what exceeds that 3:1
        // and bring the whole signal up.
        private let thresholdDB: Float = -24
        private let slope: Float = 1 - 1 / 3
        private let makeupDB: Float = 9

        func prepare(_ format: AudioStreamBasicDescription) {
            // Only 32-bit float PCM is handled; anything else passes through untouched.
            usable = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            channels = max(1, Int(format.mChannelsPerFrame))
            let rate = Float(format.mSampleRate > 0 ? format.mSampleRate : 44_100)
            attack = exp(-1 / (0.005 * rate))
            release = exp(-1 / (0.15 * rate))
            envelope = 0
        }

        func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            guard usable, frames > 0, !buffers.isEmpty else { return }
            if interleaved {
                guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let count = min(frames, Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels))
                for frame in 0..<count {
                    var peak: Float = 0
                    for channel in 0..<channels { peak = max(peak, abs(data[frame * channels + channel])) }
                    let gain = nextGain(peak)
                    for channel in 0..<channels {
                        data[frame * channels + channel] = min(1, max(-1, data[frame * channels + channel] * gain))
                    }
                }
            } else {
                let count = buffers.reduce(frames) { min($0, Int($1.mDataByteSize) / MemoryLayout<Float>.size) }
                for frame in 0..<count {
                    // One gain for all channels keeps the stereo image steady.
                    var peak: Float = 0
                    for buffer in buffers {
                        if let data = buffer.mData?.assumingMemoryBound(to: Float.self) { peak = max(peak, abs(data[frame])) }
                    }
                    let gain = nextGain(peak)
                    for buffer in buffers {
                        if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                            data[frame] = min(1, max(-1, data[frame] * gain))
                        }
                    }
                }
            }
        }

        private func nextGain(_ peak: Float) -> Float {
            let coefficient = peak > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * peak
            let levelDB = 20 * log10(max(envelope, 1e-6))
            let reduction = max(0, levelDB - thresholdDB) * slope
            return pow(10, (makeupDB - reduction) / 20)
        }
    }
}
