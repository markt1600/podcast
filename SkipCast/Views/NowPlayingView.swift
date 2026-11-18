import SwiftUI
import MediaPlayer
import PodcastCore

struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Settings.self) private var settings
    @Environment(AdAnalysisService.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    @State private var tint: Color = .orange
    @State private var scrubTime: Double?
    @State private var showingDetail = false

    var body: some View {
        @Bindable var settings = settings
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
                             segments: episode.adSegments, minimumConfidence: settings.minimumAdConfidence) { value, finished in
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

                HStack(spacing: 10) {
                    Menu {
                        Picker("Speed", selection: Binding(get: { settings.playbackSpeed }, set: { player.setSpeed($0) })) {
                            ForEach(Settings.speeds, id: \.self) { Text(Format.speed($0)).tag($0) }
                        }
                    } label: {
                        Chip(text: Format.speed(settings.playbackSpeed), systemImage: "speedometer", active: settings.playbackSpeed != 1)
                    }
                    Button { settings.skipAds.toggle() } label: {
                        Chip(text: "Skip ads", systemImage: settings.skipAds ? "forward.end.fill" : "forward.end", active: settings.skipAds)
                    }
                    Button { settings.skipIntros.toggle() } label: {
                        Chip(text: "Skip intro", systemImage: "backward.end.alt", active: settings.skipIntros)
                    }
                    Button { showingDetail = true } label: {
                        Chip(text: "", systemImage: "info.circle", active: false)
                    }
                    .accessibilityLabel("Episode details")
                }

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
                Text("Listening for ads… \(Int(fraction * 100))%")
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
        .padding(.horizontal, 12)
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
    /// Called with the new time while dragging (`finished == false`) and on release.
    let onScrub: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)
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
