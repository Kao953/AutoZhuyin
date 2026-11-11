import Foundation

public enum KeyInput: Equatable {
    case character(Character)
    case backspace, enter, escape, tab
    case up, down, left, right
    /// Shift pressed and released on its own.
    case shiftTap
}

public struct KeyResult: Equatable {
    /// false → the key should go to the app untouched.
    public var handled: Bool
    /// Text to insert into the app (finalised), if any.
    public var commit: String?

    public static let passThrough = KeyResult(handled: false, commit: nil)
    public static let consumed = KeyResult(handled: true, commit: nil)
}

/// A piece of the composition as shown to the user.
public struct MarkedPiece: Equatable {
    public var text: String
    public var mode: InputMode
}

/// The whole input-method state machine, independent of InputMethodKit.
///
/// Keystrokes accumulate in a buffer. On every key the classifier splits the buffer
/// into Zhuyin and literal segments (e.g. "ji3hello" → 我 + hello); the composition
/// (marked text) shows the result live. Space / Enter / punctuation commit it. Tab
/// forces the whole buffer into the other mode and the correction is learned.
public final class CompositionEngine {
    public let classifier: Classifier
    public let converter: Converter

    public private(set) var keys: [Character] = []
    /// Set by Tab / Shift tap: overrides the classifier for the whole buffer.
    public private(set) var forcedMode: InputMode?
    /// True when forcedMode corrects the classifier (learned on commit); false when the
    /// user forced English before typing (Shift tap on an empty buffer), which is not a
    /// correction and is not learned.
    private var forcedIsCorrection = false
    /// User-picked phrases: Zhuyin segment start (key index) → syllable range → text.
    private var fixed: [Int: [Range<Int>: String]] = [:]
    public private(set) var candidates: [Candidate] = []
    private var candidateSegmentStart = 0
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

    private func segments(of keys: [Character], finishing: Bool = false) -> [Segment] {
        guard !keys.isEmpty else { return [] }
        if let forced = forcedMode { return [Segment(range: 0..<keys.count, mode: forced)] }
        return classifier.segment(keys, finishing: finishing, previous: context)
    }

    /// Current split of the buffer into Zhuyin / literal runs.
    public var segments: [Segment] { segments(of: keys) }

    /// Mode of the last segment (what the user is typing right now).
    public var mode: InputMode { segments.last?.mode ?? .zhuyin }

    /// What to show underlined in the app while composing.
    public var markedText: String { markedPieces.map(\.text).joined() }

    public var markedPieces: [MarkedPiece] {
        let segs = segments
        return segs.enumerated().map { i, seg in
            MarkedPiece(text: render(seg, final: i < segs.count - 1), mode: seg.mode)
        }
    }

    /// Text for one segment. A non-final Zhuyin segment shows its unfinished syllable as Bopomofo.
    private func render(_ seg: Segment, final: Bool) -> String {
        let segKeys = Array(keys[seg.range])
        guard seg.mode == .zhuyin else { return String(segKeys) }
        let p = ZhuyinParser.parse(segKeys)
        let fixedHere = (fixed[seg.range.lowerBound] ?? [:])
        if final {
            let all = p.syllables.map(\.syllable)
            return converter.convert(all, fixed: fixedHere.filter { $0.key.upperBound <= all.count }).map(\.text).joined()
        }
        let done = p.completed.map(\.syllable)
        let text = converter.convert(done, fixed: fixedHere.filter { $0.key.upperBound <= done.count }).map(\.text).joined()
        return text + (p.pending?.syllable.reading ?? "")
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
            fixed = fixed.filter { $0.key < keys.count }
            if keys.isEmpty {
                // A Shift-tap "next word is English" stays armed; a correction is dropped.
                if forcedIsCorrection { forcedMode = nil; forcedIsCorrection = false }
                fixed = [:]
            }
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
            flip()
            return .consumed
        case .shiftTap:
            if keys.isEmpty {
                // Next word is English, typed as-is (lowercase stays lowercase). Tap again to cancel.
                forcedMode = forcedMode == .literal ? nil : .literal
                forcedIsCorrection = false
            } else {
                flip()
            }
            return .consumed
        case .down:
            guard !keys.isEmpty else { return .passThrough }
            openCandidates()
            return .consumed
        case .up, .left, .right:
            return keys.isEmpty ? .passThrough : .consumed
        }
    }

    /// Forces the whole buffer into the other mode (a correction that is learned).
    private func flip() {
        forcedMode = (mode == .zhuyin) ? .literal : .zhuyin
        forcedIsCorrection = true
    }

    /// True while the user has forced English before typing anything (Shift tap).
    public var isEnglishArmed: Bool { keys.isEmpty && forcedMode == .literal }

    private func handleCharacter(_ c: Character) -> KeyResult {
        if c == " " {
            guard !keys.isEmpty else { return .passThrough }
            let segs = segments(of: keys, finishing: true)
            if segs.last?.mode == .literal {
                return KeyResult(handled: true, commit: commitCurrent(segs) + " ")
            }
            if parse(ofLast: segs)?.pending != nil {
                keys.append(" ")       // first tone
                return .consumed
            }
            return KeyResult(handled: true, commit: commitCurrent(segs))
        }

        let composable = DachenLayout.isZhuyinKey(c) || (c.isASCII && c.isLetter) || (c == "'" && !keys.isEmpty)
        if composable {
            // ", . / ; -" are Zhuyin symbols (ㄝ ㄡ ㄥ ㄤ ㄦ) but act as punctuation after an
            // English word. Decide with the key included: "2;" is ㄉㄤ (檔…), "hello," is English.
            if !keys.isEmpty, DachenLayout.symbols[c] != nil, !c.isLetter, !c.isNumber, forcedMode != .zhuyin {
                let withKey = segments(of: keys + [c])
                if withKey.last?.mode == .literal && !keys.allSatisfy(\.isNumber) {
                    return KeyResult(handled: true, commit: commitCurrent() + String(c))
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

    private func parse(ofLast segs: [Segment]) -> ZhuyinParse? {
        guard let last = segs.last, last.mode == .zhuyin else { return nil }
        return ZhuyinParser.parse(Array(keys[last.range]))
    }

    static let fullwidth: [Character: String] = [
        "<": "，", ">": "。", "?": "？", "!": "！", ":": "：", "\"": "「", "(": "（", ")": "）",
        "{": "『", "}": "』", "[": "「", "]": "」", "~": "～", "_": "——",
    ]

    // MARK: - Candidates (for the last Zhuyin segment)

    private func openCandidates() {
        let segs = segments
        guard let last = segs.last, last.mode == .zhuyin else { return }
        let done = ZhuyinParser.parse(Array(keys[last.range])).completed.map(\.syllable)
        guard !done.isEmpty else { return }
        candidates = converter.candidates(done, endingAt: done.count)
        candidateSegmentStart = last.range.lowerBound
        candidateIndex = 0
    }

    public func selectCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        let c = candidates[index]
        var here = (fixed[candidateSegmentStart] ?? [:]).filter { !$0.key.overlaps(c.range) }
        here[c.range] = c.text
        fixed[candidateSegmentStart] = here
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
    private func commitCurrent(_ given: [Segment]? = nil) -> String {
        let segs = given ?? segments
        let text = segs.map { render($0, final: true) }.joined()
        if let forced = forcedMode, forcedIsCorrection {
            classifier.learned.record(String(keys), as: forced)
        }
        previousMode = segs.last?.mode
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
        forcedIsCorrection = false
        fixed = [:]
        candidates = []
    }
}
