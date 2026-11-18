import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
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

                Section("Playback") {
                    Picker("Default speed", selection: $settings.playbackSpeed) {
                        ForEach(AppSettings.speeds, id: \.self) { Text(Format.speed($0)).tag($0) }
                    }
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
            .confirmationDialog("Delete all downloaded episodes?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete \(downloaded.count) episodes", role: .destructive) {
                    for episode in downloaded { downloads.removeDownload(for: episode) }
                }
            }
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
