import Foundation

/// Scores how much a typed string looks like English.
///
/// Three sources of evidence:
///  - a list of common words (strong evidence, includes modern words like "ok", "email"),
///  - a large dictionary (e.g. /usr/share/dict/words, weaker evidence),
///  - a letter-bigram model trained on those words, for words not in either list.
public final class EnglishModel {
    private var common = Set<String>()
    private var dictionary = Set<String>()
    private var sortedWords: [String] = []
    private var sortedCommon: [String] = []
    private var bigram: [String: Double] = [:]   // "ab" -> log2 P(b|a); "^a", "a$" for boundaries
    private var unseenBigram = -12.0

    public init(commonWords: [String], dictionaryWords: [String] = []) {
        common = Set(commonWords.map { $0.lowercased() }.filter { !$0.isEmpty })
        dictionary = Set(dictionaryWords.map { $0.lowercased() }.filter { $0.count > 2 })
        sortedCommon = common.sorted()
        sortedWords = common.union(dictionary).sorted()
        trainBigram()
    }

    /// Loads common words from a bundle resource file and the system dictionary if present.
    public convenience init(commonWordsURL: URL?, systemDictionary: URL? = URL(fileURLWithPath: "/usr/share/dict/words")) {
        func lines(_ url: URL?) -> [String] {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
        }
        self.init(commonWords: lines(commonWordsURL), dictionaryWords: lines(systemDictionary))
    }

    public func isCommon(_ w: String) -> Bool { common.contains(w.lowercased()) }
    public func isWord(_ w: String) -> Bool { let l = w.lowercased(); return common.contains(l) || dictionary.contains(l) }

    /// - Parameter complete: true when the user ended the word (space / punctuation),
    ///   false while still typing (prefixes of words get partial credit).
    public func score(_ word: String, complete: Bool) -> Double {
        let w = word.lowercased()
        let n = Double(w.count)
        guard !w.isEmpty else { return 0 }
        if common.contains(w) { return 3 + n }
        if dictionary.contains(w) { return 1 + 0.6 * n }
        if !complete {
            if hasPrefix(w, in: sortedCommon) { return 0.4 * n }
            if hasPrefix(w, in: sortedWords) { return 0.2 * n }
        }
        // Unknown word: judge by how English-like its letter sequence is.
        let plaus = plausibility(w)
        return min(0.5 * n, max(-2 * n, n * (plaus + 4.2)))
    }

    /// Feature dict for the classifier (see Features.swift); `score` is their dot
    /// product with the default weights.
    public func wordFeatures(_ word: String, complete: Bool) -> FeatureVector {
        let w = word.lowercased()
        let n = Double(w.count)
        var f: FeatureVector = [:]
        if n <= 2 { f["lit.short"] = 1 }
        if common.contains(w) {
            f["lit.common"] = 1
            f["lit.common_len"] = n
        } else if dictionary.contains(w) {
            f["lit.dict"] = 1
            f["lit.dict_len"] = n
        } else if !complete && hasPrefix(w, in: sortedCommon) {
            f["lit.prefix_common_len"] = n
        } else if !complete && hasPrefix(w, in: sortedWords) {
            f["lit.prefix_dict_len"] = n
        } else {
            let plaus = plausibility(w)
            f["lit.unknown_score"] = min(0.5 * n, max(-2 * n, n * (plaus + 4.2)))
        }
        return f
    }

    /// Mean log2 probability per letter transition (≈ -3.5 for English, lower for gibberish).
    public func plausibility(_ w: String) -> Double {
        let chars = ["^"] + w.map(String.init) + ["$"]
        var total = 0.0
        for i in 1..<chars.count { total += bigram[chars[i - 1] + chars[i]] ?? unseenBigram }
        return total / Double(chars.count - 1)
    }

    private func hasPrefix(_ p: String, in words: [String]) -> Bool {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < p { lo = mid + 1 } else { hi = mid }
        }
        // words[lo] is the first word >= p; skip an exact match, then test the next one.
        if lo < words.count && words[lo] == p { lo += 1 }
        return lo < words.count && words[lo].hasPrefix(p)
    }

    private func trainBigram() {
        var pair: [String: Double] = [:]
        var first: [String: Double] = [:]
        for w in sortedWords where w.allSatisfy({ $0.isLetter && $0.isASCII }) {
            let weight = common.contains(w) ? 5.0 : 1.0
            let chars = ["^"] + w.map(String.init) + ["$"]
            for i in 1..<chars.count {
                pair[chars[i - 1] + chars[i], default: 0] += weight
                first[chars[i - 1], default: 0] += weight
            }
        }
        // Add-one smoothing over 27 possible successors.
        for (k, c) in pair {
            let a = String(k.prefix(1))
            bigram[k] = log2((c + 1) / ((first[a] ?? 0) + 27))
        }
        unseenBigram = log2(1.0 / ((first.values.max() ?? 1000) + 27))
    }
}
