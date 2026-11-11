import Foundation

/// Segment features for the Zhuyin / literal classifier. A segment's score in each mode
/// is the dot product of its features with the weights. `defaultWeights` reproduces the
/// original hand-tuned scores; learned weights come from Resources/classifier-weights.json
/// (training/train.py).
///
/// Python twin: windows/autozhuyin/core/features.py — both must produce identical
/// features (checked by ParityTests against training/parity-fixtures.json).
public typealias FeatureVector = [String: Double]

public enum Features {
    public static let defaultWeights: FeatureVector = [
        // Zhuyin
        "zh.bias": 0.5,
        "zh.stray": -5.0,
        "zh.reordered": -0.5,
        "zh.toned_valid_lex": 2.8,
        "zh.toned_valid_nolex": 0.5,
        "zh.toned_invalid": -5.0,
        "zh.pending_prefix": 0.0,
        "zh.pending_invalid": -5.0,
        "zh.untoned_mid_valid": -2.5,
        "zh.untoned_mid_invalid": -5.0,
        "zh.unconfirmed": -2.0,
        "zh.lexscore": 0.0,
        "zh.phrase": 0.0,
        // Literal
        "lit.bias": 0.0,
        "lit.upper": 20.0,
        "lit.num_digits": 0.8,
        "lit.num_others": -1.0,
        "lit.common": 3.0,
        "lit.common_len": 1.0,
        "lit.dict": 1.0,
        "lit.dict_len": 0.6,
        "lit.prefix_common_len": 0.4,
        "lit.prefix_dict_len": 0.2,
        "lit.unknown_score": 1.0,
        "lit.short": 0.0,
        "lit.digits": -1.5,
        "lit.others": -1.5,
        // Segmentation
        "seg.switch": -3.0,
        // Context: the first segment has the same mode as the previously committed text
        "ctx.zh": 1.5,
        "ctx.lit": 1.5,
    ]

    /// Reads {"weights": {...}} from a JSON file; empty if missing or invalid.
    public static func loadWeights(from url: URL?) -> FeatureVector {
        guard let url, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let w = obj["weights"] as? [String: Double] else { return [:] }
        return w
    }

    public static func dot(_ w: FeatureVector, _ f: FeatureVector) -> Double {
        f.reduce(0) { $0 + (w[$1.key] ?? 0) * $1.value }
    }

    /// Features of `keys` read as Zhuyin, or nil if impossible.
    public static func zhuyin(_ keys: [Character], lexicon: Lexicon, isLast: Bool = true,
                              afterOther: Bool = false, finishing: Bool = false,
                              previous: InputMode? = nil) -> FeatureVector? {
        let parse = ZhuyinParser.parse(keys)
        // A Zhuyin segment followed by another must end with a tone.
        if !isLast && parse.pending != nil { return nil }
        // Space finishes an untoned last syllable as first tone; after a toned syllable it
        // just commits, so it must not count as an extra (stray) tone.
        let scored = finishing && isLast && parse.pending != nil ? ZhuyinParser.parse(keys + [" "]) : parse
        if scored.foreignKeys > 0 || scored.syllables.isEmpty { return nil }

        var f: FeatureVector = ["zh.bias": 1]
        func add(_ k: String, _ v: Double = 1) { f[k, default: 0] += v }
        if scored.strayTones > 0 { add("zh.stray", Double(scored.strayTones)) }
        let last = scored.syllables.count - 1
        var tonedRun: [Syllable] = []
        for (i, p) in scored.syllables.enumerated() {
            if p.reordered { add("zh.reordered") }
            let valid = SyllableTable.isValid(p.syllable)
            if p.toned {
                if valid {
                    if let best = lexicon.bestScore(for: p.syllable) {
                        add("zh.toned_valid_lex")
                        add("zh.lexscore", best + 4)
                    } else {
                        add("zh.toned_valid_nolex")
                    }
                    tonedRun.append(p.syllable)
                } else {
                    add("zh.toned_invalid")
                }
            } else if i == last {
                add(SyllableTable.isValidPrefix(p.syllable) ? "zh.pending_prefix" : "zh.pending_invalid")
            } else {
                add(valid ? "zh.untoned_mid_valid" : "zh.untoned_mid_invalid")
            }
        }
        // Syllables covered by a multi-syllable lexicon phrase (real Chinese forms words).
        var covered = [Bool](repeating: false, count: tonedRun.count)
        for i in tonedRun.indices {
            for n in 2...4 where i + n <= tonedRun.count {
                if !lexicon.entries(for: Array(tonedRun[i..<(i + n)])).isEmpty {
                    for k in i..<(i + n) { covered[k] = true }
                }
            }
        }
        let coveredCount = covered.filter { $0 }.count
        if coveredCount > 0 { add("zh.phrase", Double(coveredCount)) }
        if isLast && afterOther && !finishing && !parse.syllables.contains(where: \.toned) {
            add("zh.unconfirmed")
        }
        if afterOther {
            add("seg.switch")
        } else if previous == .zhuyin {
            add("ctx.zh")
        }
        return f
    }

    /// Features of `keys` output as typed, or nil if impossible.
    public static func literal(_ keys: [Character], english: EnglishModel, isLast: Bool = true,
                               afterOther: Bool = false, finishing: Bool = false,
                               previous: InputMode? = nil) -> FeatureVector? {
        if keys.isEmpty || keys.contains(" ") { return nil }
        let complete = !isLast || finishing
        var f: FeatureVector = ["lit.bias": 1]
        func add(_ k: String, _ v: Double = 1) { f[k, default: 0] += v }
        if afterOther {
            add("seg.switch")
        } else if previous == .literal {
            add("ctx.lit")
        }
        if keys.contains(where: { $0.isUppercase }) { add("lit.upper") }

        let letters = String(keys.filter { $0.isLetter })
        let digits = keys.filter { $0.isNumber }.count
        let others = keys.count - letters.count - digits
        if letters.isEmpty {
            if digits > 0 { add("lit.num_digits", Double(digits)) }
            if others > 0 { add("lit.num_others", Double(others)) }
            return f
        }
        for (k, v) in english.wordFeatures(letters, complete: complete || digits > 0) { add(k, v) }
        if digits > 0 { add("lit.digits", Double(digits)) }
        let nonApostrophe = others - keys.filter { $0 == "'" }.count
        if nonApostrophe > 0 { add("lit.others", Double(nonApostrophe)) }
        return f
    }
}
