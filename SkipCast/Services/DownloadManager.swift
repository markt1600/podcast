import Foundation
import SwiftData
import Observation
import OSLog

private let log = Logger(subsystem: "com.skipcast.app", category: "downloads")

/// Downloads episode audio with a background URLSession so transfers keep
/// going while the app is suspended.
@MainActor
@Observable
final class DownloadManager: NSObject {
    private let context: ModelContext
    private let settings: AppSettings

    /// Fraction complete by episode uid, for episodes currently downloading.
    private(set) var progress: [String: Double] = [:]
    /// Called on the main actor when a file has landed on disk.
    @ObservationIgnored var onDownloaded: ((Episode) -> Void)?
    /// Called just before a downloaded file is deleted.
    @ObservationIgnored var onWillRemove: ((Episode) -> Void)?
    /// Completion handler handed over by the system when it relaunches us for
    /// background session events.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.skipcast.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
        super.init()
    }

    /// Reconnects to transfers that were running when the app last exited and
    /// clears "downloading" flags that no longer have a task behind them.
    func resume() {
        let session = session
        Task {
            let tasks = await session.allTasks
            let active = Set(tasks.compactMap(\.taskDescription))
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.downloadStateRaw == 1 })
            for episode in (try? context.fetch(descriptor)) ?? [] where !active.contains(episode.uid) {
                episode.downloadState = .none
            }
        }
    }

    func download(_ episode: Episode, automatic: Bool = false) {
        guard episode.downloadState == .none else { return }
        var request = URLRequest(url: episode.audioURL)
        request.allowsCellularAccess = !automatic || settings.downloadOnCellular
        let task = session.downloadTask(with: request)
        task.taskDescription = episode.uid
        episode.downloadState = .downloading
        progress[episode.uid] = 0
        task.resume()
        log.info("Started download of \(episode.title, privacy: .public)")
    }

    func cancel(_ episode: Episode) {
        let uid = episode.uid
        session.getAllTasks { tasks in
            tasks.first { $0.taskDescription == uid }?.cancel()
        }
        episode.downloadState = .none
        progress[uid] = nil
    }

    func removeDownload(for episode: Episode) {
        if episode.downloadState == .downloading { cancel(episode) }
        guard episode.downloadState == .downloaded else { return }
        onWillRemove?(episode)
        if let name = episode.localFileName {
            try? FileManager.default.removeItem(at: Episode.downloadsDirectory.appendingPathComponent(name))
        }
        episode.localFileName = nil
        episode.downloadState = .none
        // Timings measured on the deleted file don't apply to a fresh stream,
        // which may have different ads stitched in.
        if episode.analysisIsFileSpecific {
            episode.adSegments = []
            episode.contentStart = nil
            episode.analysisState = .none
            episode.analysisNote = nil
            episode.analysisIsFileSpecific = false
        }
    }

    private func episode(uid: String) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func finished(uid: String, fileName: String?, error: String?) {
        progress[uid] = nil
        if let error {
            log.error("Download \(uid, privacy: .public) failed: \(error, privacy: .public)")
        } else {
            log.info("Download \(uid, privacy: .public) finished")
        }
        guard let episode = episode(uid: uid) else {
            // Episode was removed while downloading; don't leave an orphan file.
            if let fileName { try? FileManager.default.removeItem(at: Episode.downloadsDirectory.appendingPathComponent(fileName)) }
            return
        }
        if let fileName {
            episode.localFileName = fileName
            episode.downloadState = .downloaded
            try? context.save()
            onDownloaded?(episode)
        } else if episode.downloadState == .downloading {
            episode.downloadState = .none
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let uid = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            // Only publish visible steps; this fires many times a second.
            if fraction - (self.progress[uid] ?? 0) >= 0.01 { self.progress[uid] = fraction }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let uid = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            Task { @MainActor in self.finished(uid: uid, fileName: nil, error: "HTTP \(status)") }
            return
        }
        // The temporary file disappears when this method returns, so move it now.
        let ext = downloadTask.originalRequest?.url?.pathExtension ?? ""
        let fileName = uid + "." + (ext.isEmpty || ext.count > 4 ? "mp3" : ext)
        let destination = Episode.downloadsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in self.finished(uid: uid, fileName: fileName, error: nil) }
        } catch {
            Task { @MainActor in self.finished(uid: uid, fileName: nil, error: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let uid = task.taskDescription else { return }
        Task { @MainActor in self.finished(uid: uid, fileName: nil, error: error.localizedDescription) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
