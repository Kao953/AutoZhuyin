import Foundation

public enum InputMode: String, Codable {
    /// Keys are Dachen Zhuyin and get converted to Chinese.
    case zhuyin
    /// Keys are output as typed (English words, numbers).
    case literal
}

/// A run of keys (indices into the buffer) interpreted in one mode.
public struct Segment: Equatable {
    public var range: Range<Int>
    public var mode: InputMode

    public init(range: Range<Int>, mode: InputMode) {
        self.range = range
        self.mode = mode
    }
}

public struct Classification {
    public var mode: InputMode
    public var zhuyinScore: Double
    public var literalScore: Double
}

/// Remembers the user's corrections (Tab toggles) per key sequence.
public final class LearnedPreferences {
    /// Positive = prefers Zhuyin, negative = prefers literal.
    public private(set) var weights: [String: Int]
    private let onChange: ([String: Int]) -> Void

    public init(weights: [String: Int] = [:], onChange: @escaping ([String: Int]) -> Void = { _ in }) {
        self.weights = weights
        self.onChange = onChange
    }

    public func record(_ keys: String, as mode: InputMode) {
        let delta = mode == .zhuyin ? 1 : -1
        weights[keys] = max(-3, min(3, (weights[keys] ?? 0) + delta))
        onChange(weights)
    }

    public func clear() {
        weights = [:]
        onChange(weights)
    }

    public func bias(for keys: String) -> Double { Double(weights[keys] ?? 0) * 4 }
}

/// Decides whether a key sequence is Zhuyin or literal (English / numbers).
public final class Classifier {
    public let lexicon: Lexicon
    public let english: EnglishModel
    public let learned: LearnedPreferences

    /// Traditional-Chinese users type Zhuyin most of the time: a small prior toward it.
    public var zhuyinPrior = 0.5
    /// How much the previous segment's mode pulls the current one.
    public var contextWeight = 1.5

    public init(lexicon: Lexicon, english: EnglishModel, learned: LearnedPreferences = LearnedPreferences()) {
        self.lexicon = lexicon
        self.english = english
        self.learned = learned
    }

    /// - Parameters:
    ///   - finishing: the user pressed space. Zhuyin is scored as if the space were a
    ///     first-tone key; literal is scored as a completed word.
    ///   - previous: mode of the previously committed segment, if recent.
    public func classify(_ keys: [Character], finishing: Bool = false, previous: InputMode? = nil) -> Classification {
        var zh = zhuyinScore(finishing ? keys + [" "] : keys) + zhuyinPrior
        var lit = literalScore(keys, complete: finishing)
        switch previous {
        case .zhuyin?: zh += contextWeight
        case .literal?: lit += contextWeight
        case nil: break
        }
        let learnedBias = learned.bias(for: String(keys))
        if learnedBias > 0 { zh += learnedBias } else { lit -= learnedBias }
        return Classification(mode: zh >= lit ? .zhuyin : .literal, zhuyinScore: zh, literalScore: lit)
    }

    // MARK: - Segmentation

    /// Cost of each switch between Zhuyin and literal inside one buffer, so that a normal
    /// word or sentence is not chopped up.
    public var segmentPenalty = 3.0

    /// Splits a buffer into alternating Zhuyin / literal segments, e.g. "ji3hello" →
    /// [ji3: zhuyin, hello: literal]. Dynamic programming over every split point.
    /// A Zhuyin segment followed by another segment must end with a tone key.
    public func segment(_ keys: [Character], finishing: Bool = false, previous: InputMode? = nil) -> [Segment] {
        let n = keys.count
        guard n > 0 else { return [] }
        let modes: [InputMode] = [.zhuyin, .literal]
        // best[i][m]: best score for keys[0..<i] whose last segment has mode m.
        var best = Array(repeating: [Double](repeating: -.infinity, count: 2), count: n + 1)
        var back = Array(repeating: [Int](repeating: -1, count: 2), count: n + 1)   // segment start j

        for i in 1...n {
            for j in 0..<i {
                let scores = segmentScores(Array(keys[j..<i]), isLast: i == n, afterOther: j > 0,
                                           finishing: finishing, previous: j == 0 ? previous : nil,
                                           whole: j == 0 && i == n)
                for m in 0..<2 where scores[m] > -.infinity {
                    // Adjacent segments must alternate modes; same-mode neighbours are one segment.
                    let total = j == 0 ? scores[m] : best[j][1 - m] + scores[m] - segmentPenalty
                    if total > best[i][m] {
                        best[i][m] = total
                        back[i][m] = j
                    }
                }
            }
        }

        guard best[n][0] > -.infinity || best[n][1] > -.infinity else {
            return [Segment(range: 0..<n, mode: classify(keys, finishing: finishing, previous: previous).mode)]
        }
        var m = best[n][0] >= best[n][1] ? 0 : 1
        var i = n
        var out: [Segment] = []
        while i > 0 {
            let j = back[i][m]
            out.append(Segment(range: j..<i, mode: modes[m]))
            i = j
            m = 1 - m
        }
        return out.reversed()
    }

    /// Extra cost for a trailing Zhuyin segment after English that has no tone key yet
    /// ("ji3hel" should stay 我hel, not become 我heㄠ, until a tone confirms the switch).
    public var unconfirmedSwitchPenalty = 2.0

    private func segmentScores(_ seg: [Character], isLast: Bool, afterOther: Bool, finishing: Bool,
                               previous: InputMode?, whole: Bool) -> [Double] {
        var zh: Double
        let parse = ZhuyinParser.parse(seg)
        if !isLast && parse.pending != nil {
            zh = -.infinity
        } else {
            zh = zhuyinScore(finishing && isLast ? seg + [" "] : seg) + zhuyinPrior
            if isLast && afterOther && !finishing && !parse.syllables.contains(where: \.toned) {
                zh -= unconfirmedSwitchPenalty
            }
        }
        var lit = literalScore(seg, complete: !isLast || finishing)
        switch previous {
        case .zhuyin?: zh += contextWeight
        case .literal?: lit += contextWeight
        case nil: break
        }
        if whole {
            let b = learned.bias(for: String(seg))
            if b > 0 { zh += b } else { lit -= b }
        }
        return [zh, lit]
    }

    public func zhuyinScore(_ keys: [Character]) -> Double {
        let parse = ZhuyinParser.parse(keys)
        if parse.foreignKeys > 0 || parse.syllables.isEmpty { return -.infinity }
        var s = -5.0 * Double(parse.strayTones)
        for (i, p) in parse.syllables.enumerated() {
            let isLast = i == parse.syllables.count - 1
            // Out-of-order typing is accepted, but is weaker evidence than normal Zhuyin.
            if p.reordered { s -= 0.5 }
            let valid = SyllableTable.isValid(p.syllable)
            if p.toned {
                if valid {
                    s += 2 + (lexicon.bestScore(for: p.syllable) != nil ? 0.8 : -1.5)
                } else {
                    s -= 5
                }
            } else if isLast {
                s += SyllableTable.isValidPrefix(p.syllable) ? 0 : -5
            } else {
                // Untoned syllable in the middle: allowed (tone omission) but unusual.
                s += valid ? -2.5 : -5
            }
        }
        return s
    }

    public func literalScore(_ keys: [Character], complete: Bool) -> Double {
        if keys.isEmpty || keys.contains(" ") { return -.infinity }
        var score = 0.0
        if keys.contains(where: { $0.isUppercase }) { score += 20 }   // Shift = clearly English

        let letters = String(keys.filter { $0.isLetter })
        let digits = keys.filter { $0.isNumber }.count
        let others = keys.count - letters.count - digits

        if letters.isEmpty {
            // Pure number like "2024" (with possible "." or ",").
            return score + 0.8 * Double(digits) - 1.0 * Double(others)
        }
        score += english.score(letters, complete: complete || digits > 0)
        score -= 1.5 * Double(digits)
        // `'` inside a word (don't) is fine; Zhuyin punctuation keys inside a word are not.
        let apostrophes = keys.filter { $0 == "'" }.count
        score -= 1.5 * Double(others - apostrophes)
        return score
    }
}
