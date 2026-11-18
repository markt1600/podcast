import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum RSSParserError: Error {
    case invalidFeed(String)
}

/// Parses a podcast RSS feed, including the iTunes and Podcasting 2.0
/// (`podcast:transcript`, `podcast:chapters`) extensions.
public enum RSSParser {
    public static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || delegate.sawChannel else {
            throw RSSParserError.invalidFeed(parser.parserError?.localizedDescription ?? "Not a podcast feed")
        }
        guard delegate.sawChannel else { throw RSSParserError.invalidFeed("No <channel> element") }
        return delegate.feed
    }

    /// Parses `1:02:03`, `62:03` or plain seconds.
    public static func parseDuration(_ string: String) -> TimeInterval? {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var feed = ParsedFeed()
        var sawChannel = false

        private var path: [String] = []
        private var text = ""
        private var item: Item?

        /// Episode under construction; the enclosure may arrive at any point.
        private struct Item {
            var guid = ""
            var title = ""
            var description = ""
            var itunesSummary = ""
            var pubDate: Date?
            var duration: TimeInterval?
            var audioURL: URL?
            var fileSize: Int64?
            var artworkURL: URL?
            var transcripts: [TranscriptLink] = []
            var chaptersURL: URL?
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = name.lowercased()
            path.append(name)
            text = ""

            switch name {
            case "channel":
                sawChannel = true
            case "item":
                item = Item()
            case "enclosure":
                guard item != nil, let urlString = attributes["url"], let url = URL(string: urlString) else { break }
                let type = attributes["type"] ?? ""
                // Prefer audio enclosures, but accept untyped ones.
                if item?.audioURL == nil || type.hasPrefix("audio") {
                    item?.audioURL = url
                    item?.fileSize = attributes["length"].flatMap { Int64($0) }
                }
            case "itunes:image":
                guard let url = attributes["href"].flatMap(URL.init(string:)) else { break }
                if item != nil { item?.artworkURL = url } else { feed.artworkURL = url }
            case "itunes:category":
                if item == nil, let name = attributes["text"], !feed.categories.contains(name) {
                    feed.categories.append(name)
                }
            case "podcast:transcript":
                guard item != nil, let url = attributes["url"].flatMap(URL.init(string:)) else { break }
                item?.transcripts.append(TranscriptLink(url: url, type: attributes["type"] ?? ""))
            case "podcast:chapters":
                guard item != nil else { break }
                item?.chaptersURL = attributes["url"].flatMap(URL.init(string:))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let name = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                if !path.isEmpty { path.removeLast() }
                text = ""
            }
            let parent = path.count >= 2 ? path[path.count - 2] : ""

            if name == "item" {
                finishItem()
                return
            }

            if item != nil {
                guard parent == "item" else { return }
                switch name {
                case "title", "itunes:title": if item?.title.isEmpty == true || name == "title" { item?.title = value }
                case "guid": item?.guid = value
                case "description", "content:encoded": if item?.description.isEmpty == true { item?.description = value }
                case "itunes:summary": item?.itunesSummary = value
                case "pubdate": item?.pubDate = RSSParser.parseDate(value)
                case "itunes:duration": item?.duration = RSSParser.parseDuration(value)
                default: break
                }
            } else if parent == "channel" {
                switch name {
                case "title": feed.title = value
                case "itunes:author": feed.author = value
                case "description": feed.summary = value
                case "itunes:summary": if feed.summary.isEmpty { feed.summary = value }
                default: break
                }
            } else if parent == "image", name == "url", feed.artworkURL == nil, path.contains("channel") {
                feed.artworkURL = URL(string: value)
            }
        }

        private func finishItem() {
            defer { item = nil }
            guard let item, let audioURL = item.audioURL else { return }
            var episode = ParsedEpisode(audioURL: audioURL)
            episode.guid = item.guid.isEmpty ? audioURL.absoluteString : item.guid
            episode.title = item.title
            episode.summary = RSSParser.stripHTML(item.description.isEmpty ? item.itunesSummary : item.description)
            episode.pubDate = item.pubDate
            episode.duration = item.duration
            episode.fileSize = item.fileSize
            episode.artworkURL = item.artworkURL
            episode.transcripts = item.transcripts
            episode.chaptersURL = item.chaptersURL
            feed.episodes.append(episode)
        }
    }

    /// Crude tag stripper for show notes; good enough for a plain-text summary.
    public static func plainText(_ html: String) -> String { stripHTML(html) }

    static func stripHTML(_ html: String) -> String {
        var result = html
            .replacingOccurrences(of: "<br\\s*/?>|</p>|</li>|</h\\d>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
