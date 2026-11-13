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
    /// Composition cursor: a key index into `keys` (nil = at the end). ← → move it between
    /// syllables; ↓ shows candidates for the phrase before it; typing there inserts a
    /// syllable (kept in `inserting` until its tone key, then spliced into `keys`).
    private var cursor: Int?
    private var inserting: [Character] = []
    public var candidateIndex = 0
    public var isShowingCandidates: Bool { !candidates.isEmpty }

    /// Index of a held space: the first word of a composition that also reads as Zhuyin is
    /// not committed as English on space; the next word decides ("up jo4" = 因為,
    /// "up the" = up the, "no su3" = no 你). Right after English text only common
    /// one-syllable readings are held (up = 因, url = 教), so English typing isn't delayed.
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
        self.converter = Converter(lexicon: classifier.lexicon, history: classifier.history)
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
        if let first = rest.first, first.mode == .zhuyin,
           heldReadsAsChinese(keys, held: h, end: first.range.upperBound, finishing: finishing) {
            return [Segment(range: 0..<first.range.upperBound, mode: .zhuyin)] + rest.dropFirst()
        }
        return [Segment(range: 0..<base, mode: .literal)] + rest
    }

    /// Chinese all the way to `end` vs. the held English word followed by Chinese.
    private func heldReadsAsChinese(_ keys: [Character], held h: Int, end: Int, finishing: Bool) -> Bool {
        let c = classifier, w = classifier.weights, ctx = context
        let isLast = end == keys.count
        guard let zhWhole = c.segmentFeatures(Array(keys[..<end]), isLast: isLast, afterOther: false,
                                              finishing: finishing, previous: ctx).0 else { return false }
        guard let word = c.segmentFeatures(Array(keys[..<h]), isLast: false, afterOther: false,
                                           finishing: true, previous: ctx).1,
              let zhRest = c.segmentFeatures(Array(keys[(h + 1)..<end]), isLast: isLast, afterOther: true,
                                             finishing: finishing, previous: nil).0 else { return true }
        return Features.dot(w, zhWhole) >= Features.dot(w, word) + Features.dot(w, zhRest)
    }

    /// Whether keys + space also read as a common Chinese syllable (see `held`).
    private func isAmbiguousWord(_ keys: [Character]) -> Bool {
        guard keys.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let p = ZhuyinParser.parse(keys + [" "])
        guard p.pending == nil, !p.syllables.isEmpty, p.strayTones == 0, p.foreignKeys == 0 else { return false }
        var best: [Double] = []
        for ps in p.syllables {
            guard let e = classifier.lexicon.entries(for: [ps.syllable]).first else { return false }
            best.append(e.score)
        }
        if context != .literal { return true }   // first word: hold anything that reads as Zhuyin
        return best.count == 1 && best[0] >= CompositionEngine.holdMinScore
    }

    /// Current split of the buffer into Zhuyin / literal runs.
    public var segments: [Segment] { segments(of: keys) }

    /// Mode of the last segment (what the user is typing right now).
    public var mode: InputMode { segments.last?.mode ?? .zhuyin }

    /// What to show underlined in the app while composing.
    public var markedText: String { markedPieces.map(\.text).joined() }

    public var markedPieces: [MarkedPiece] {
        var pieces = segmentPieces
        if !inserting.isEmpty {
            // Show the syllable being inserted at the cursor.
            var at = baseCursorOffset, out: [MarkedPiece] = [], done = false
            for piece in pieces {
                if !done && at <= piece.text.count {
                    let i = piece.text.index(piece.text.startIndex, offsetBy: at)
                    out.append(MarkedPiece(text: String(piece.text[..<i]), mode: piece.mode))
                    out.append(MarkedPiece(text: insertingText, mode: .zhuyin))
                    out.append(MarkedPiece(text: String(piece.text[i...]), mode: piece.mode))
                    done = true
                } else {
                    out.append(piece)
                    at -= piece.text.count
                }
            }
            pieces = out.filter { !$0.text.isEmpty }
        }
        if pendingBacktick { pieces.append(MarkedPiece(text: "`", mode: .literal)) }
        return pieces
    }

    private var segmentPieces: [MarkedPiece] {
        let segs = segments
        return segs.enumerated().map { i, seg in
            MarkedPiece(text: render(seg, final: i < segs.count - 1), mode: seg.mode)
        }
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

    /// Absolute key index after each syllable of a Zhuyin segment.
    private func syllableEnds(_ seg: Segment) -> [Int] {
        ZhuyinParser.parse(Array(keys[seg.range])).syllables.map { seg.range.lowerBound + $0.keyRange.upperBound }
    }

    /// Key indices the cursor can stop at: the start, after every Zhuyin syllable, and at
    /// every segment boundary.
    private var cursorPositions: [Int] {
        var out: Set<Int> = [0, keys.count]
        for seg in segments {
            out.insert(seg.range.upperBound)
            if seg.mode == .zhuyin { out.formUnion(syllableEnds(seg)) }
        }
        return out.sorted()
    }

    /// A place to open candidates: after the `local`-th syllable of Zhuyin segment `segIndex`.
    private struct CursorStop { let segIndex: Int; let local: Int }

    private func stop(at pos: Int) -> CursorStop? {
        let segs = segments
        for (i, seg) in segs.enumerated() where seg.mode == .zhuyin
            && seg.range.lowerBound < pos && pos <= seg.range.upperBound {
            let n = convertibleSyllables(seg, final: i < segs.count - 1).syllables.count
            let local = syllableEnds(seg).filter { $0 <= pos }.count
            return local > 0 ? CursorStop(segIndex: i, local: min(local, n)) : nil
        }
        return nil
    }

    /// Where ↓ opens candidates: before the cursor, or the last syllable.
    private var candidateStop: CursorStop? {
        if let c = cursor { return stop(at: c) }
        let segs = segments
        for i in segs.indices.reversed() where segs[i].mode == .zhuyin {
            let n = convertibleSyllables(segs[i], final: i < segs.count - 1).syllables.count
            if n > 0 { return CursorStop(segIndex: i, local: n) }
        }
        return nil
    }

    /// Cursor position in the rendered segments (without the syllable being inserted).
    private var baseCursorOffset: Int {
        let pieces = segmentPieces
        guard let c = cursor else { return pieces.reduce(0) { $0 + $1.text.count } }
        let segs = segments
        for (i, seg) in segs.enumerated() where seg.range.lowerBound < c && c <= seg.range.upperBound {
            var offset = pieces[..<i].reduce(0) { $0 + $1.text.count }
            if seg.mode == .literal { return offset + c - seg.range.lowerBound }
            let local = stop(at: c)?.local ?? 0
            for conv in conversion(of: seg, final: i < segs.count - 1).segments {
                if conv.range.upperBound <= local {
                    offset += conv.text.count
                } else if conv.range.lowerBound < local {
                    offset += min(local - conv.range.lowerBound, conv.text.count)
                }
            }
            return offset
        }
        return 0
    }

    /// Cursor position in `markedText`, in Characters.
    public var cursorOffset: Int { baseCursorOffset + insertingText.count }

    private var insertingText: String {
        inserting.isEmpty ? "" : ZhuyinParser.parse(inserting).syllables.map(\.syllable.reading).joined()
    }

    private func moveCursor(by delta: Int) {
        inserting = []
        let stops = cursorPositions
        let here = cursor ?? keys.count
        let next = delta < 0 ? (stops.last { $0 < here } ?? here) : (stops.first { $0 > here } ?? here)
        cursor = next >= keys.count ? nil : next
    }

    // MARK: - Editing in the middle

    /// Keeps picked phrases that end at or before key index `pos` (they don't move).
    private func trimFixed(at pos: Int) {
        var kept: [Int: [Range<Int>: String]] = [:]
        for seg in segments where seg.mode == .zhuyin {
            guard let picks = fixed[seg.range.lowerBound] else { continue }
            if seg.range.upperBound <= pos {
                kept[seg.range.lowerBound] = picks
            } else if seg.range.lowerBound < pos {
                let ends = syllableEnds(seg)
                let here = picks.filter { $0.key.upperBound <= ends.count && ends[$0.key.upperBound - 1] <= pos }
                if !here.isEmpty { kept[seg.range.lowerBound] = here }
            }
        }
        fixed = kept
    }

    /// Inserts keys at the cursor and moves the cursor after them.
    private func splice(_ newKeys: [Character]) {
        guard let pos = cursor else { keys += newKeys; return }
        trimFixed(at: pos)
        keys.insert(contentsOf: newKeys, at: pos)
        if let h = held, h >= pos { held = h + newKeys.count }
        let next = pos + newKeys.count
        cursor = next >= keys.count ? nil : next
    }

    /// Backspace in the middle: removes the syllable (or literal key) before the cursor.
    private func deleteBeforeCursor(_ pos: Int) {
        var start = pos - 1
        for seg in segments where seg.mode == .zhuyin && seg.range.lowerBound < pos && pos <= seg.range.upperBound {
            for ps in ZhuyinParser.parse(Array(keys[seg.range])).syllables
            where seg.range.lowerBound + ps.keyRange.upperBound == pos {
                start = seg.range.lowerBound + ps.keyRange.lowerBound
            }
        }
        trimFixed(at: start)
        keys.removeSubrange(start..<pos)
        if let h = held {
            if h >= start && h < pos { held = nil } else if h >= pos { held = h - (pos - start) }
        }
        cursor = start
        if keys.isEmpty { reset() }
    }

    /// Typing with the cursor in the middle: compose one syllable, splice it in on its tone.
    private func insertKey(_ c: Character) -> KeyResult {
        if c == " " {
            if inserting.isEmpty { return KeyResult(handled: true, commit: commitCurrent()) }
            splice(inserting + [" "])
            inserting = []
            return .consumed
        }
        inserting.append(c)
        let p = ZhuyinParser.parse(inserting)
        if p.strayTones > 0 || p.foreignKeys > 0 {
            inserting.removeLast()   // a tone with nothing to attach to
        } else if p.syllables.count == 1, p.syllables[0].toned {
            splice(inserting)
            inserting = []
        } else if p.syllables.count > 1 {
            // A new syllable started without a tone: splice the first one as it is.
            let first = p.syllables[0].keyRange.upperBound
            splice(Array(inserting[..<first]))
            inserting = Array(inserting[first...])
        }
        return .consumed
    }

    // MARK: - Key handling

    public func handle(_ key: KeyInput) -> KeyResult {
        if isShowingCandidates { return handleCandidateKey(key) }
        if pendingBacktick { return afterBacktick(key) }
        if !inserting.isEmpty && (key == .backspace || key == .escape) {
            if key == .backspace { inserting.removeLast() } else { inserting = [] }
            return .consumed
        }

        switch key {
        case .character(let c):
            return handleCharacter(c)
        case .backspace:
            guard !keys.isEmpty else { return .passThrough }
            if let c = cursor {
                if c > 0 { deleteBeforeCursor(c) }
                return .consumed
            }
            keys.removeLast()
            if let h = held, keys.count <= h { held = nil }
            fixed = fixed.filter { $0.key < keys.count }
            if keys.isEmpty { forcedMode = nil; fixed = [:] }
            return .consumed
        case .enter:
            guard !keys.isEmpty else { return .passThrough }
            if !inserting.isEmpty { splice(inserting); inserting = [] }
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
            if inserting.isEmpty { openCandidates() }
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
        if cursor != nil, !keys.isEmpty, c == " " || DachenLayout.isZhuyinKey(c) {
            return insertKey(c)
        }
        if !inserting.isEmpty { splice(inserting); inserting = [] }
        cursor = nil   // anything else continues at the end
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
        guard let stop = candidateStop else { return }
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
        rememberPicks(segs)
        if let forced = forcedMode {
            classifier.learned.record(String(keys), as: forced)
        }
        previousMode = segs.last?.mode
        previousCommitTime = now()
        reset()
        return text
    }

    /// Candidates the user picked are remembered and come first next time.
    private func rememberPicks(_ segs: [Segment]) {
        for seg in segs where seg.mode == .zhuyin {
            guard let picks = fixed[seg.range.lowerBound], !picks.isEmpty else { continue }
            let syl = convertibleSyllables(seg, final: true).syllables
            for (range, text) in picks where range.upperBound <= syl.count {
                classifier.history.record(Array(syl[range]), phrase: text)
            }
        }
    }

    /// Commits whatever is composed (e.g. the app lost focus). Returns "" when empty.
    public func commitAll() -> String {
        keys.isEmpty ? "" : commitCurrent()
    }

    public func reset() {
        keys = []
        inserting = []
        held = nil
        pendingBacktick = false
        cursor = nil
        forcedMode = nil
        fixed = [:]
        candidates = []
    }
}
