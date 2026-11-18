import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// OPML is the format podcast apps use to exchange subscription lists.
public enum OPML {
    public struct Entry: Equatable, Sendable {
        public var title: String
        public var feedURL: URL

        public init(title: String, feedURL: URL) {
            self.title = title
            self.feedURL = feedURL
        }
    }

    /// Feeds listed in an OPML document, in order, without duplicates.
    /// Outlines may be nested in folders; anything without a feed URL is skipped.
    public static func parse(_ data: Data) -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    public static func generate(_ entries: [Entry], title: String = "Podcast subscriptions") -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head><title>\(escape(title))</title></head>",
            "  <body>",
        ]
        for entry in entries {
            lines.append(#"    <outline type="rss" text="\#(escape(entry.title))" title="\#(escape(entry.title))" xmlUrl="\#(escape(entry.feedURL.absoluteString))"/>"#)
        }
        lines += ["  </body>", "</opml>", ""]
        return lines.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var seen = Set<String>()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name.lowercased() == "outline" else { return }
            // Attribute names vary in case between exporters.
            var lowered: [String: String] = [:]
            for (key, value) in attributes { lowered[key.lowercased()] = value }
            guard let raw = lowered["xmlurl"]?.trimmingCharacters(in: .whitespaces), let url = URL(string: raw),
                  url.scheme?.hasPrefix("http") == true, seen.insert(PodcastDiscovery.normalize(url)).inserted else { return }
            entries.append(Entry(title: lowered["title"] ?? lowered["text"] ?? url.host ?? raw, feedURL: url))
        }
    }
}
