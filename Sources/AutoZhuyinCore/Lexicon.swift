import Foundation

public struct LexiconEntry: Equatable {
    public var phrase: String
    /// log10 probability (higher is more likely), McBopomofo-style.
    public var score: Double
}

/// Maps Bopomofo readings (syllables joined by "-", e.g. "ㄋㄧˇ-ㄏㄠˇ") to phrases.
///
/// File format, one entry per line (`#` starts a comment):
///     ㄋㄧˇ-ㄏㄠˇ 你好 -4.2
/// The phrase/reading columns may be in either order; the score is optional.
public final class Lexicon {
    private var exact: [String: [LexiconEntry]] = [:]
    private var toneless: [String: [LexiconEntry]] = [:]
    public private(set) var maxPhraseLength = 1

    public init() {}

    public convenience init(contentsOf url: URL) throws {
        self.init()
        load(try String(contentsOf: url, encoding: .utf8))
    }

    public func load(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 2 else { continue }
            let (reading, phrase) = Lexicon.isBopomofo(cols[0]) ? (cols[0], cols[1]) : (cols[1], cols[0])
            guard Lexicon.isBopomofo(reading) else { continue }
            let score = cols.count >= 3 ? Double(cols[2]) ?? -6 : -6
            add(reading: reading, phrase: phrase, score: score)
        }
        for key in exact.keys { exact[key]?.sort { $0.score > $1.score } }
        for key in toneless.keys { toneless[key]?.sort { $0.score > $1.score } }
    }

    public func add(reading rawReading: String, phrase: String, score: Double) {
        let entry = LexiconEntry(phrase: phrase, score: score)
        // Some data sets write the neutral tone as a prefix ("˙ㄉㄜ"); we use a suffix.
        let syllables = rawReading.split(separator: "-").map { s -> String in
            s.hasPrefix("˙") ? String(s.dropFirst()) + "˙" : String(s)
        }
        let reading = syllables.joined(separator: "-")
        maxPhraseLength = max(maxPhraseLength, syllables.count)
        if !(exact[reading]?.contains { $0.phrase == phrase } ?? false) {
            exact[reading, default: []].append(entry)
        }
        let key = Lexicon.stripTones(reading)
        if let i = toneless[key]?.firstIndex(where: { $0.phrase == phrase }) {
            toneless[key]![i].score = max(toneless[key]![i].score, score)
        } else {
            toneless[key, default: []].append(entry)
        }
    }

    /// Entries for a sequence of readings. Untoned syllables match any tone.
    public func entries(for syllables: [Syllable]) -> [LexiconEntry] {
        if syllables.allSatisfy({ $0.tone != nil }) {
            return exact[syllables.map(\.reading).joined(separator: "-")] ?? []
        }
        return toneless[syllables.map(\.toneless).joined(separator: "-")] ?? []
    }

    public func bestScore(for syllable: Syllable) -> Double? {
        entries(for: [syllable]).first?.score
    }

    public var isEmpty: Bool { exact.isEmpty }

    static let toneMarks: Set<Character> = ["ˊ", "ˇ", "ˋ", "˙"]

    static func stripTones(_ reading: String) -> String {
        String(reading.filter { !toneMarks.contains($0) })
    }

    static func isBopomofo(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        return (0x3105...0x312F).contains(first.value) || first == "˙"
    }
}
