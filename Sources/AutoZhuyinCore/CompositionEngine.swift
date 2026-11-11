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
    /// Set by Tab / a Shift tap while typing: overrides the classifier for the whole
    /// buffer. It is a correction, learned on commit.
    public private(set) var forcedMode: InputMode?
    /// English mode, toggled by a Shift tap when nothing is being typed. Keys go straight
    /// to the app (no composition, no underline) until Shift is tapped again.
    public private(set) var isEnglishMode = false
    /// User-picked phrases: Zhuyin segment start (key index) → syllable range → text.
    private var fixed: [Int: [Range<Int>: String]] = [:]
    public private(set) var candidates: [Candidate] = []
    private var candidateSegmentStart = 0
    /// Composition cursor for choosing candidates: index into `cursorStops`, nil = at the end.
    /// ← → move it; ↓ shows candidates for the phrase ending at the cursor.
    private var cursor: Int?
    public var candidateIndex = 0
    public var isShowingCandidates: Bool { !candidates.isEmpty }

    /// Index of a held space: an English word that is also a common one-syllable Chinese
    /// reading ("up " = ㄧㄣ 因) is not committed on space; the next word decides
    /// ("up jo4" = 因為, "up the" = up the).
    private var held: Int?
    /// "`" was typed: if the next key is in `symbols` it gives that full-width symbol
    /// whatever the context; anything else makes it a plain backtick (so ``` still works).
    public private(set) var pendingBacktick = false
    static let holdMinScore = -3.5

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
        if let h = held, h < keys.count, keys[h] == " " {
            return heldSegments(keys, held: h, finishing: finishing)
        }
        return classifier.segment(keys, finishing: finishing, previous: context)
    }

    /// The held word is Chinese if the words typed after it start with Chinese.
    private func heldSegments(_ keys: [Character], held h: Int, finishing: Bool) -> [Segment] {
        let base = h + 1
        let rest = classifier.segment(Array(keys[base...]), finishing: finishing, previous: nil).map {
            Segment(range: ($0.range.lowerBound + base)..<($0.range.upperBound + base), mode: $0.mode)
        }
        if let first = rest.first, first.mode == .zhuyin {
            return [Segment(range: 0..<first.range.upperBound, mode: .zhuyin)] + rest.dropFirst()
        }
        return [Segment(range: 0..<base, mode: .literal)] + rest
    }

    /// Whether keys + space also read as a common Chinese syllable (see `held`).
    private func isAmbiguousWord(_ keys: [Character]) -> Bool {
        guard keys.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let p = ZhuyinParser.parse(keys + [" "])
        guard p.pending == nil, p.syllables.count == 1 else { return false }
        guard let best = classifier.lexicon.entries(for: p.syllables.map(\.syllable)).first else { return false }
        return best.score >= CompositionEngine.holdMinScore
    }

    /// Current split of the buffer into Zhuyin / literal runs.
    public var segments: [Segment] { segments(of: keys) }

    /// Mode of the last segment (what the user is typing right now).
    public var mode: InputMode { segments.last?.mode ?? .zhuyin }

    /// What to show underlined in the app while composing.
    public var markedText: String { markedPieces.map(\.text).joined() }

    public var markedPieces: [MarkedPiece] {
        let segs = segments
        var pieces = segs.enumerated().map { i, seg in
            MarkedPiece(text: render(seg, final: i < segs.count - 1), mode: seg.mode)
        }
        if pendingBacktick { pieces.append(MarkedPiece(text: "`", mode: .literal)) }
        return pieces
    }

    /// Text for one segment. A non-final Zhuyin segment shows its unfinished syllable as Bopomofo.
    private func render(_ seg: Segment, final: Bool) -> String {
        guard seg.mode == .zhuyin else { return String(keys[seg.range]) }
        let (converted, pending) = conversion(of: seg, final: final)
        return converted.map(\.text).joined() + pending
    }

    /// Syllables of a Zhuyin segment that are converted to Chinese (all of them when
    /// final, otherwise the finished ones).
    private func convertibleSyllables(_ seg: Segment, final: Bool) -> (syllables: [Syllable], pending: String) {
        let p = ZhuyinParser.parse(Array(keys[seg.range]))
        if final { return (p.syllables.map(\.syllable), "") }
        return (p.completed.map(\.syllable), p.pending?.syllable.reading ?? "")
    }

    private func conversion(of seg: Segment, final: Bool) -> (segments: [ConvertedSegment], pending: String) {
        let (syl, pending) = convertibleSyllables(seg, final: final)
        let fixedHere = (fixed[seg.range.lowerBound] ?? [:]).filter { $0.key.upperBound <= syl.count }
        return (converter.convert(syl, fixed: fixedHere), pending)
    }

    // MARK: - Cursor

    /// A place the cursor can stop: after the `local`-th syllable of Zhuyin segment `segIndex`.
    private struct CursorStop { let segIndex: Int; let local: Int }

    private var cursorStops: [CursorStop] {
        let segs = segments
        var out: [CursorStop] = []
        for (i, seg) in segs.enumerated() where seg.mode == .zhuyin {
            let n = convertibleSyllables(seg, final: i < segs.count - 1).syllables.count
            for k in stride(from: 1, through: n, by: 1) { out.append(CursorStop(segIndex: i, local: k)) }
        }
        return out
    }

    /// Cursor position in `markedText`, in Characters.
    public var cursorOffset: Int {
        let pieces = markedPieces
        let total = pieces.reduce(0) { $0 + $1.text.count }
        let stops = cursorStops
        guard let c = cursor, stops.indices.contains(c) else { return total }
        let stop = stops[c]
        var offset = pieces[..<stop.segIndex].reduce(0) { $0 + $1.text.count }
        let segs = segments
        for conv in conversion(of: segs[stop.segIndex], final: stop.segIndex < segs.count - 1).segments {
            if conv.range.upperBound <= stop.local {
                offset += conv.text.count
            } else if conv.range.lowerBound < stop.local {
                offset += min(stop.local - conv.range.lowerBound, conv.text.count)
            }
        }
        return offset
    }

    private func moveCursor(by delta: Int) {
        let stops = cursorStops
        guard !stops.isEmpty else { return }
        let next = (cursor ?? stops.count - 1) + delta
        cursor = next >= stops.count - 1 ? nil : max(0, next)
    }

    // MARK: - Key handling

    public func handle(_ key: KeyInput) -> KeyResult {
        if isShowingCandidates { return handleCandidateKey(key) }
        if pendingBacktick { return afterBacktick(key) }

        switch key {
        case .character(let c):
            return handleCharacter(c)
        case .backspace:
            guard !keys.isEmpty else { return .passThrough }
            cursor = nil
            keys.removeLast()
            if let h = held, keys.count <= h { held = nil }
            fixed = fixed.filter { $0.key < keys.count }
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
            flip()
            return .consumed
        case .shiftTap:
            if keys.isEmpty {
                // Toggle English mode; it stays on until the next Shift tap.
                isEnglishMode.toggle()
                previousMode = isEnglishMode ? .literal : nil
                previousCommitTime = now()
            } else {
                flip()
            }
            return .consumed
        case .down:
            guard !keys.isEmpty else { return .passThrough }
            openCandidates()
            return .consumed
        case .left:
            guard !keys.isEmpty else { return .passThrough }
            moveCursor(by: -1)
            return .consumed
        case .right:
            guard !keys.isEmpty else { return .passThrough }
            moveCursor(by: 1)
            return .consumed
        case .up:
            return keys.isEmpty ? .passThrough : .consumed
        }
    }

    /// Forces the whole buffer into the other mode (a correction that is learned).
    private func flip() {
        forcedMode = (mode == .zhuyin) ? .literal : .zhuyin
    }

    private func handleCharacter(_ c: Character) -> KeyResult {
        cursor = nil   // typing always continues at the end
        // English mode: every key goes to the app as typed.
        if isEnglishMode && keys.isEmpty { return .passThrough }
        if c == "`" {
            pendingBacktick = true
            return .consumed
        }
        if c == " " {
            guard !keys.isEmpty else { return .passThrough }
            let segs = segments(of: keys, finishing: true)
            if segs.last?.mode == .literal {
                if held == nil, segs.count == 1, forcedMode == nil, isAmbiguousWord(keys) {
                    held = keys.count
                    keys.append(" ")
                    return .consumed
                }
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

    private func afterBacktick(_ key: KeyInput) -> KeyResult {
        pendingBacktick = false
        if key == .escape || key == .backspace { return .consumed }
        let committed = keys.isEmpty ? "" : commitCurrent()
        if case .character(let c) = key, let symbol = CompositionEngine.symbols[c] {
            return KeyResult(handled: true, commit: committed + symbol)
        }
        // Not a symbol: the backtick was meant literally; then handle the key as usual.
        var r = handle(key)
        if !r.handled, case .character(let c) = key { r = KeyResult(handled: true, commit: String(c)) }
        return KeyResult(handled: r.handled, commit: committed + "`" + (r.commit ?? ""))
    }

    /// "`" + key → full-width symbol.
    static let symbols: [Character: String] = [
        ",": "，", "<": "，", ".": "。", ">": "。", "/": "？", "?": "？", ";": "；", ":": "：",
        "'": "、", "\\": "、", "\"": "「", "[": "「", "]": "」", "{": "『", "}": "』",
        "(": "（", ")": "）", "!": "！", "~": "～", "-": "——", "_": "——", "=": "＝",
    ]

    static let fullwidth: [Character: String] = [
        "<": "，", ">": "。", "?": "？", "!": "！", ":": "：", "\"": "「", "(": "（", ")": "）",
        "{": "『", "}": "』", "[": "「", "]": "」", "~": "～", "_": "——",
    ]

    // MARK: - Candidates (for the last Zhuyin segment)

    /// Opens candidates for the phrase ending at the cursor (default: the last syllable).
    private func openCandidates() {
        let stops = cursorStops
        guard !stops.isEmpty else { return }
        let stop = stops[min(cursor ?? stops.count - 1, stops.count - 1)]
        let segs = segments
        let seg = segs[stop.segIndex]
        let syl = convertibleSyllables(seg, final: stop.segIndex < segs.count - 1).syllables
        candidates = converter.candidates(syl, endingAt: stop.local)
        candidateSegmentStart = seg.range.lowerBound
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
        if let forced = forcedMode {
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
        held = nil
        pendingBacktick = false
        cursor = nil
        forcedMode = nil
        fixed = [:]
        candidates = []
    }
}
