import Foundation

/// The user-phrases.txt file as the phrase editor sees it: entries in lexicon format
/// ("ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -1"), and every other line (comments, blank lines)
/// kept as it was when the file is written back.
public struct UserPhrases: Equatable {
    public struct Entry: Equatable {
        public var phrase: String
        public var reading: String
        /// nil: the line had no score (the lexicon then uses its default).
        public var score: Double?

        public init(phrase: String, reading: String, score: Double? = UserPhrases.defaultScore) {
            self.phrase = phrase
            self.reading = reading
            self.score = score
        }
    }

    enum Line: Equatable {
        case entry(Entry)
        case other(String)
    }

    /// Score for phrases added in the editor: high enough to beat the built-in phrases
    /// with the same reading (log10 probability; common words are around -3).
    public static let defaultScore = -1.0

    var lines: [Line]

    public init(text: String = "") {
        var lines = text.components(separatedBy: "\n").map { line -> Line in
            UserPhrases.parseEntry(line).map(Line.entry) ?? .other(line)
        }
        if lines.last == .other("") { lines.removeLast() }   // the final newline
        self.lines = lines
    }

    public var text: String {
        lines.map { line -> String in
            switch line {
            case .other(let s): return s
            case .entry(let e):
                let score = e.score.map { " " + UserPhrases.format($0) } ?? ""
                return "\(e.reading) \(e.phrase)\(score)"
            }
        }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    public var entries: [Entry] {
        lines.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }
    }

    public mutating func append(_ entry: Entry) {
        lines.append(.entry(entry))
    }

    /// Replaces the `index`-th entry (an index into `entries`).
    public mutating func replace(at index: Int, with entry: Entry) {
        guard let i = lineIndex(ofEntry: index) else { return }
        lines[i] = .entry(entry)
    }

    public mutating func remove(at index: Int) {
        guard let i = lineIndex(ofEntry: index) else { return }
        lines.remove(at: i)
    }

    private func lineIndex(ofEntry index: Int) -> Int? {
        var n = -1
        for (i, line) in lines.enumerated() {
            if case .entry = line { n += 1 }
            if n == index { return i }
        }
        return nil
    }

    private static func format(_ score: Double) -> String {
        score == score.rounded() ? String(Int(score)) : String(score)
    }

    /// One lexicon line: reading and phrase in either order, then an optional score.
    static func parseEntry(_ line: String) -> Entry? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard fields.count >= 2, !fields[0].hasPrefix("#") else { return nil }
        let (reading, phrase) = Lexicon.isBopomofo(fields[0]) ? (fields[0], fields[1]) : (fields[1], fields[0])
        guard Lexicon.isBopomofo(reading) else { return nil }
        let score = fields.count >= 3 ? Double(fields[2]) : nil
        if fields.count >= 3 && score == nil { return nil }
        return Entry(phrase: phrase, reading: reading, score: score)
    }

    // MARK: - Readings typed in the editor

    /// The lexicon reading for what was typed in the editor: Bopomofo ("ㄗˋ ㄉㄨㄥˋ",
    /// "ㄗˋㄉㄨㄥˋ", "ㄗˋ-ㄉㄨㄥˋ") or Dachen keys ("y42j/4"). A space or "-" ends a
    /// first-tone syllable. nil if it doesn't read as valid syllables.
    public static func reading(fromTyped typed: String) -> String? {
        var keys: [Character] = []
        for c in typed.trimmingCharacters(in: .whitespaces) {
            if c == "-" || c == " " || c == "　" {
                keys.append(" ")
            } else if let key = dachenKey[c] {
                keys.append(key)
            } else if c == "˙" {
                keys.append("7")
            } else {
                keys.append(Character(c.lowercased()))
            }
        }
        let p = ZhuyinParser.parse(keys)
        guard p.foreignKeys == 0, !p.syllables.isEmpty,
              p.syllables.allSatisfy({ SyllableTable.isValid($0.syllable) }) else { return nil }
        return p.syllables.map(\.syllable.reading).joined(separator: "-")
    }

    /// Bopomofo symbol or tone mark → its Dachen key.
    private static let dachenKey: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (key, symbol) in DachenLayout.symbols { map[symbol] = key }
        for (key, tone) in DachenLayout.tones where tone != .first {
            if let mark = tone.mark.first { map[mark] = key }
        }
        return map
    }()

    /// Why the entry can't be saved, or nil if it is fine.
    public static func problem(phrase: String, reading: String) -> String? {
        if phrase.isEmpty { return "請輸入詞" }
        if phrase.contains(where: \.isWhitespace) { return "詞裡不能有空白" }
        if reading.isEmpty { return "請輸入注音" }
        let syllables = reading.split(separator: "-").count
        if syllables != phrase.count { return "注音有 \(syllables) 個音節，詞有 \(phrase.count) 個字" }
        return nil
    }
}
