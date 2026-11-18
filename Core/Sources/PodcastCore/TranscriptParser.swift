import Foundation

/// Parses publisher-supplied transcripts (Podcasting 2.0 `podcast:transcript`)
/// in WebVTT, SRT or JSON form. Formats without timestamps (plain text, HTML)
/// are useless for locating ads and return nil.
public enum TranscriptParser {
    public static func parse(_ data: Data, type: String) -> [TranscriptSegment]? {
        let type = type.lowercased()
        let segments: [TranscriptSegment]
        if type.contains("json") {
            segments = parseJSON(data)
        } else if type.contains("vtt") || type.contains("srt") || type.contains("subrip") {
            segments = parseCues(String(decoding: data, as: UTF8.self))
        } else {
            return nil
        }
        return segments.isEmpty ? nil : segments
    }

    /// Picks the transcript format we can make the most of.
    public static func bestLink(from links: [TranscriptLink]) -> TranscriptLink? {
        func rank(_ link: TranscriptLink) -> Int {
            let type = link.type.lowercased()
            if type.contains("vtt") { return 0 }
            if type.contains("srt") || type.contains("subrip") { return 1 }
            if type.contains("json") { return 2 }
            return 99
        }
        return links.filter { rank($0) < 99 }.min { rank($0) < rank($1) }
    }

    /// WebVTT and SRT share the `start --> end` cue line; only the decimal
    /// separator differs.
    static func parseCues(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: (start: TimeInterval, end: TimeInterval)?
        var lines: [String] = []

        func flush() {
            if let cue = current {
                let body = lines.joined(separator: " ")
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !body.isEmpty {
                    segments.append(TranscriptSegment(start: cue.start, end: cue.end, text: body))
                }
            }
            current = nil
            lines = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                flush()
                let parts = line.components(separatedBy: "-->")
                let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                if let start = parseTimestamp(parts[0]), let end = parseTimestamp(endToken) {
                    current = (start, end)
                }
            } else if line.isEmpty {
                flush()
            } else if current != nil {
                lines.append(line)
            }
        }
        flush()
        return segments
    }

    static func parseTimestamp(_ string: String) -> TimeInterval? {
        let cleaned = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func parseJSON(_ data: Data) -> [TranscriptSegment] {
        struct File: Decodable {
            struct Segment: Decodable {
                let startTime: Double
                let endTime: Double?
                let body: String
            }
            let segments: [Segment]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.segments.enumerated().map { index, segment in
            let fallbackEnd = index + 1 < file.segments.count ? file.segments[index + 1].startTime : segment.startTime + 2
            return TranscriptSegment(start: segment.startTime, end: segment.endTime ?? fallbackEnd, text: segment.body)
        }
    }

    /// Podcasting 2.0 JSON chapters file.
    public static func parseChapters(_ data: Data) -> [Chapter] {
        struct File: Decodable {
            struct Entry: Decodable {
                let startTime: Double
                let title: String?
            }
            let chapters: [Entry]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.chapters
            .map { Chapter(start: $0.startTime, title: $0.title ?? "") }
            .sorted { $0.start < $1.start }
    }
}
