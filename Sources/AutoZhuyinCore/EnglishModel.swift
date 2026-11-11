import Foundation

/// Scores how much a typed string looks like English.
///
/// Three sources of evidence:
///  - a list of common words (strong evidence, includes modern words like "ok", "email"),
///  - a large dictionary (e.g. /usr/share/dict/words, weaker evidence),
///  - a letter-bigram model trained on those words, for words not in either list.
public final class EnglishModel {
    private var common = Set<String>()
    private var sortedCommon: [String] = []
    /// Dictionary words (lowercase, > 2 letters), sorted: membership and prefix checks are
    /// binary searches, so no 230k-entry Set has to be built at startup.
    private var sortedDict: [String] = []
    private var bigram: [String: Double] = [:]   // "ab" -> log2 P(b|a); "^a", "a$" for boundaries
    private var unseenBigram = -12.0

    /// - Parameter bigram: precomputed table (english-bigram.json); trained from the words if nil.
    public init(commonWords: [String], dictionaryWords: [String] = [],
                bigram: (table: [String: Double], unseen: Double)? = nil) {
        common = Set(commonWords.map { $0.lowercased() }.filter { !$0.isEmpty })
        sortedCommon = common.sorted()
        var dict = dictionaryWords.map { $0.lowercased() }.filter { $0.count > 2 }
        if !zip(dict, dict.dropFirst()).allSatisfy({ $0 < $1 }) {
            dict = Array(Set(dict)).sorted()
        }
        sortedDict = dict
        if let bigram {
            self.bigram = bigram.table
            unseenBigram = bigram.unseen
        } else {
            trainBigram()
        }
    }

    /// Loads the bundled data files. Falls back to the system word list and to training
    /// the bigram table when the precomputed files are missing.
    public convenience init(commonWordsURL: URL?, dictionaryURL: URL? = nil, bigramURL: URL? = nil) {
        func lines(_ url: URL?) -> [String] {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        var bigram: (table: [String: Double], unseen: Double)?
        if let url = bigramURL, let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let table = obj["table"] as? [String: Double], let unseen = obj["unseen"] as? Double {
            bigram = (table, unseen)
        }
        let dictURL = dictionaryURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? URL(fileURLWithPath: "/usr/share/dict/words")
        self.init(commonWords: lines(commonWordsURL), dictionaryWords: lines(dictURL), bigram: bigram)
    }

    public func isCommon(_ w: String) -> Bool { common.contains(w.lowercased()) }
    public func isWord(_ w: String) -> Bool { let l = w.lowercased(); return common.contains(l) || inDictionary(l) }

    private func inDictionary(_ w: String) -> Bool {
        let i = lowerBound(w, in: sortedDict)
        return i < sortedDict.count && sortedDict[i] == w
    }

    /// Some word strictly longer than `p` starts with it (common words or dictionary).
    private func isPrefixOfWord(_ p: String) -> Bool {
        hasPrefix(p, in: sortedCommon) || hasPrefix(p, in: sortedDict)
    }

    /// - Parameter complete: true when the user ended the word (space / punctuation),
    ///   false while still typing (prefixes of words get partial credit).
    public func score(_ word: String, complete: Bool) -> Double {
        let w = word.lowercased()
        let n = Double(w.count)
        guard !w.isEmpty else { return 0 }
        if common.contains(w) { return 3 + n }
        if inDictionary(w) { return 1 + 0.6 * n }
        if !complete {
            if hasPrefix(w, in: sortedCommon) { return 0.4 * n }
            if isPrefixOfWord(w) { return 0.2 * n }
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
        } else if inDictionary(w) {
            f["lit.dict"] = 1
            f["lit.dict_len"] = n
        } else if !complete && hasPrefix(w, in: sortedCommon) {
            f["lit.prefix_common_len"] = n
        } else if !complete && isPrefixOfWord(w) {
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

    private func lowerBound(_ p: String, in words: [String]) -> Int {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < p { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func hasPrefix(_ p: String, in words: [String]) -> Bool {
        var lo = lowerBound(p, in: words)
        // words[lo] is the first word >= p; skip an exact match, then test the next one.
        if lo < words.count && words[lo] == p { lo += 1 }
        return lo < words.count && words[lo].hasPrefix(p)
    }

    private func trainBigram() {
        var pair: [String: Double] = [:]
        var first: [String: Double] = [:]
        for w in Set(sortedCommon + sortedDict).sorted() where w.allSatisfy({ $0.isLetter && $0.isASCII }) {
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
