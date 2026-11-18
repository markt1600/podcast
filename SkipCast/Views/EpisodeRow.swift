import SwiftUI
import PodcastCore

struct EpisodeRow: View {
    let episode: Episode
    var showsArtwork = true

    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(Library.self) private var library
    @Environment(AdAnalysisService.self) private var analysis
    @State private var showingDetail = false

    private var isCurrent: Bool { player.episode?.uid == episode.uid }

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                ArtworkView(url: episode.displayArtworkURL, cornerRadius: 8, maxPixel: 200)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(.orange)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                    Text(metadata)
                    adBadge
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if episode.position > 0, !episode.isPlayed, episode.duration > 0 {
                    ProgressView(value: episode.progress)
                        .tint(.orange)
                }
            }
            Spacer(minLength: 4)
            downloadButton
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent { player.togglePlayPause() } else { player.play(episode) }
        }
        .swipeActions(edge: .leading) {
            Button(episode.isPlayed ? "Unplayed" : "Played", systemImage: episode.isPlayed ? "circle" : "checkmark.circle") {
                library.markPlayed(episode, played: !episode.isPlayed)
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            if episode.downloadState != .none {
                Button("Remove", systemImage: "trash", role: .destructive) { downloads.removeDownload(for: episode) }
            }
            Button("Details", systemImage: "info.circle") { showingDetail = true }
                .tint(.gray)
        }
        .sheet(isPresented: $showingDetail) {
            EpisodeDetailView(episode: episode)
        }
    }

    private var metadata: String {
        var parts = [Format.date(episode.pubDate)]
        if episode.duration > 0 {
            parts.append(episode.position > 0 && !episode.isPlayed ? "\(Format.length(episode.remaining)) left" : Format.length(episode.duration))
        }
        if episode.isPlayed { parts.append("Played") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var adBadge: some View {
        if let fraction = analysis.progress[episode.uid] {
            Label("Scanning \(Int(fraction * 100))%", systemImage: "waveform.badge.magnifyingglass")
                .foregroundStyle(.orange)
        } else if episode.downloadState == .downloaded, episode.analysisState == .queued || analysis.isWorking(on: episode) {
            Label("Waiting to scan", systemImage: "clock")
        } else if episode.analysisState == .done {
            let ads = episode.adSegments.filter { $0.kind == .ad }
            if episode.analysisIsFileSpecific {
                // Fully scanned: the seal says the timings were measured on this audio.
                Label(ads.isEmpty ? "No ads" : "\(ads.count) ad\(ads.count == 1 ? "" : "s")", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(ads.isEmpty ? Color.secondary : Color.orange)
            } else if !ads.isEmpty {
                // Taken from the publisher's show notes; no scan needed.
                Label("\(ads.count) ad\(ads.count == 1 ? "" : "s") · from notes", systemImage: "checkmark.seal")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var downloadButton: some View {
        switch episode.downloadState {
        case .none:
            Button { downloads.download(episode) } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download")
        case .downloading:
            Button { downloads.cancel(episode) } label: {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: downloads.progress[episode.uid] ?? 0)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 8))
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel download")
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        }
    }
}

/// Show notes plus what the ad scan found.
struct EpisodeDetailView: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss
    @Environment(AdAnalysisService.self) private var analysis
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        ArtworkView(url: episode.displayArtworkURL, cornerRadius: 12)
                            .frame(width: 90, height: 90)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.podcast?.title ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(episode.title)
                                .font(.headline)
                            Text([Format.date(episode.pubDate), episode.duration > 0 ? Format.length(episode.duration) : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                Section("Ads & intro") {
                    scanStatus
                    if let start = episode.contentStart {
                        LabeledContent("Episode starts at", value: Format.clock(start))
                    }
                    ForEach(episode.adSegments, id: \.start) { segment in
                        Button {
                            player.play(episode)
                            player.seek(to: segment.start)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("\(Format.clock(segment.start)) – \(Format.clock(segment.end))")
                                        .font(.subheadline.monospacedDigit().weight(.medium))
                                    Spacer()
                                    Text(segment.kind == .ad ? "Ad · \(Format.length(segment.duration))" : "Intro/outro · \(Format.length(segment.duration))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !segment.reason.isEmpty {
                                    Text(segment.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                if !episode.summary.isEmpty {
                    Section("Show notes") {
                        Text(episode.summary)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { analysis.quickScan(episode) }
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if let fraction = analysis.progress[episode.uid] {
            ProgressView(value: fraction) {
                Text("Listening for ads… \(Int(fraction * 100))%").font(.subheadline)
            } currentValueLabel: {
                if let upTo = analysis.scannedUpTo[episode.uid] {
                    Text("Scanned to \(Format.clock(upTo)). Ads before that point are already skipped.")
                }
            }
        } else if episode.analysisState == .queued || episode.analysisState == .analyzing {
            Label("Waiting to scan", systemImage: "clock")
        } else {
            if episode.analysisState == .done {
                let ads = episode.adSegments.filter { $0.kind == .ad }
                Label(ads.isEmpty ? "No ads found" : "\(ads.count) ad break\(ads.count == 1 ? "" : "s"), \(Format.length(ads.reduce(0) { $0 + $1.duration })) total",
                      systemImage: episode.analysisIsFileSpecific ? "checkmark.seal.fill" : "list.bullet.rectangle")
            }
            if let note = episode.analysisNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if episode.downloadState == .downloaded {
                Button(episode.analysisIsFileSpecific ? "Scan again" : "Scan audio for ads", systemImage: "waveform.badge.magnifyingglass") {
                    analysis.enqueue(episode, force: true)
                }
            } else if episode.downloadState == .none {
                Button("Download and scan", systemImage: "arrow.down.circle") { downloads.download(episode) }
            }
        }
    }
}
