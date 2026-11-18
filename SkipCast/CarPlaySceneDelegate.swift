import CarPlay
import SwiftData
import UIKit

/// The app's CarPlay screens: Up Next, Shows (and their episodes), and the
/// system Now Playing screen with a speed button.
///
/// CarPlay only shows the app when it is signed with Apple's CarPlay audio
/// entitlement; see the README.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    private var interfaceController: CPInterfaceController?
    private var upNextTemplate: CPListTemplate?
    private var showsTemplate: CPListTemplate?
    private var model: AppModel { AppModel.shared }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self

        let upNext = CPListTemplate(title: "Up Next", sections: [CPListSection(items: upNextItems())])
        upNext.tabImage = UIImage(systemName: "play.circle")
        upNext.emptyViewTitleVariants = ["Nothing ready to play"]
        upNext.emptyViewSubtitleVariants = ["Downloaded episodes appear here."]
        let shows = CPListTemplate(title: "Shows", sections: [CPListSection(items: showItems())])
        shows.tabImage = UIImage(systemName: "square.grid.2x2")
        upNextTemplate = upNext
        showsTemplate = shows

        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            CPNowPlayingPlaybackRateButton { [weak self] _ in self?.cycleSpeed() },
        ])
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [upNext, shows]), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        upNextTemplate = nil
        showsTemplate = nil
    }

    /// Lists are rebuilt whenever they come into view, so they reflect what
    /// has been played or downloaded since.
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === upNextTemplate {
            upNextTemplate?.updateSections([CPListSection(items: upNextItems())])
        } else if aTemplate === showsTemplate {
            showsTemplate?.updateSections([CPListSection(items: showItems())])
        }
    }

    // MARK: - Lists

    private func upNextItems() -> [CPListItem] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isPlayed && ($0.position > 0 || $0.downloadStateRaw == 2) },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
        descriptor.fetchLimit = min(20, CPListTemplate.maximumItemCount)
        let episodes = (try? model.container.mainContext.fetch(descriptor)) ?? []
        return episodes.map { item(for: $0, inShowList: false) }
    }

    private func showItems() -> [CPListItem] {
        model.library.podcasts().prefix(CPListTemplate.maximumItemCount).map { podcast in
            let item = CPListItem(text: podcast.title, detailText: podcast.author)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                let episodes = podcast.sortedEpisodes.prefix(min(25, CPListTemplate.maximumItemCount))
                let list = CPListTemplate(title: podcast.title,
                                          sections: [CPListSection(items: episodes.map { self.item(for: $0, inShowList: true) })])
                self.interfaceController?.pushTemplate(list, animated: true, completion: nil)
                completion()
            }
            loadArtwork(podcast.artworkURL, into: item)
            return item
        }
    }

    private func item(for episode: Episode, inShowList: Bool) -> CPListItem {
        var details: [String] = [inShowList ? Format.date(episode.pubDate) : (episode.podcast?.title ?? "")]
        if episode.duration > 0 {
            details.append(episode.position > 0 && !episode.isPlayed
                ? "\(Format.length(episode.remaining)) left" : Format.length(episode.duration))
        }
        let item = CPListItem(text: episode.title, detailText: details.filter { !$0.isEmpty }.joined(separator: " · "))
        item.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            self.model.player.play(episode)
            if self.interfaceController?.topTemplate !== CPNowPlayingTemplate.shared {
                self.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            }
            completion()
        }
        if !inShowList { loadArtwork(episode.displayArtworkURL, into: item) }
        return item
    }

    private func loadArtwork(_ url: URL?, into item: CPListItem) {
        guard let url else { return }
        Task {
            if let image = await ArtworkLoader.shared.image(for: url, maxPixel: 180) { item.setImage(image) }
        }
    }

    // MARK: - Now Playing

    private func cycleSpeed() {
        let speeds = AppSettings.speeds
        let current = speeds.firstIndex { abs($0 - model.player.speed) < 0.001 } ?? 0
        model.player.setSpeed(speeds[(current + 1) % speeds.count])
    }
}
