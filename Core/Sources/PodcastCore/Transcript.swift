import Foundation

/// A transcript flattened to one entry per spoken word, with a searchable
/// normalised text and a mapping from text positions back to time.
struct WordTrack {
    struct Word {
        var start: TimeInterval
        var end: TimeInterval
        /// Lowercased, punctuation-free form used for matching.
        var norm: String
        /// The word closes a sentence (per the transcript's punctuation).
        var endsSentence: Bool
        /// Character offset of `norm` in `text`.
        var offset: Int
    }

    private(set) var words: [Word] = []
    /// All `norm`s joined by single spaces.
    private(set) var text = ""
    private var utf16Offsets: [Int] = []

    init(_ segments: [TranscriptSegment]) {
        var pieces: [String] = []
        var cursor = 0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let raw = segment.text.split(whereSeparator: { $0 == " " || $0.isNewline })
            guard !raw.isEmpty else { continue }
            // Caption cues carry many words; spread them evenly across the cue.
            let step = (segment.end - segment.start) / Double(raw.count)
            for (index, token) in raw.enumerated() {
                let norm = Self.normalize(String(token))
                guard !norm.isEmpty else { continue }
                let start = segment.start + step * Double(index)
                let last = token.last!
                // "Dr." and friends end in a full stop without ending the sentence.
                let endsSentence = (last == "." && !Self.abbreviations.contains(norm)) || last == "?" || last == "!"
                words.append(Word(start: start, end: raw.count == 1 ? segment.end : start + step, norm: norm,
                                  endsSentence: endsSentence, offset: cursor))
                utf16Offsets.append(cursor)
                pieces.append(norm)
                cursor += norm.utf16.count + 1
            }
        }
        text = pieces.joined(separator: " ")
    }

    static let abbreviations: Set<String> = ["dr", "mr", "mrs", "ms", "st", "vs", "prof", "jr", "sr", "no", "mt"]

    /// Lowercases and keeps only what matters for matching: letters, digits,
    /// apostrophes and the `.` `/` of web addresses.
    static func normalize(_ token: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in token.lowercased().unicodeScalars {
            switch scalar {
            case "’": scalars.append("'")
            case "%": scalars.append(contentsOf: " percent".unicodeScalars)
            case "'", ".", "/": scalars.append(scalar)
            default:
                if scalar.isASCII ? (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
                    : CharacterSet.alphanumerics.contains(scalar) {
                    scalars.append(scalar)
                }
            }
        }
        var result = String(scalars)
        // Sentence punctuation sticks to the end of words; ".com" keeps its leading dot.
        while let last = result.last, last == "." || last == "/" || last == "'" { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Index of the word containing the given UTF-16 offset of `text`.
    func wordIndex(atUTF16 offset: Int) -> Int {
        var low = 0
        var high = utf16Offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if utf16Offsets[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// First word at or after `time`.
    func wordIndex(atTime time: TimeInterval) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].start < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Start of the sentence containing word `index`. Falls back to a pause
    /// in speech when the transcript has no punctuation.
    func sentenceStart(before index: Int, maxSeconds: TimeInterval = 15) -> Int {
        var i = index
        while i > 0 {
            let previous = words[i - 1]
            if previous.endsSentence || words[i].start - previous.end > 0.8 { break }
            if words[index].start - previous.start > maxSeconds { break }
            i -= 1
        }
        return i
    }

    /// Last word of the sentence containing word `index`.
    func sentenceEnd(after index: Int, maxSeconds: TimeInterval = 15) -> Int {
        var i = index
        while i < words.count - 1 {
            if words[i].endsSentence || words[i + 1].start - words[i].end > 0.8 { break }
            if words[i + 1].start - words[index].start > maxSeconds { break }
            i += 1
        }
        return i
    }
}
