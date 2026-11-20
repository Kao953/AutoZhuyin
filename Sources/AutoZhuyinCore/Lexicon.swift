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
///
/// Loading is on the input method's startup path, so the file is parsed as raw bytes,
/// and the tone-ignoring index (only needed for untoned syllables) is built lazily —
/// call `prepareTonelessIndex()` from a background queue to have it ready.
public final class Lexicon {
    private var exact: [String: [LexiconEntry]] = [:]
    /// User phrases (`setUserPhrases`), kept apart so they can be replaced while running.
    /// They override a built-in entry for the same phrase and reading.
    private var user: [String: [LexiconEntry]] = [:]
    private var tonelessIndex: [String: [LexiconEntry]]?
    private let lock = NSLock()
    public private(set) var maxPhraseLength = 1

    public init() {}

    public convenience init(contentsOf url: URL) throws {
        self.init()
        load(data: try Data(contentsOf: url))
    }

    public func load(_ text: String) {
        load(data: Data(text.utf8))
    }

    public func load(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        exact.reserveCapacity(exact.count + data.count / 30)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            while i < n {
                var end = i
                while end < n && bytes[end] != 0x0A { end += 1 }
                parseLine(bytes, i, end)
                i = end + 1
            }
        }
        for (key, entries) in exact where entries.count > 1 {
            exact[key] = entries.sorted { $0.score > $1.score }
        }
        tonelessIndex = nil   // rebuilt on demand
        readingIndex = nil
    }

    /// Splits one line into up to three space/tab separated fields.
    private func parseLine(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
        var fields: [Range<Int>] = []
        var i = start
        while i < end && fields.count < 3 {
            while i < end && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D) { i += 1 }
            if i >= end { break }
            if fields.isEmpty && b[i] == 0x23 { return }   // "#" comment
            let s = i
            while i < end && b[i] != 0x20 && b[i] != 0x09 && b[i] != 0x0D { i += 1 }
            fields.append(s..<i)
        }
        guard fields.count >= 2 else { return }
        func str(_ r: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: b[r]), as: UTF8.self) }
        let (r, p) = Lexicon.isBopomofo(b, fields[0]) ? (fields[0], fields[1]) : (fields[1], fields[0])
        guard Lexicon.isBopomofo(b, r) else { return }
        let score = fields.count >= 3 ? Lexicon.parseDouble(b, fields[2]) ?? -6 : -6
        // Neutral tone written as a prefix ("˙ㄉㄜ") needs normalising; detect it on bytes.
        var prefixNeutral = b[r.lowerBound] == 0xCB
        var k = r.lowerBound
        while !prefixNeutral && k + 2 < r.upperBound {
            if b[k] == 0x2D && b[k + 1] == 0xCB && b[k + 2] == 0x99 { prefixNeutral = true }
            k += 1
        }
        addEntry(reading: str(r), phrase: str(p), score: score, normalise: prefixNeutral)
    }

    /// Parses "-3.9151"-style decimals without creating a String.
    private static func parseDouble(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> Double? {
        var i = r.lowerBound
        var sign = 1.0
        if i < r.upperBound && (b[i] == 0x2D || b[i] == 0x2B) { sign = b[i] == 0x2D ? -1 : 1; i += 1 }
        var value = 0.0, scale = 1.0, digits = 0, fraction = false
        while i < r.upperBound {
            let c = b[i]
            if c >= 0x30 && c <= 0x39 {
                if fraction { scale /= 10; value += Double(c - 0x30) * scale } else { value = value * 10 + Double(c - 0x30) }
                digits += 1
            } else if c == 0x2E && !fraction {
                fraction = true
            } else {
                return Double(String(decoding: UnsafeBufferPointer(rebasing: b[r]), as: UTF8.self))
            }
            i += 1
        }
        return digits > 0 ? sign * value : nil
    }

    /// Adds one entry (call `load` for bulk data; this does not re-sort).
    public func add(reading: String, phrase: String, score: Double) {
        lock.lock()
        defer { lock.unlock() }
        let key = addEntry(reading: reading, phrase: phrase, score: score, normalise: reading.contains("˙"))
        exact[key]?.sort { $0.score > $1.score }
        tonelessIndex = nil
        readingIndex = nil
    }

    @discardableResult
    private func addEntry(reading rawReading: String, phrase: String, score: Double, normalise: Bool) -> String {
        var reading = rawReading
        // Some data sets write the neutral tone as a prefix ("˙ㄉㄜ"); we use a suffix.
        if normalise {
            reading = reading.split(separator: "-").map { s -> String in
                s.hasPrefix("˙") ? String(s.dropFirst()) + "˙" : String(s)
            }.joined(separator: "-")
        }
        maxPhraseLength = max(maxPhraseLength, reading.utf8.reduce(1) { $0 + ($1 == 0x2D ? 1 : 0) })
        if exact[reading] == nil {
            exact[reading] = [LexiconEntry(phrase: phrase, score: score)]
        } else if !exact[reading]!.contains(where: { $0.phrase == phrase }) {
            exact[reading]!.append(LexiconEntry(phrase: phrase, score: score))
        }
        return reading
    }

    /// Replaces the user phrases (user-phrases.txt, lexicon format).
    public func setUserPhrases(_ text: String) {
        let parsed = Lexicon()
        parsed.load(text)
        lock.lock()
        defer { lock.unlock() }
        user = parsed.exact
        maxPhraseLength = max(maxPhraseLength, parsed.maxPhraseLength)
        tonelessIndex = nil
        readingIndex = nil
    }

    /// User entries first-class: they replace a built-in entry with the same phrase.
    private func merged(_ key: String, _ builtIn: [LexiconEntry]?) -> [LexiconEntry]? {
        guard let mine = user[key] else { return builtIn }
        let phrases = Set(mine.map(\.phrase))
        return (mine + (builtIn ?? []).filter { !phrases.contains($0.phrase) }).sorted { $0.score > $1.score }
    }

    /// The most likely reading of a phrase: its own entry if the lexicon has one,
    /// otherwise the most common reading of each character. nil if a character has none.
    public func reading(of phrase: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if readingIndex == nil {
            var index: [String: (reading: String, score: Double)] = [:]
            for source in [exact, user] {
                for (reading, entries) in source {
                    for e in entries where index[e.phrase].map({ e.score > $0.score }) ?? true {
                        index[e.phrase] = (reading, e.score)
                    }
                }
            }
            readingIndex = index
        }
        if let whole = readingIndex?[phrase] { return whole.reading }
        var out: [String] = []
        for c in phrase {
            guard let r = readingIndex?[String(c)], !r.reading.contains("-") else { return nil }
            out.append(r.reading)
        }
        return out.isEmpty ? nil : out.joined(separator: "-")
    }
    private var readingIndex: [String: (reading: String, score: Double)]?

    /// Builds the index that ignores tones (for untoned syllables). Safe to call from a
    /// background queue; lookups build it themselves if it is not ready yet.
    public func prepareTonelessIndex() {
        lock.lock()
        defer { lock.unlock() }
        _ = buildTonelessIfNeeded()
    }

    private func buildTonelessIfNeeded() -> [String: [LexiconEntry]] {
        if let index = tonelessIndex { return index }
        var best: [String: [String: Double]] = [:]
        for (reading, entries) in [exact, user].joined() {
            let key = Lexicon.stripTones(reading)
            for e in entries {
                if let s = best[key]?[e.phrase], s >= e.score { continue }
                best[key, default: [:]][e.phrase] = e.score
            }
        }
        var index: [String: [LexiconEntry]] = [:]
        index.reserveCapacity(best.count)
        for (key, phrases) in best {
            index[key] = phrases.map { LexiconEntry(phrase: $0.key, score: $0.value) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.phrase < $1.phrase }
        }
        tonelessIndex = index
        return index
    }

    /// Entries for a sequence of readings. Untoned syllables match any tone.
    public func entries(for syllables: [Syllable]) -> [LexiconEntry] {
        lock.lock()
        defer { lock.unlock() }
        if syllables.allSatisfy({ $0.tone != nil }) {
            let key = syllables.map(\.reading).joined(separator: "-")
            return merged(key, exact[key]) ?? []
        }
        return buildTonelessIfNeeded()[syllables.map(\.toneless).joined(separator: "-")] ?? []
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

    /// Same test on raw UTF-8: Bopomofo U+3105–U+312F is E3 84 85…E3 84 AF; "˙" is CB 99.
    private static func isBopomofo(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> Bool {
        guard r.count >= 2 else { return false }
        if b[r.lowerBound] == 0xCB && b[r.lowerBound + 1] == 0x99 { return true }
        guard r.count >= 3, b[r.lowerBound] == 0xE3, b[r.lowerBound + 1] == 0x84 else { return false }
        let c = b[r.lowerBound + 2]
        return c >= 0x85 && c <= 0xAF
    }
}
