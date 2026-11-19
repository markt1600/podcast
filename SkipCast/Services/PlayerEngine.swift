import Foundation
import AVFoundation
import MediaPlayer
import Observation
import PodcastCore

/// Audio playback: transport, speed, position saving, lock-screen controls,
/// and jumping over ads and intros.
@MainActor
@Observable
final class PlayerEngine {
    struct SkipEvent: Identifiable, Equatable {
        let id = UUID()
        let from: Double
        let to: Double
        let label: String
        /// Start of the skipped segment, used to undo.
        let segmentStart: Double?
    }

    private(set) var episode: Episode?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Most recent automatic skip, shown briefly with an Undo button.
    private(set) var lastSkip: SkipEvent?
    /// When the sleep timer will pause playback; nil if it is off.
    private(set) var sleepTimerEnd: Date?
    /// Set when show-notes timings can't be trusted for the audio being streamed.
    private(set) var skipDisabledReason: String?

    private let settings: AppSettings
    private let stats: ListeningStats
    @ObservationIgnored private var silenceObserver: Any?
    @ObservationIgnored private var silences: [ClosedRange<Double>] = []
    /// The pause playback is currently hurrying through, if any.
    @ObservationIgnored private var currentSilence: ClosedRange<Double>?
    /// Restores normal speed at the moment a pause ends.
    @ObservationIgnored private var silenceEnd: Task<Void, Never>?
    /// How much faster than the chosen speed pauses are played, and the
    /// fastest that may ever be.
    private static let silenceRate = 2.5
    private static let maximumSilenceRate = 4.0
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var lastSave = Date.distantPast
    /// Segments the user chose to hear (by undoing a skip or seeking into them).
    @ObservationIgnored private var allowedSegments: Set<Double> = []
    @ObservationIgnored private var wantsToPlay = false

    @ObservationIgnored var onFinished: ((Episode) -> Void)?
    /// Called when playback pauses or a show's speed changes, so state can be synced.
    @ObservationIgnored var onStateSaved: (() -> Void)?
    /// Called when playback starts, pauses or changes episode.
    @ObservationIgnored var onPlaybackChanged: (() -> Void)?
    @ObservationIgnored var onShowSettingChanged: ((Podcast) -> Void)?

    /// Speed for what is playing: the show's own if it has one, else the default.
    var speed: Double {
        episode?.podcast?.playbackSpeed ?? settings.playbackSpeed
    }
    @ObservationIgnored var onWillPlay: ((Episode) -> Void)?
    /// Called when the audio turns out not to match the show-notes timestamps.
    @ObservationIgnored var onNotesMismatch: ((Episode) -> Void)?

    init(settings: AppSettings, stats: ListeningStats) {
        self.settings = settings
        self.stats = stats
        player.automaticallyWaitsToMinimizeStalling = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        silenceObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.silenceTick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status != .paused
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self?.updateNowPlaying()
                self?.onPlaybackChanged?()
            }
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.finishEpisode()
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.savePosition()
                } else if type == .ended, options?.contains(.shouldResume) == true, self.wantsToPlay {
                    self.play()
                }
            }
        })
        configureRemoteCommands()
    }

    // MARK: - Transport

    func play(_ episode: Episode) {
        if self.episode?.uid == episode.uid {
            play()
            return
        }
        savePosition()
        onWillPlay?(episode)

        self.episode = episode
        allowedSegments = []
        lastSkip = nil
        skipDisabledReason = episode.notesTimingsUnreliable && !episode.analysisIsFileSpecific ? Self.mismatchReason : nil
        duration = episode.duration
        currentTime = episode.position

        let item = AVPlayerItem(url: episode.localFileURL ?? episode.audioURL)
        // Time-domain stretching keeps voices natural at 1.25–2×.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        endSilence(countAsTrimmed: false)
        silences = episode.silenceVersion == SilenceScanner.version ? episode.silences : []
        applyVoiceBoost()
        prepareSilences(for: episode)

        var start = episode.position
        // Near the end already? Start over rather than finishing instantly.
        if episode.duration > 0, start > episode.duration - 10 { start = 0 }
        if start < 1, settings.skipIntros {
            // A per-show setting made by the user wins over the detected start.
            let manual = episode.podcast?.introSkipSeconds ?? 0
            let introEnd = manual > 0 ? manual : (episode.contentStart ?? 0)
            if introEnd > 0, episode.duration == 0 || introEnd < episode.duration - 30 {
                start = introEnd
                lastSkip = SkipEvent(from: 0, to: introEnd, label: "Skipped intro", segmentStart: nil)
                stats.recordSkip(isAd: false, seconds: introEnd)
            }
        }
        if start > 0 {
            currentTime = start
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        episode.lastPlayedAt = .now
        play()
        loadArtwork(for: episode)
    }

    func play() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        wantsToPlay = true
        endSilence(countAsTrimmed: false)
        player.defaultRate = Float(speed)
        player.rate = Float(speed)
    }

    func pause() {
        wantsToPlay = false
        endSilence(countAsTrimmed: false)
        player.pause()
        savePosition()
        stats.flush()
        onStateSaved?()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// User-initiated seek.
    func seek(to time: Double) {
        let target = min(max(0, time), duration > 0 ? max(0, duration - 1) : time)
        // Seeking into an ad on purpose means the user wants to hear it.
        if let segment = activeSegments.first(where: { target >= $0.start && target < $0.end }) {
            allowedSegments.insert(segment.start)
        }
        jump(to: target)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Changes speed and remembers it for this show.
    func setSpeed(_ speed: Double) {
        if let podcast = episode?.podcast {
            podcast.playbackSpeed = speed
            onShowSettingChanged?(podcast)
        } else {
            settings.playbackSpeed = speed
        }
        player.defaultRate = Float(speed)
        if isPlaying { player.rate = Float(speed) }
        updateNowPlaying()
    }

    // MARK: - Trim silence and voice boost

    /// Whether pauses are shortened for what is playing: the show's own
    /// setting if it has one, else the default.
    var trimSilence: Bool {
        episode?.podcast?.trimSilence ?? settings.trimSilence
    }

    var voiceBoost: Bool {
        episode?.podcast?.voiceBoost ?? settings.voiceBoost
    }

    /// Whether silence trimming can work for this episode (it needs the file).
    var canTrimSilence: Bool {
        episode?.localFileURL != nil
    }

    /// Turns silence trimming on or off and remembers it for this show.
    func setTrimSilence(_ on: Bool) {
        guard let episode else { return }
        if let podcast = episode.podcast {
            podcast.trimSilence = on
            onShowSettingChanged?(podcast)
        } else {
            settings.trimSilence = on
        }
        if on {
            prepareSilences(for: episode)
        } else {
            endSilence(countAsTrimmed: false)
        }
    }

    func setVoiceBoost(_ on: Bool) {
        if let podcast = episode?.podcast {
            podcast.voiceBoost = on
            onShowSettingChanged?(podcast)
        } else {
            settings.voiceBoost = on
        }
        applyVoiceBoost()
    }

    private func applyVoiceBoost() {
        guard let item = player.currentItem else { return }
        guard voiceBoost else {
            item.audioMix = nil
            return
        }
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  item === player.currentItem, voiceBoost else { return }
            item.audioMix = VoiceBoost.audioMix(for: track)
        }
    }

    /// Finds the episode's pauses the first time they are needed.
    private func prepareSilences(for episode: Episode) {
        // Already worked out by this version (even if it found none)? Nothing to do.
        guard trimSilence, episode.silenceVersion != SilenceScanner.version, let file = episode.localFileURL else { return }
        let uid = episode.uid
        Task {
            let found = await Task.detached(priority: .utility) { SilenceScanner.scan(file) }.value
            guard !episode.isDeleted else { return }
            episode.silences = found
            episode.silenceVersion = SilenceScanner.version
            if self.episode?.uid == uid { silences = found }
        }
    }

    /// Plays pauses faster, and is back at normal speed before speech resumes.
    private func silenceTick(_ time: Double) {
        guard isPlaying, time.isFinite, currentSilence == nil, trimSilence,
              let silence = SilenceFinder.silence(at: time, in: silences) else {
            // Left the pause some other way (a seek, a skip): make sure speed is normal.
            if let current = currentSilence, time.isFinite, !current.contains(time) { endSilence(countAsTrimmed: false) }
            return
        }
        let fast = min(speed * Self.silenceRate, max(speed, Self.maximumSilenceRate))
        let remaining = silence.upperBound - time
        // Too little left to be worth a change of speed.
        guard fast > speed, remaining > 0.2 else { return }
        currentSilence = silence
        player.rate = Float(fast)
        // Checking the clock ten times a second would overshoot into the next
        // words at this speed, so the return to normal is timed exactly.
        silenceEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining / fast))
            guard !Task.isCancelled else { return }
            self?.endSilence(countAsTrimmed: true)
        }
    }

    private func endSilence(countAsTrimmed: Bool) {
        silenceEnd?.cancel()
        silenceEnd = nil
        guard let finished = currentSilence else { return }
        currentSilence = nil
        if isPlaying, wantsToPlay { player.rate = Float(speed) }
        if countAsTrimmed {
            // Time the pause would have taken, less the time it did take.
            let fast = min(speed * Self.silenceRate, max(speed, Self.maximumSilenceRate))
            let length = finished.upperBound - finished.lowerBound
            stats.recordSilence(seconds: length / speed - length / fast)
        }
    }

    static let sleepTimerOptions = [10, 15, 30, 45, 60]

    /// Pauses playback after the given number of minutes; nil turns the timer off.
    func setSleepTimer(minutes: Int?) {
        sleepTimerEnd = minutes.map { Date.now.addingTimeInterval(Double($0) * 60) }
    }

    /// Whole minutes left on the sleep timer, rounded up.
    var sleepMinutesRemaining: Int? {
        sleepTimerEnd.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) }
    }

    func undoLastSkip() {
        guard let skip = lastSkip else { return }
        if let start = skip.segmentStart { allowedSegments.insert(start) }
        stats.recordSkip(isAd: skip.label == "Skipped ad", seconds: -(skip.to - skip.from))
        lastSkip = nil
        jump(to: skip.from)
    }

    func dismissSkipNotice() {
        lastSkip = nil
    }

    /// Stops playback if this episode is loaded (e.g. its file is being deleted).
    func unload(_ episode: Episode) {
        guard self.episode?.uid == episode.uid, episode.localFileURL != nil else { return }
        savePosition()
        wantsToPlay = false
        player.replaceCurrentItem(with: nil)
        self.episode = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func jump(to time: Double) {
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    private static let mismatchReason = "This audio has extra ads inserted, so the show-notes timings don’t line up. Ads will be skipped once the downloaded episode has been scanned."

    // MARK: - Ad skipping

    /// Segments eligible for skipping right now.
    var activeSegments: [AdSegment] {
        guard let episode, skipDisabledReason == nil else { return [] }
        return episode.skippableSegments(ads: settings.skipAds, boilerplate: settings.skipIntros)
            .filter { $0.confidence >= settings.minimumAdConfidence && !allowedSegments.contains($0.start) }
    }

    private func tick(_ time: Double) {
        guard time.isFinite, let episode else { return }
        currentTime = time

        // The observer only fires while audio is playing, which is exactly when
        // the timer matters, and it keeps firing with the screen locked.
        if let end = sleepTimerEnd, Date.now >= end {
            sleepTimerEnd = nil
            pause()
            return
        }

        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0, itemDuration != duration {
            duration = itemDuration
            // Show-notes timings assume the publisher's master. If the stream is
            // noticeably longer, ads were inserted and those timings are off.
            if !episode.analysisIsFileSpecific, episode.duration > 0, abs(itemDuration - episode.duration) > 20,
               !episode.adSegments.isEmpty {
                skipDisabledReason = Self.mismatchReason
                episode.notesTimingsUnreliable = true
                onNotesMismatch?(episode)
            }
            if episode.duration == 0 || episode.analysisIsFileSpecific || episode.localFileURL != nil { episode.duration = itemDuration }
            updateNowPlaying()
        }

        if isPlaying, let hit = AdSkipPlanner.skipTarget(at: time, segments: activeSegments) {
            let target = duration > 0 ? min(hit.target, duration - 0.5) : hit.target
            lastSkip = SkipEvent(from: time, to: target, label: hit.segment.kind == .ad ? "Skipped ad" : "Skipped intro",
                                 segmentStart: hit.segment.start)
            stats.recordSkip(isAd: hit.segment.kind == .ad, seconds: target - time)
            jump(to: target)
        }

        if Date.now.timeIntervalSince(lastSave) > 5 { savePosition() }
    }

    private func savePosition() {
        guard let episode, !episode.isDeleted else { return }
        episode.position = currentTime
        episode.stateUpdatedAt = .now
        lastSave = .now
    }

    private func finishEpisode() {
        guard let episode else { return }
        wantsToPlay = false
        player.replaceCurrentItem(with: nil)
        self.episode = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onFinished?(episode)
    }

    // MARK: - Lock screen & remote controls

    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    private func loadArtwork(for episode: Episode) {
        artwork = nil
        guard let url = episode.displayArtworkURL else { return }
        let uid = episode.uid
        Task {
            guard let image = await ArtworkLoader.shared.image(for: url, maxPixel: 600), self.episode?.uid == uid else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let episode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcast?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 30) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -30) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}
