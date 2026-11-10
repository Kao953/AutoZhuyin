import Foundation

public enum KeyInput: Equatable {
    case character(Character)
    case backspace, enter, escape, tab
    case up, down, left, right
}

public struct KeyResult: Equatable {
    /// false → the key should go to the app untouched.
    public var handled: Bool
    /// Text to insert into the app (finalised), if any.
    public var commit: String?

    public static let passThrough = KeyResult(handled: false, commit: nil)
    public static let consumed = KeyResult(handled: true, commit: nil)
}

/// The whole input-method state machine, independent of InputMethodKit.
///
/// Keystrokes accumulate in a buffer. On every key the classifier decides whether the
/// buffer is Zhuyin or literal text; the composition (marked text) shows the result
/// live. Space / Enter / punctuation commit it. Tab flips the decision and the
/// correction is learned.
public final class CompositionEngine {
    public let classifier: Classifier
    public let converter: Converter

    public private(set) var keys: [Character] = []
    /// Set by Tab: overrides the classifier for the current buffer.
    public private(set) var forcedMode: InputMode?
    /// User-picked phrases, by syllable range.
    public private(set) var fixed: [Range<Int>: String] = [:]
    public private(set) var candidates: [Candidate] = []
    public var candidateIndex = 0
    public var isShowingCandidates: Bool { !candidates.isEmpty }

    private var previousMode: InputMode?
    private var previousCommitTime = Date.distantPast
    /// How long the previous segment's mode keeps influencing the next one.
    public var contextWindow: TimeInterval = 20
    public var now: () -> Date = Date.init

    public init(classifier: Classifier) {
        self.classifier = classifier
        self.converter = Converter(lexicon: classifier.lexicon)
    }

    // MARK: - Derived state

    private var context: InputMode? {
        now().timeIntervalSince(previousCommitTime) < contextWindow ? previousMode : nil
    }

    public var mode: InputMode {
        forcedMode ?? classifier.classify(keys, previous: context).mode
    }

    public var parse: ZhuyinParse { ZhuyinParser.parse(keys) }

    /// What to show underlined in the app while composing.
    public var markedText: String {
        guard !keys.isEmpty else { return "" }
        switch mode {
        case .literal:
            return String(keys)
        case .zhuyin:
            let p = parse
            let done = converter.convert(p.completed.map(\.syllable), fixed: validFixed(p)).map(\.text).joined()
            return done + (p.pending?.syllable.reading ?? "")
        }
    }

    private func validFixed(_ p: ZhuyinParse) -> [Range<Int>: String] {
        fixed.filter { $0.key.upperBound <= p.completed.count }
    }

    private func zhuyinCommitText() -> String {
        let p = parse
        // An unfinished trailing syllable is converted as untoned.
        return converter.convert(p.syllables.map(\.syllable), fixed: validFixed(p)).map(\.text).joined()
    }

    // MARK: - Key handling

    public func handle(_ key: KeyInput) -> KeyResult {
        if isShowingCandidates { return handleCandidateKey(key) }

        switch key {
        case .character(let c):
            return handleCharacter(c)
        case .backspace:
            guard !keys.isEmpty else { return .passThrough }
            keys.removeLast()
            fixed = validFixed(parse)
            if keys.isEmpty { forcedMode = nil; fixed = [:] }
            return .consumed
        case .enter:
            guard !keys.isEmpty else { return .passThrough }
            return KeyResult(handled: true, commit: commitCurrent())
        case .escape:
            guard !keys.isEmpty else { return .passThrough }
            reset()
            return .consumed
        case .tab:
            guard !keys.isEmpty else { return .passThrough }
            forcedMode = (mode == .zhuyin) ? .literal : .zhuyin
            return .consumed
        case .down:
            guard !keys.isEmpty else { return .passThrough }
            openCandidates()
            return .consumed
        case .up, .left, .right:
            return keys.isEmpty ? .passThrough : .consumed
        }
    }

    private func handleCharacter(_ c: Character) -> KeyResult {
        if c == " " {
            guard !keys.isEmpty else { return .passThrough }
            let decided = forcedMode ?? classifier.classify(keys, finishing: true, previous: context).mode
            if decided == .literal {
                return KeyResult(handled: true, commit: commitCurrent(as: .literal) + " ")
            }
            if parse.pending != nil {
                keys.append(" ")       // first tone
                return .consumed
            }
            return KeyResult(handled: true, commit: commitCurrent(as: .zhuyin))
        }

        let composable = DachenLayout.isZhuyinKey(c) || (c.isASCII && c.isLetter) || (c == "'" && !keys.isEmpty)
        if composable {
            // ", . / ; -" are Zhuyin symbols (ㄝ ㄡ ㄥ ㄤ ㄦ) but act as punctuation after an
            // English word. Decide with the key included: "2;" is ㄉㄤ (檔…), "hello," is English.
            if !keys.isEmpty, DachenLayout.symbols[c] != nil, !c.isLetter, !c.isNumber, forcedMode != .zhuyin {
                let withKey = forcedMode ?? classifier.classify(keys + [c], previous: context).mode
                if withKey == .literal && !keys.allSatisfy(\.isNumber) {
                    return KeyResult(handled: true, commit: commitCurrent(as: .literal) + String(c))
                }
            }
            keys.append(c)
            return .consumed
        }

        // Any other character (Shift-punctuation, symbols): commit, then emit it.
        let chineseContext = keys.isEmpty ? (context == .zhuyin) : (mode == .zhuyin)
        let committed = keys.isEmpty ? "" : commitCurrent()
        let punct = chineseContext ? (CompositionEngine.fullwidth[c] ?? String(c)) : String(c)
        if committed.isEmpty && punct == String(c) { return .passThrough }
        return KeyResult(handled: true, commit: committed + punct)
    }

    static let fullwidth: [Character: String] = [
        "<": "，", ">": "。", "?": "？", "!": "！", ":": "：", "\"": "「", "(": "（", ")": "）",
        "{": "『", "}": "』", "[": "「", "]": "」", "~": "～", "_": "——",
    ]

    // MARK: - Candidates

    private func openCandidates() {
        let p = parse
        guard mode == .zhuyin, !p.completed.isEmpty else { return }
        candidates = converter.candidates(p.completed.map(\.syllable), endingAt: p.completed.count)
        candidateIndex = 0
    }

    public func selectCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        let c = candidates[index]
        fixed = fixed.filter { !$0.key.overlaps(c.range) }
        fixed[c.range] = c.text
        candidates = []
    }

    private func handleCandidateKey(_ key: KeyInput) -> KeyResult {
        switch key {
        case .character(let c) where c.isNumber && c != "0":
            selectCandidate(Int(String(c))! - 1 + pageStart)
        case .character(" "), .enter:
            selectCandidate(candidateIndex)
        case .down, .right:
            candidateIndex = min(candidates.count - 1, candidateIndex + 1)
        case .up, .left:
            candidateIndex = max(0, candidateIndex - 1)
        case .escape, .backspace:
            candidates = []
        default:
            break
        }
        return .consumed
    }

    public var pageSize = 9
    private var pageStart: Int { (candidateIndex / pageSize) * pageSize }

    // MARK: - Commit

    @discardableResult
    private func commitCurrent(as decided: InputMode? = nil) -> String {
        let m = decided ?? mode
        let text = m == .literal ? String(keys) : zhuyinCommitText()
        if let forced = forcedMode {
            classifier.learned.record(String(keys), as: forced)
        }
        previousMode = m
        previousCommitTime = now()
        reset()
        return text
    }

    /// Commits whatever is composed (e.g. the app lost focus). Returns "" when empty.
    public func commitAll() -> String {
        keys.isEmpty ? "" : commitCurrent()
    }

    public func reset() {
        keys = []
        forcedMode = nil
        fixed = [:]
        candidates = []
    }
}
