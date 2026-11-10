import Foundation

public enum InputMode: String, Codable {
    /// Keys are Dachen Zhuyin and get converted to Chinese.
    case zhuyin
    /// Keys are output as typed (English words, numbers).
    case literal
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
