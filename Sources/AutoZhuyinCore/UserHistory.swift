import Foundation

/// Remembers the candidates the user picked, so they come first next time.
///
/// Keys are toneless readings ("ㄊㄧㄢ", "ㄐㄧㄣ-ㄊㄧㄢ"); a picked phrase is boosted only
/// where the lexicon has it for the reading being converted, so a toneless key is safe.
/// Stored as JSON: {reading: {phrase: [count, last use]}} (same format on every platform).
public final class UserHistory {
    public typealias Data = [String: [String: [Int]]]

    /// (reading, phrase) pairs kept; the least recently used go first.
    public var maxEntries = 2000
    static let maxCount = 10

    public private(set) var data: Data = [:]
    private var clock = 0
    private let onChange: (Data) -> Void

    public init(data: Data = [:], onChange: @escaping (Data) -> Void = { _ in }) {
        self.onChange = onChange
        for (reading, phrases) in data {
            for (phrase, value) in phrases where value.count >= 2 {
                self.data[reading, default: [:]][phrase] = [value[0], value[1]]
                clock = max(clock, value[1])
            }
        }
    }

    /// Loads the JSON file written through `onChange`; empty if missing or unreadable.
    public static func load(from url: URL) -> Data {
        guard let raw = try? Foundation.Data(contentsOf: url),
              let data = try? JSONDecoder().decode(Data.self, from: raw) else { return [:] }
        return data
    }

    static func key(_ syllables: [Syllable]) -> String {
        syllables.map(\.toneless).joined(separator: "-")
    }

    public func record(_ syllables: [Syllable], phrase: String) {
        guard !syllables.isEmpty, !phrase.isEmpty else { return }
        clock += 1
        let key = UserHistory.key(syllables)
        let count = data[key]?[phrase]?.first ?? 0
        data[key, default: [:]][phrase] = [min(UserHistory.maxCount, count + 1), clock]
        evict()
        onChange(data)
    }

    private func evict() {
        var pairs: [(used: Int, reading: String, phrase: String)] = []
        for (r, phrases) in data { for (p, v) in phrases { pairs.append((v[1], r, p)) } }
        guard pairs.count > maxEntries else { return }
        pairs.sort { $0.used < $1.used }
        for pair in pairs.prefix(pairs.count - maxEntries) {
            data[pair.reading]?[pair.phrase] = nil
            if data[pair.reading]?.isEmpty == true { data[pair.reading] = nil }
        }
    }

    public func clear() {
        data = [:]
        onChange(data)
    }

    /// Lexicon entries with picked phrases moved to the top: just above the best entry,
    /// more so the more often they were picked.
    func adjust(_ syllables: [Syllable], _ entries: [LexiconEntry]) -> [LexiconEntry] {
        guard let picked = data[UserHistory.key(syllables)], let top = entries.first?.score else { return entries }
        var out = entries.map { e -> LexiconEntry in
            guard let count = picked[e.phrase]?.first else { return e }
            return LexiconEntry(phrase: e.phrase, score: max(e.score, top + 0.01 + 0.1 * Double(count)))
        }
        // Stable sort (keep lexicon order among equal scores), like Python's sort.
        out = out.enumerated().sorted { $0.element.score != $1.element.score
            ? $0.element.score > $1.element.score : $0.offset < $1.offset }.map(\.element)
        return out
    }
}
