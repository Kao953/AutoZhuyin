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
/// Every segment is scored as features · weights (see Features.swift).
public final class Classifier {
    public let lexicon: Lexicon
    public let english: EnglishModel
    public let learned: LearnedPreferences
    /// Feature weights: the hand-tuned defaults overlaid with trained ones.
    public private(set) var weights: FeatureVector

    public init(lexicon: Lexicon, english: EnglishModel, learned: LearnedPreferences = LearnedPreferences(),
                weights: FeatureVector = [:]) {
        self.lexicon = lexicon
        self.english = english
        self.learned = learned
        self.weights = Features.defaultWeights.merging(weights) { _, new in new }
    }

    /// (Zhuyin features or nil, literal features or nil) for one segment. `previous` (mode of
    /// the text committed just before) only affects the first segment.
    public func segmentFeatures(_ seg: [Character], isLast: Bool, afterOther: Bool, finishing: Bool,
                                previous: InputMode? = nil) -> (FeatureVector?, FeatureVector?) {
        (Features.zhuyin(seg, lexicon: lexicon, isLast: isLast, afterOther: afterOther,
                         finishing: finishing, previous: previous),
         Features.literal(seg, english: english, isLast: isLast, afterOther: afterOther,
                          finishing: finishing, previous: previous))
    }

    private func scores(_ seg: [Character], isLast: Bool, afterOther: Bool, finishing: Bool,
                        previous: InputMode?, whole: Bool) -> [Double] {
        let (fz, fl) = segmentFeatures(seg, isLast: isLast, afterOther: afterOther,
                                       finishing: finishing, previous: previous)
        var zh = fz.map { Features.dot(weights, $0) } ?? -.infinity
        var lit = fl.map { Features.dot(weights, $0) } ?? -.infinity
        if whole {
            let b = learned.bias(for: String(seg))
            if b > 0 { zh += b } else { lit -= b }
        }
        return [zh, lit]
    }

    /// The whole buffer as one segment.
    /// - Parameters:
    ///   - finishing: the user pressed space. An unfinished Zhuyin syllable is scored as
    ///     first tone; literal is scored as a completed word.
    ///   - previous: mode of the previously committed segment, if recent.
    public func classify(_ keys: [Character], finishing: Bool = false, previous: InputMode? = nil) -> Classification {
        let s = scores(keys, isLast: true, afterOther: false, finishing: finishing, previous: previous, whole: true)
        return Classification(mode: s[0] >= s[1] ? .zhuyin : .literal, zhuyinScore: s[0], literalScore: s[1])
    }

    // MARK: - Segmentation

    /// Splits a buffer into alternating Zhuyin / literal segments, e.g. "ji3hello" →
    /// [ji3: zhuyin, hello: literal]. Dynamic programming over every split point; the
    /// cost of each switch is the "seg.switch" feature.
    public func segment(_ keys: [Character], finishing: Bool = false, previous: InputMode? = nil) -> [Segment] {
        let n = keys.count
        guard n > 0 else { return [] }
        let modes: [InputMode] = [.zhuyin, .literal]
        // best[i][m]: best score for keys[0..<i] whose last segment has mode m.
        var best = Array(repeating: [Double](repeating: -.infinity, count: 2), count: n + 1)
        var back = Array(repeating: [Int](repeating: -1, count: 2), count: n + 1)   // segment start j

        for i in 1...n {
            for j in 0..<i {
                let s = scores(Array(keys[j..<i]), isLast: i == n, afterOther: j > 0, finishing: finishing,
                               previous: j == 0 ? previous : nil, whole: j == 0 && i == n)
                for m in 0..<2 where s[m] > -.infinity {
                    // Adjacent segments must alternate modes; same-mode neighbours are one segment.
                    if j > 0 && best[j][1 - m] == -.infinity { continue }
                    let total = j == 0 ? s[m] : best[j][1 - m] + s[m]
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
}
