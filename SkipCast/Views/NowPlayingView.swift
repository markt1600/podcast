import SwiftUI
import MediaPlayer
import PodcastCore

struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AdAnalysisService.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    @State private var tint: Color = .orange
    @State private var scrubTime: Double?
    @State private var showingDetail = false

    var body: some View {
        if let episode = player.episode {
            VStack(spacing: 18) {
                Spacer(minLength: 12)
                ArtworkView(url: episode.displayArtworkURL, cornerRadius: 24, maxPixel: 900)
                    .frame(maxWidth: 320)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.9)
                    .animation(.spring(duration: 0.4), value: player.isPlaying)
                    .padding(.horizontal, 32)

                VStack(spacing: 4) {
                    Text(episode.title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(episode.podcast?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)

                skipNotice

                VStack(spacing: 6) {
                    Scrubber(time: scrubTime ?? player.currentTime, duration: player.duration,
                             segments: episode.adSegments, minimumConfidence: settings.minimumAdConfidence,
                             scannedUpTo: scannedExtent(of: episode)) { value, finished in
                        if finished {
                            player.seek(to: value)
                            scrubTime = nil
                        } else {
                            scrubTime = value
                        }
                    }
                    HStack {
                        Text(Format.clock(scrubTime ?? player.currentTime))
                        Spacer()
                        Text("-" + Format.clock(max(0, player.duration - (scrubTime ?? player.currentTime))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 44) {
                    Button { player.skip(by: -30) } label: {
                        Image(systemName: "gobackward.30").font(.system(size: 32))
                    }
                    .accessibilityLabel("Back 30 seconds")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 76))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skip(by: 30) } label: {
                        Image(systemName: "goforward.30").font(.system(size: 32))
                    }
                    .accessibilityLabel("Forward 30 seconds")
                }
                .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Menu {
                        Picker("Speed for this show", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                            ForEach(AppSettings.speeds, id: \.self) { Text(Format.speed($0)).tag($0) }
                        }
                    } label: {
                        Chip(text: Format.speed(player.speed), systemImage: "speedometer", active: player.speed != 1)
                    }
                    Button { settings.skipAds.toggle() } label: {
                        Chip(text: "Skip ads", systemImage: settings.skipAds ? "forward.end.fill" : "forward.end", active: settings.skipAds)
                    }
                    Button { settings.skipIntros.toggle() } label: {
                        Chip(text: "Skip intro", systemImage: "backward.end.alt", active: settings.skipIntros)
                    }
                    Menu {
                        ForEach(PlayerEngine.sleepTimerOptions, id: \.self) { minutes in
                            Button(minutes == 60 ? "1 hour" : "\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                        }
                        if player.sleepTimerEnd != nil {
                            Button("Turn off", systemImage: "xmark", role: .destructive) { player.setSleepTimer(minutes: nil) }
                        }
                    } label: {
                        Chip(text: player.sleepMinutesRemaining.map { "\($0)m" } ?? "", systemImage: "moon.zzz.fill",
                             active: player.sleepTimerEnd != nil)
                    }
                    .accessibilityLabel(player.sleepMinutesRemaining.map { "Sleep timer, \($0) minutes left" } ?? "Sleep timer")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                adStatus(for: episode)

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                    SystemVolumeSlider()
                        .frame(height: 30)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button { showingDetail = true } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .padding(18)
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Episode details")
            }
            .background {
                LinearGradient(colors: [tint.opacity(0.55), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            }
            .task(id: episode.displayArtworkURL) {
                guard let url = episode.displayArtworkURL,
                      let image = await ArtworkLoader.shared.image(for: url, maxPixel: 900),
                      let color = image.averageColor else { return }
                withAnimation(.easeInOut(duration: 0.5)) { tint = color }
            }
            .sheet(isPresented: $showingDetail) { EpisodeDetailView(episode: episode) }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "play.slash")
                .onAppear { dismiss() }
        }
    }

    /// How much of the episode has been scanned, in seconds; nil if not applicable.
    private func scannedExtent(of episode: Episode) -> Double? {
        if let upTo = analysis.scannedUpTo[episode.uid] { return upTo }
        return episode.analysisState == .done && episode.analysisIsFileSpecific ? player.duration : nil
    }

    @ViewBuilder private var skipNotice: some View {
        if let skip = player.lastSkip {
            HStack(spacing: 10) {
                Label("\(skip.label) · \(Format.length(skip.to - skip.from))", systemImage: "forward.end.fill")
                    .font(.footnote.weight(.semibold))
                Button("Undo") { player.undoLastSkip() }
                    .font(.footnote.weight(.bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.2), in: Capsule())
            .transition(.scale.combined(with: .opacity))
            .task(id: skip.id) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { player.dismissSkipNotice() }
            }
        }
    }

    @ViewBuilder private func adStatus(for episode: Episode) -> some View {
        Group {
            if let reason = player.skipDisabledReason {
                Text(reason)
            } else if let fraction = analysis.progress[episode.uid] {
                Text("Scanning for ads… \(Int(fraction * 100))%"
                     + (analysis.scannedUpTo[episode.uid].map { " · ads skipped up to \(Format.clock($0))" } ?? ""))
            } else if episode.downloadState == .downloaded, analysis.isWorking(on: episode) {
                Text("Waiting to scan · this episode is next")
            } else if episode.scanSkippedForShow {
                Text("This show doesn’t carry ads, so it isn’t scanned")
            } else if episode.analysisState == .done {
                let ads = episode.adSegments.filter { $0.kind == .ad }
                Text(ads.isEmpty ? "No ads found in this episode"
                     : "\(ads.count) ad break\(ads.count == 1 ? "" : "s") found · \(Format.length(ads.reduce(0) { $0 + $1.duration }))"
                        + (episode.analysisIsFileSpecific ? "" : " · from show notes"))
            } else if episode.downloadState != .downloaded {
                Text("Download this episode to find its ads")
            } else {
                Text("Not scanned for ads yet")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
}

private struct Chip: View {
    let text: String
    let systemImage: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            if !text.isEmpty { Text(text) }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.thinMaterial), in: Capsule())
    }
}

/// Progress bar with ad breaks marked, draggable to seek.
private struct Scrubber: View {
    let time: Double
    let duration: Double
    let segments: [AdSegment]
    let minimumConfidence: Double
    /// Scanned portion of the episode, drawn as a thin line under the bar.
    var scannedUpTo: Double?
    /// Called with the new time while dragging (`finished == false`) and on release.
    let onScrub: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)
                if let scannedUpTo, duration > 0 {
                    Capsule()
                        .fill(Color.orange.opacity(0.55))
                        .frame(width: width * min(1, scannedUpTo / duration), height: 2)
                        .offset(y: 7)
                }
                Capsule().fill(.primary.opacity(0.85)).frame(width: width * fraction, height: 6)
                if duration > 0 {
                    ForEach(segments, id: \.start) { segment in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segment.kind == .ad ? Color.orange : Color.teal)
                            .opacity(segment.confidence >= minimumConfidence ? 1 : 0.4)
                            .frame(width: max(3, width * (segment.end - segment.start) / duration), height: 6)
                            .offset(x: width * min(1, segment.start / duration))
                    }
                }
                Circle()
                    .fill(.primary)
                    .frame(width: 14, height: 14)
                    .offset(x: width * fraction - 7)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        onScrub(min(1, max(0, value.location.x / width)) * duration, false)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        onScrub(min(1, max(0, value.location.x / width)) * duration, true)
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Format.clock(time)) of \(Format.clock(duration))")
        .accessibilityAdjustableAction { direction in
            onScrub(time + (direction == .increment ? 30 : -30), true)
        }
    }
}

/// The system volume control (same as the hardware buttons), with AirPlay routing.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        MPVolumeView(frame: .zero)
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
