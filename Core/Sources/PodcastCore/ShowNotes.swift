import Foundation

/// Many shows publish a timestamped index in their episode notes:
///
///     (00:06:10) Sponsor: LMNT
///     [00:01:59] What I'm doing to help prevent Alzheimer's
///
/// This turns such notes into chapters, which tell us where sponsor reads
/// and the intro are without having to listen to the audio at all.
public enum ShowNotes {
    public static func chapters(from notes: String) -> [Chapter] {
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var chapters: [Chapter] = []
        for (index, line) in lines.enumerated() {
            guard let (time, rest) = leadingTimestamp(in: line) ?? trailingTimestamp(in: line) else { continue }
            var title = rest
            // Some notes put the timestamp (a link) on its own line above the title.
            if title.isEmpty, let next = lines[(index + 1)...].first(where: { !$0.isEmpty }), leadingTimestamp(in: next) == nil {
                title = next
            }
            chapters.append(Chapter(start: time, title: title))
        }
        // A real index has several entries in ascending order; anything else is
        // more likely a stray time of day in the prose.
        guard chapters.count >= 3, zip(chapters, chapters.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { return [] }
        return chapters
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^[\s\-–—•*]*[\(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?[\s\-–—:|]*(.*)$"#)

    private static let trailingPattern = try! NSRegularExpression(
        pattern: #"^(.{4,}?)\s*[\(\[]((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]][;,.]?(?:\s+and)?$"#)

    /// "Why lab testing is insufficient [2:15];"
    static func trailingTimestamp(in line: String) -> (TimeInterval, String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = trailingPattern.firstMatch(in: line, range: range),
              let titleRange = Range(match.range(at: 1), in: line),
              let timeRange = Range(match.range(at: 2), in: line),
              let time = RSSParser.parseDuration(String(line[timeRange])) else { return nil }
        return (time, String(line[titleRange]).trimmingCharacters(in: .whitespaces))
    }

    static func leadingTimestamp(in line: String) -> (TimeInterval, String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range),
              let timeRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line),
              let time = RSSParser.parseDuration(String(line[timeRange])) else { return nil }
        return (time, String(line[titleRange]).trimmingCharacters(in: .whitespaces))
    }
}
