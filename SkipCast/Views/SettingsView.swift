import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(CloudSync.self) private var sync
    @Environment(ListeningStats.self) private var stats
    @Environment(Library.self) private var library
    @State private var importing = false
    @State private var importResult: String?
    @State private var exportURL: URL?
    @Query(filter: #Predicate<Episode> { $0.downloadStateRaw == 2 }) private var downloaded: [Episode]
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Skip ads", isOn: $settings.skipAds)
                    Toggle("Skip intros and outros", isOn: $settings.skipIntros)
                    Toggle("Scan new downloads automatically", isOn: $settings.autoAnalyze)
                    Picker("Sensitivity", selection: $settings.minimumAdConfidence) {
                        Text("Skip anything that looks like an ad").tag(0.3)
                        Text("Balanced").tag(0.5)
                        Text("Only skip when certain").tag(0.85)
                    }
                } header: {
                    Text("Ad skipping")
                } footer: {
                    Text("Ads are found by reading the show notes and by listening to downloaded episodes on this device. Nothing is uploaded. Every skip can be undone from the player, and a skipped section is always marked on the progress bar.")
                }

                Section {
                    Picker("Default speed", selection: $settings.playbackSpeed) {
                        ForEach(AppSettings.speeds, id: \.self) { Text(Format.speed($0)).tag($0) }
                    }
                    Toggle("Trim silence", isOn: $settings.trimSilence)
                    Toggle("Voice boost", isOn: $settings.voiceBoost)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("These are the defaults. Changing speed, trim silence or voice boost in the player is remembered for that show. Trim silence works on downloaded episodes.")
                }

                Section("Time saved") {
                    LabeledContent("This month", value: Format.length(stats.thisMonth.total))
                    LabeledContent("All time", value: Format.length(stats.allTime.total))
                    LabeledContent("Ads skipped", value: "\(stats.allTime.adCount) · \(Format.length(stats.allTime.adSeconds))")
                    LabeledContent("Intros skipped", value: Format.length(stats.allTime.introSeconds))
                    LabeledContent("Silence trimmed", value: Format.length(stats.allTime.silenceSeconds))
                }

                Section {
                    Button("Import subscriptions…", systemImage: "square.and.arrow.down") { importing = true }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export subscriptions", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let importResult {
                        Text(importResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Subscriptions")
                } footer: {
                    Text("Uses OPML, the file format other podcast apps export and import.")
                }

                Section {
                    Toggle("Download new episodes", isOn: $settings.autoDownload)
                    Stepper("Keep latest \(settings.keepCount) per show", value: $settings.keepCount, in: 1...20)
                        .disabled(!settings.autoDownload)
                    Toggle("Use mobile data", isOn: $settings.downloadOnCellular)
                        .disabled(!settings.autoDownload)
                    Toggle("Delete episodes after playing", isOn: $settings.autoDeletePlayed)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("A newly added show starts with its \(AppSettings.firstSyncCount) newest episodes, downloaded over Wi-Fi only. After that, new episodes download as they are published.")
                }

                Section {
                    LabeledContent("iCloud", value: sync.isAvailable ? "On" : "Not signed in")
                    if let date = sync.lastSync {
                        LabeledContent("Last synced", value: date.formatted(.relative(presentation: .named)))
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Subscriptions, per-show settings and where you are in each episode are shared with your other devices through iCloud.")
                }

                Section {
                    LabeledContent("Downloaded episodes", value: "\(downloaded.count)")
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: spaceUsed, countStyle: .file))
                    Button("Delete all downloads", role: .destructive) { confirmingDelete = true }
                        .disabled(downloaded.isEmpty)
                } header: {
                    Text("Storage")
                }
            }
            .navigationTitle("Settings")
            .task(id: library.isRefreshing) { exportURL = writeExportFile() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .text, .data]) { result in
                guard case .success(let url) = result else { return }
                Task { await importSubscriptions(from: url) }
            }
            .confirmationDialog("Delete all downloaded episodes?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete \(downloaded.count) episodes", role: .destructive) {
                    for episode in downloaded { downloads.removeDownload(for: episode) }
                }
            }
        }
    }

    private func importSubscriptions(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importResult = "That file couldn’t be read."
            return
        }
        importResult = "Importing…"
        let outcome = await library.importOPML(data)
        if outcome.found == 0 {
            importResult = "No podcast feeds were found in that file."
        } else {
            importResult = "Added \(outcome.added) of \(outcome.found) shows"
                + (outcome.failed > 0 ? "; \(outcome.failed) couldn’t be loaded." : ".")
                + (outcome.found - outcome.added - outcome.failed > 0 ? " The rest were already in your library." : "")
        }
    }

    /// Writes the subscription list where the share sheet can pick it up.
    private func writeExportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SkipCast subscriptions.opml")
        do {
            try library.exportOPML().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private var spaceUsed: Int64 {
        downloaded.reduce(0) { total, episode in
            guard let url = episode.localFileURL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return total }
            return total + Int64(size)
        }
    }
}
