import Foundation

public struct ConvertedSegment: Equatable {
    public var range: Range<Int>   // syllable indices
    public var text: String
}

public struct Candidate: Equatable {
    public var range: Range<Int>
    public var text: String
}

/// Turns a syllable sequence into the most likely Chinese text (Viterbi over the lexicon).
public struct Converter {
    public let lexicon: Lexicon
    /// Picked candidates come first.
    public let history: UserHistory?
    /// Score used when a syllable has no lexicon entry; the Bopomofo itself is emitted.
    static let unknownScore = -30.0
    /// Penalty for matching an untoned syllable against all tones.
    static let tonelessPenalty = -1.5
    /// Syllables typed without a tone stay as Bopomofo (no characters, no candidates) until
    /// the tone is typed.
    public var requireTones = false

    public init(lexicon: Lexicon, history: UserHistory? = nil) {
        self.lexicon = lexicon
        self.history = history
    }

    private func entries(_ syllables: [Syllable]) -> [LexiconEntry] {
        if requireTones && syllables.contains(where: { $0.tone == nil }) { return [] }
        let e = lexicon.entries(for: syllables)
        return history?.adjust(syllables, e) ?? e
    }

    /// - Parameter fixed: user-chosen phrases by syllable range; they are always kept.
    public func convert(_ syllables: [Syllable], fixed: [Range<Int>: String] = [:]) -> [ConvertedSegment] {
        let n = syllables.count
        guard n > 0 else { return [] }
        let maxLen = max(1, lexicon.maxPhraseLength)

        // best[j] = (score, backpointer segment) for the prefix ending at j.
        var best: [(score: Double, seg: ConvertedSegment?)] = Array(repeating: (-.infinity, nil), count: n + 1)
        best[0] = (0, nil)

        for j in 1...n {
            for len in 1...min(maxLen, j) {
                let i = j - len
                guard best[i].score > -.infinity else { continue }
                let range = i..<j
                for (text, score) in options(for: range, syllables: syllables, fixed: fixed) {
                    let total = best[i].score + score
                    if total > best[j].score { best[j] = (total, ConvertedSegment(range: range, text: text)) }
                }
            }
        }

        var segments: [ConvertedSegment] = []
        var j = n
        while j > 0, let seg = best[j].seg {
            segments.append(seg)
            j = seg.range.lowerBound
        }
        return segments.reversed()
    }

    /// The `k` best paths (log10 score, segments), best first — for language-model reranking.
    public func kBest(_ syllables: [Syllable], fixed: [Range<Int>: String] = [:], k: Int) -> [(score: Double, segments: [ConvertedSegment])] {
        let n = syllables.count
        guard n > 0, k > 0 else { return [] }
        let maxLen = max(1, lexicon.maxPhraseLength)
        typealias Path = (score: Double, segments: [ConvertedSegment])
        var beams: [[Path]] = Array(repeating: [], count: n + 1)
        beams[0] = [(0, [])]
        for j in 1...n {
            var cand: [Path] = []
            for len in 1...min(maxLen, j) {
                let i = j - len
                guard !beams[i].isEmpty else { continue }
                let range = i..<j
                for (text, score) in options(for: range, syllables: syllables, fixed: fixed) {
                    for path in beams[i] {
                        cand.append((path.score + score, path.segments + [ConvertedSegment(range: range, text: text)]))
                    }
                }
            }
            cand.sort { $0.score > $1.score }
            beams[j] = Array(cand.prefix(k))
        }
        return beams[n]
    }

    private func options(for range: Range<Int>, syllables: [Syllable], fixed: [Range<Int>: String]) -> [(String, Double)] {
        if let text = fixed[range] { return [(text, 0)] }
        // A span may not partially overlap or swallow a fixed span.
        if fixed.keys.contains(where: { $0.overlaps(range) }) { return [] }

        let slice = Array(syllables[range])
        var result = entries(slice).map { entry -> (String, Double) in
            let penalty = slice.contains { $0.tone == nil } ? Converter.tonelessPenalty : 0
            return (entry.phrase, entry.score + penalty)
        }
        if result.isEmpty && range.count == 1 {
            result = [(slice[0].reading, Converter.unknownScore)]
        }
        return result
    }

    /// Candidates for phrases ending at syllable index `end - 1`, longest phrases first.
    public func candidates(_ syllables: [Syllable], endingAt end: Int) -> [Candidate] {
        guard end > 0, end <= syllables.count else { return [] }
        var out: [Candidate] = []
        var seen = Set<String>()
        for len in stride(from: min(lexicon.maxPhraseLength, end), through: 1, by: -1) {
            let range = (end - len)..<end
            for entry in entries(Array(syllables[range])) where !seen.contains(entry.phrase) {
                seen.insert(entry.phrase)
                out.append(Candidate(range: range, text: entry.phrase))
            }
        }
        // Last, the Bopomofo itself, for writing about it ("ㄤ", "ㄤˊ").
        let syl = syllables[end - 1]
        for text in [syl.toneless, syl.reading] where !text.isEmpty && !seen.contains(text) {
            seen.insert(text)
            out.append(Candidate(range: (end - 1)..<end, text: text))
        }
        return out
    }
}
