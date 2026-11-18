// Developer tool: runs the episode analyser over a word-timestamp transcript
// and prints what it would skip, with the surrounding text, so detections can
// be checked against a real episode.
//
//   swift run adscan transcript.json [--feed feed.xml --item N] [--ref other.json ...] [--cues] [--no-transcript]
//
// Transcript: {"words":[{"start":0.0,"end":0.4,"text":"hello"}, ...]}
import Foundation
import PodcastCore

struct Input: Decodable {
    struct Word: Decodable {
        let start: Double
        let end: Double
        let text: String
    }
    let title: String?
    let duration: Double?
    let words: [Word]

    var segments: [TranscriptSegment] {
        words.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) }
    }
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

func load(_ path: String) throws -> Input {
    try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}
func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

let feedPath = option("--feed")
let itemIndex = Int(option("--item") ?? "0") ?? 0
var references: [String] = []
while let reference = option("--ref") { references.append(reference) }
let showCues = flag("--cues")
let noTranscript = flag("--no-transcript")
guard let path = arguments.first else {
    print("usage: adscan transcript.json [--feed feed.xml --item N] [--ref other.json ...] [--cues] [--no-transcript]")
    exit(2)
}

let input = try load(path)
var evidence = EpisodeEvidence()
evidence.transcript = noTranscript ? [] : input.segments
evidence.duration = input.duration
if let feedPath {
    let feed = try RSSParser.parse(Data(contentsOf: URL(fileURLWithPath: feedPath)))
    evidence.showNotes = feed.episodes[itemIndex].summary
    print("show notes index: \(ShowNotes.chapters(from: evidence.showNotes).count) entries")
}
for reference in references {
    evidence.reference.formUnion(RepetitionDetector.fingerprint(of: try load(reference).segments))
}

func text(from start: Double, to end: Double) -> String {
    input.words.filter { $0.start >= start && $0.start < end }.map(\.text).joined(separator: " ")
}

print("== \(input.title ?? path) (\(clock(input.duration ?? 0)))")
if showCues {
    for line in AdDetector().debugCues(input.segments) { print(line) }
}

let analysis = EpisodeAnalyzer().analyze(evidence)
for ad in analysis.segments {
    print("\n\(ad.kind == .ad ? "AD" : "BOILERPLATE") \(clock(ad.start)) – \(clock(ad.end))  [\(String(format: "%.1f", ad.start))–\(String(format: "%.1f", ad.end))] (\(Int(ad.duration))s, confidence \(String(format: "%.2f", ad.confidence)))  [\(ad.reason)]")
    print("  before: …\(text(from: ad.start - 12, to: ad.start).suffix(140))")
    print("  starts: \(text(from: ad.start, to: ad.start + 12).prefix(140))…")
    print("  ends:   …\(text(from: ad.end - 12, to: ad.end + 0.01).suffix(140))")
    print("  after:  \(text(from: ad.end + 0.01, to: ad.end + 12).prefix(140))…")
}
if let start = analysis.contentStart {
    print("\nCONTENT STARTS \(clock(start)): \(text(from: start, to: start + 10).prefix(120))…")
}
let ads = analysis.segments.filter { $0.kind == .ad }
print("\n\(ads.count) ad segment(s), \(Int(ads.reduce(0) { $0 + $1.duration }))s total")
