import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks

/// Owns the long-lived services and wires them together.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let settings: AppSettings
    let downloads: DownloadManager
    let library: Library
    let player: PlayerEngine
    let analysis: AdAnalysisService
    let sync: CloudSync

    static let shared = AppModel()

    /// Identifier of the periodic background check for new episodes
    /// (also listed in Info.plist).
    static let refreshTaskID = "com.skipcast.refresh"

    /// Asks iOS to wake the app later to check for new episodes. iOS picks the
    /// actual moment, based on how the app is used; this only sets the earliest.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date.now.addingTimeInterval(3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs when iOS grants a background refresh: look for new episodes (their
    /// downloads then continue on their own) and book the next check.
    static func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await shared.library.refreshAll()
        try? shared.container.mainContext.save()
    }

    private init() {
        do {
            container = try ModelContainer(for: Podcast.self, Episode.self)
        } catch {
            // A store that can't be opened leaves the app with nothing to show.
            fatalError("Could not open the podcast library: \(error)")
        }
        let context = container.mainContext
        settings = AppSettings()
        downloads = DownloadManager(context: context, settings: settings)
        library = Library(context: context, settings: settings, downloads: downloads)
        player = PlayerEngine(settings: settings)
        analysis = AdAnalysisService(context: context)
        sync = CloudSync(context: context, library: library)

        downloads.onDownloaded = { [unowned self] episode in
            if settings.autoAnalyze { analysis.enqueue(episode) }
        }
        downloads.onWillRemove = { [unowned self] episode in
            player.unload(episode)
        }
        player.onWillPlay = { [unowned self] episode in
            analysis.quickScan(episode)
            if settings.autoAnalyze { analysis.prioritize(episode) }
        }
        player.onNotesMismatch = { [unowned self] episode in
            analysis.enqueue(episode, force: true)
        }
        player.onFinished = { [unowned self] episode in
            library.markPlayed(episode, played: true)
        }
        player.onStateSaved = { [unowned self] in
            sync.schedule()
        }
        player.onSpeedChanged = { [unowned self] podcast in
            library.showSettingsChanged(podcast)
        }
        library.onChange = { [unowned self] in
            sync.schedule()
        }
        sync.currentEpisodeUID = { [unowned self] in
            player.episode?.uid
        }
        downloads.resume()
        analysis.resume()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in AppModel.shared.downloads.backgroundCompletion = completionHandler }
    }
}

@main
struct SkipCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.downloads)
                .environment(model.library)
                .environment(model.player)
                .environment(model.analysis)
                .environment(model.sync)
                .tint(.orange)
                .task {
                    await model.library.addStarterShowsIfNeeded()
                    await model.sync.syncNow()
                    await model.library.refreshIfStale(maxAge: 300)
                }
        }
        .modelContainer(model.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                try? model.container.mainContext.save()
                AppModel.scheduleBackgroundRefresh()
                Task { await model.sync.syncNow() }
            } else if phase == .active {
                model.sync.schedule(after: 1)
                // Back in the app after a while: see what has been published since.
                Task { await model.library.refreshIfStale() }
            }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) {
            await AppModel.backgroundRefresh()
        }
    }
}
