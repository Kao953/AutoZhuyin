package com.autozhuyin.core

/** What handle() did: whether the key was consumed, and text to commit to the app. */
data class KeyResult(val handled: Boolean, val commit: String? = null) {
    companion object {
        val PASS = KeyResult(false)
        val CONSUMED = KeyResult(true)
    }
}

/** Part of the composition shown in one mode (English is drawn differently). */
data class MarkedPiece(val text: String, val mode: Mode)

/**
 * Input method state machine. Port of windows/autozhuyin/core/engine.py
 * (Swift: CompositionEngine.swift); the three behave the same and share test cases.
 *
 * Keys are one-character strings, or one of the special key names below.
 * The buffer is split into Zhuyin / literal segments, e.g. "ji3hello" -> 我 + hello.
 * Text offsets (cursorOffset) are in UTF-16 units, as Android's InputConnection expects.
 */
class CompositionEngine(
    val classifier: Classifier,
    /** Monotonic clock in seconds. */
    var now: () -> Double = { System.nanoTime() / 1e9 },
) {
    val converter = Converter(classifier.lexicon, classifier.history)
    var pageSize = 9
    var contextWindow = 20.0

    val keys = mutableListOf<String>()
    private var forcedMode: Mode? = null
    private var forcedCount = 0
    /** English mode, toggled by a Shift tap when nothing is being typed: keys go straight to the app. */
    var englishMode = false
        private set
    /** "`" typed; the next key may be a forced symbol. */
    private var backtick = false
    /** Zhuyin segment start -> {syllable range: picked text}. */
    private var fixed = mutableMapOf<Int, MutableMap<Span, String>>()
    var candidates: List<Piece> = emptyList()
        private set
    /** Candidates are the "`" + space symbol table. */
    var symbolTable = false
        private set
    var candidateIndex = 0
    private var candidateSegmentStart = 0
    // Composition cursor: a key index into keys (null = at the end). ← → move it between
    // syllables; ↓ opens candidates for the phrase before it; typing there inserts a
    // syllable (kept in `inserting` until its tone key, then spliced in).
    private var cursor: Int? = null
    private val inserting = mutableListOf<String>()
    /** Index of a held space (see HOLD_MIN_SCORE), or null. */
    private var held: Int? = null
    /** Last characters committed: context for "AI 選字" (not ported yet). */
    var recentText = ""
        private set
    private var previousMode: Mode? = null
    private var previousTime = Double.NEGATIVE_INFINITY
    private var cacheKey: Any? = null
    private var cacheValue: List<Segment> = emptyList()

    // --- derived state ---

    val context: Mode? get() = if (now() - previousTime < contextWindow) previousMode else null

    private data class CacheKey(val keys: List<String>, val finishing: Boolean, val ctx: Mode?, val held: Int?)

    private fun segments(keys: List<String>, finishing: Boolean = false): List<Segment> {
        if (keys.isEmpty()) return emptyList()
        forcedMode?.let { return listOf(Segment(0, keys.size, it)) }
        val ctx = context
        val h = held?.takeIf { it < keys.size && keys[it] == " " }
        val key = CacheKey(keys.toList(), finishing, ctx, h)
        if (key != cacheKey) {
            cacheKey = key
            cacheValue = if (h == null) classifier.segment(keys, finishing, ctx) else heldSegments(keys, h, finishing)
        }
        return cacheValue
    }

    /** The held word is Chinese if the words typed after it start with Chinese. */
    private fun heldSegments(keys: List<String>, held: Int, finishing: Boolean): List<Segment> {
        val base = held + 1
        val rest = classifier.segment(keys.subList(base, keys.size), finishing, null)
            .map { Segment(it.start + base, it.end + base, it.mode) }
        if (rest.isNotEmpty() && rest[0].mode == Mode.ZHUYIN && heldReadsAsChinese(keys, held, rest[0].end, finishing)) {
            return listOf(Segment(0, rest[0].end, Mode.ZHUYIN)) + rest.drop(1)
        }
        return listOf(Segment(0, base, Mode.LITERAL)) + rest
    }

    /** Chinese all the way to `end` vs. the held English word followed by Chinese. */
    private fun heldReadsAsChinese(keys: List<String>, held: Int, end: Int, finishing: Boolean): Boolean {
        val c = classifier
        val w = c.weights
        val ctx = context
        val isLast = end == keys.size
        val zhWhole = c.segmentFeatures(keys.subList(0, end), isLast, false, finishing, ctx).first ?: return false
        val word = c.segmentFeatures(keys.subList(0, held), false, false, true, ctx).second
        val zhRest = c.segmentFeatures(keys.subList(held + 1, end), isLast, true, finishing, null).first
        if (word == null || zhRest == null) return true
        return Features.dot(w, zhWhole) >= Features.dot(w, word) + Features.dot(w, zhRest)
    }

    /**
     * Whether keys + space also read as a common Chinese syllable (see HOLD_MIN_SCORE).
     * Any Dachen keys count, not only letters: "0" is ㄢ (安), "5j;" is ㄓㄨㄤ (裝).
     */
    private fun isAmbiguousWord(keys: List<String>): Boolean {
        if (!keys.all { Bopomofo.isZhuyinKey(it) }) return false
        val p = Bopomofo.parse(keys + " ")
        if (p.pending != null || p.syllables.isEmpty() || p.strayTones != 0 || p.foreignKeys != 0) return false
        val best = ArrayList<Double>()
        for (ps in p.syllables) {
            val entries = classifier.lexicon.entries(listOf(ps.syllable))
            if (entries.isEmpty()) return false
            best.add(entries[0].score)
        }
        if (context != Mode.LITERAL) return true   // first word: hold anything that reads as Zhuyin
        return best.size == 1 && best[0] >= HOLD_MIN_SCORE
    }

    val segments: List<Segment> get() = segments(keys)

    val mode: Mode get() = segments.lastOrNull()?.mode ?: Mode.ZHUYIN

    val isComposing: Boolean get() = keys.isNotEmpty() || candidates.isNotEmpty() || backtick || inserting.isNotEmpty()

    val showingCandidates: Boolean get() = candidates.isNotEmpty()

    val pageStart: Int get() = (candidateIndex / pageSize) * pageSize

    /** (syllables converted to Chinese, pending Bopomofo) for a Zhuyin segment. */
    private fun convertible(seg: Segment, final: Boolean): Pair<List<Syllable>, String> {
        val p = Bopomofo.parse(keys.subList(seg.start, seg.end))
        if (final) return p.syllables.map { it.syllable } to ""
        return p.completed.map { it.syllable } to (p.pending?.syllable?.reading ?: "")
    }

    private fun conversion(seg: Segment, final: Boolean): Pair<List<Piece>, String> {
        val (syl, pending) = convertible(seg, final)
        val fx = fixed[seg.start]?.filterKeys { it.end <= syl.size } ?: emptyMap()
        return converter.convert(syl, fx) to pending
    }

    private fun render(seg: Segment, final: Boolean): String {
        if (seg.mode == Mode.LITERAL) return keys.subList(seg.start, seg.end).joinToString("")
        val (converted, pending) = conversion(seg, final)
        return converted.joinToString("") { it.text } + pending
    }

    // --- cursor ---

    /** Absolute key index after each syllable of a Zhuyin segment. */
    private fun syllableEnds(seg: Segment): List<Int> =
        Bopomofo.parse(keys.subList(seg.start, seg.end)).syllables.map { seg.start + it.end }

    /**
     * Key indices the cursor can stop at: after every Zhuyin syllable and at every segment
     * boundary, but never before the first Chinese character.
     */
    private fun cursorPositions(): List<Int> {
        val out = sortedSetOf(keys.size)
        val ends = ArrayList<Int>()
        for (seg in segments) {
            out.add(seg.end)
            if (seg.mode == Mode.ZHUYIN) ends += syllableEnds(seg)
        }
        out.addAll(ends)
        val first = ends.minOrNull() ?: keys.size
        return out.filter { it >= first }
    }

    /** (segment index, syllables before pos) for the Zhuyin segment pos is in. */
    private fun stopAt(pos: Int): Pair<Int, Int>? {
        val segs = segments
        for ((i, seg) in segs.withIndex()) {
            if (seg.mode == Mode.ZHUYIN && seg.start < pos && pos <= seg.end) {
                val n = convertible(seg, i < segs.size - 1).first.size
                val local = syllableEnds(seg).count { it <= pos }
                return if (local != 0) i to minOf(local, n) else null
            }
        }
        return null
    }

    /** Where ↓ opens candidates: before the cursor, or the last syllable. */
    private fun candidateStop(): Pair<Int, Int>? {
        cursor?.let { return stopAt(it) }
        val segs = segments
        for (i in segs.indices.reversed()) {
            if (segs[i].mode == Mode.ZHUYIN) {
                val n = convertible(segs[i], i < segs.size - 1).first.size
                if (n != 0) return i to n
            }
        }
        return null
    }

    /** Cursor position in the rendered segments (without the syllable being inserted). */
    private fun baseCursorOffset(): Int {
        val pieces = segmentPieces()
        val c = cursor ?: return pieces.sumOf { it.text.length }
        val segs = segments
        for ((i, seg) in segs.withIndex()) {
            if (!(seg.start < c && c <= seg.end)) continue
            var offset = pieces.take(i).sumOf { it.text.length }
            if (seg.mode == Mode.LITERAL) return offset + c - seg.start
            val local = stopAt(c)?.second ?: 0
            for (piece in conversion(seg, i < segs.size - 1).first) {
                if (piece.end <= local) {
                    offset += piece.text.length
                } else if (piece.start < local) {
                    // Part of a phrase: one character per syllable.
                    val chars = minOf(local - piece.start, piece.text.codePointCount(0, piece.text.length))
                    offset += piece.text.offsetByCodePoints(0, chars)
                }
            }
            return offset
        }
        return 0
    }

    /** Cursor position in markedText (UTF-16 units). */
    val cursorOffset: Int get() = baseCursorOffset() + insertingText().length

    private fun moveCursor(delta: Int) {
        inserting.clear()
        val stops = cursorPositions()
        val here = cursor ?: keys.size
        val next = if (delta < 0) stops.lastOrNull { it < here } ?: here else stops.firstOrNull { it > here } ?: here
        cursor = if (next >= keys.size) null else next
    }

    private fun insertingText(): String =
        if (inserting.isEmpty()) "" else Bopomofo.parse(inserting).syllables.joinToString("") { it.syllable.reading }

    // --- editing in the middle ---

    /** Keeps picked phrases that end at or before key index pos (they don't move). */
    private fun trimFixed(pos: Int) {
        val kept = mutableMapOf<Int, MutableMap<Span, String>>()
        for (seg in segments) {
            val picks = fixed[seg.start]
            if (picks.isNullOrEmpty() || seg.mode != Mode.ZHUYIN) continue
            if (seg.end <= pos) {
                kept[seg.start] = picks
            } else if (seg.start < pos) {
                val ends = syllableEnds(seg)
                val here = picks.filterKeys { it.end <= ends.size && ends[it.end - 1] <= pos }
                if (here.isNotEmpty()) kept[seg.start] = here.toMutableMap()
            }
        }
        fixed = kept
    }

    /** Inserts keys at the cursor and moves the cursor after them. */
    private fun splice(newKeys: List<String>) {
        val pos = cursor ?: keys.size
        trimFixed(pos)
        keys.addAll(pos, newKeys)
        held?.let { if (it >= pos) held = it + newKeys.size }
        val c = pos + newKeys.size
        cursor = if (c >= keys.size) null else c
    }

    /** Backspace in the middle: removes the syllable (or literal key) before the cursor. */
    private fun deleteBeforeCursor() {
        val pos = cursor ?: return
        var start = pos - 1
        for (seg in segments) {
            if (seg.mode == Mode.ZHUYIN && seg.start < pos && pos <= seg.end) {
                for (ps in Bopomofo.parse(keys.subList(seg.start, seg.end)).syllables) {
                    if (seg.start + ps.end == pos) start = seg.start + ps.start
                }
            }
        }
        trimFixed(start)
        keys.subList(start, pos).clear()
        held?.let {
            if (it in start until pos) held = null else if (it >= pos) held = it - (pos - start)
        }
        cursor = start
        if (keys.isEmpty()) reset()
    }

    /** Typing with the cursor in the middle: compose one syllable, splice it in on its tone. */
    private fun insertKey(c: String): KeyResult {
        if (c == " ") {
            if (inserting.isEmpty()) return KeyResult(true, commit())
            splice(inserting + " ")
            inserting.clear()
            return KeyResult.CONSUMED
        }
        inserting.add(c)
        val p = Bopomofo.parse(inserting)
        if (p.strayTones != 0 || p.foreignKeys != 0) {
            inserting.removeAt(inserting.size - 1)   // a tone with nothing to attach to
            return KeyResult.CONSUMED
        }
        if (p.syllables.isNotEmpty() && p.syllables.last().toned && p.syllables.size == 1) {
            splice(inserting.toList())
            inserting.clear()
        } else if (p.syllables.size > 1) {
            // A new syllable started without a tone: splice the first one as it is.
            val first = p.syllables[0].end
            splice(inserting.subList(0, first).toList())
            inserting.subList(0, first).clear()
        }
        return KeyResult.CONSUMED
    }

    val markedPieces: List<MarkedPiece>
        get() {
            var pieces = segmentPieces()
            if (inserting.isNotEmpty()) {
                // Show the syllable being inserted at the cursor.
                var at = baseCursorOffset()
                val out = ArrayList<MarkedPiece>()
                var done = false
                for (p in pieces) {
                    if (!done && at <= p.text.length) {
                        out += MarkedPiece(p.text.substring(0, at), p.mode)
                        out += MarkedPiece(insertingText(), Mode.ZHUYIN)
                        out += MarkedPiece(p.text.substring(at), p.mode)
                        done = true
                    } else {
                        out += p
                        at -= p.text.length
                    }
                }
                pieces = out.filter { it.text.isNotEmpty() }
            }
            if (backtick) pieces = pieces + MarkedPiece(BACKTICK, Mode.LITERAL)
            return pieces
        }

    private fun segmentPieces(): List<MarkedPiece> {
        val segs = segments
        return segs.mapIndexed { i, s -> MarkedPiece(render(s, i < segs.size - 1), s.mode) }
    }

    val markedText: String get() = markedPieces.joinToString("") { it.text }

    // --- key handling ---

    /** Forces the whole buffer into the other mode (a correction that is learned). */
    private fun flip() {
        forcedMode = mode.other
        forcedCount = keys.size   // that word is learned, not what is typed after it
    }

    /** Whether handle(key) would consume the key, without changing state. */
    fun wants(key: String): Boolean {
        if (candidates.isNotEmpty() || key == SHIFT_TAP || backtick || inserting.isNotEmpty()) return true
        if (englishMode && keys.isEmpty()) return false   // English mode: everything goes to the app as typed
        if (key in SPECIAL_KEYS) return keys.isNotEmpty()
        if (key == BACKTICK) return true
        if (keys.isNotEmpty()) return true
        if (key == " ") return false
        if (Bopomofo.isZhuyinKey(key) || isAsciiLetter(key)) return true
        return context == Mode.ZHUYIN && key in FULLWIDTH
    }

    fun handle(key: String): KeyResult {
        if (candidates.isNotEmpty()) return handleCandidateKey(key)
        if (backtick) return afterBacktick(key)
        if (inserting.isNotEmpty() && (key == BACKSPACE || key == ESCAPE)) {
            if (key == BACKSPACE) inserting.removeAt(inserting.size - 1) else inserting.clear()
            return KeyResult.CONSUMED
        }
        when (key) {
            BACKSPACE -> {
                if (keys.isEmpty()) return KeyResult.PASS
                cursor?.let {
                    if (it > 0) deleteBeforeCursor()
                    return KeyResult.CONSUMED
                }
                keys.removeAt(keys.size - 1)
                held?.let { if (keys.size <= it) held = null }
                fixed = fixed.filterKeys { it < keys.size }.toMutableMap()
                if (keys.isEmpty()) {
                    forcedMode = null
                    fixed = mutableMapOf()
                }
                return KeyResult.CONSUMED
            }
            ENTER -> {
                if (keys.isEmpty()) return KeyResult.PASS
                if (inserting.isNotEmpty()) {
                    splice(inserting.toList())
                    inserting.clear()
                }
                return KeyResult(true, commit())
            }
            ESCAPE -> {
                if (keys.isEmpty()) return KeyResult.PASS
                reset()
                return KeyResult.CONSUMED
            }
            TAB -> {
                if (keys.isEmpty()) return KeyResult.PASS
                flip()
                return KeyResult.CONSUMED
            }
            SHIFT_TAP -> {
                if (keys.isEmpty()) {
                    // Toggle English mode; it stays on until the next Shift tap.
                    englishMode = !englishMode
                    previousMode = if (englishMode) Mode.LITERAL else null
                    previousTime = now()
                } else {
                    flip()
                }
                return KeyResult.CONSUMED
            }
            DOWN -> {
                if (keys.isEmpty()) return KeyResult.PASS
                if (inserting.isEmpty()) openCandidates()
                return KeyResult.CONSUMED
            }
            LEFT, RIGHT -> {
                if (keys.isEmpty()) return KeyResult.PASS
                moveCursor(if (key == LEFT) -1 else 1)
                return KeyResult.CONSUMED
            }
            UP -> return if (keys.isNotEmpty()) KeyResult.CONSUMED else KeyResult.PASS
        }
        return handleCharacter(key)
    }

    private fun afterBacktick(key: String): KeyResult {
        backtick = false
        if (key == ESCAPE || key == BACKSPACE) return KeyResult.CONSUMED
        // After English ("`ls` "), space keeps the backtick literal (Markdown code).
        val opensTable = key == DOWN || (key == " " && (keys.isEmpty() || mode == Mode.ZHUYIN))
        val committed = if (keys.isNotEmpty()) commit() else ""
        SYMBOLS[key]?.let { return KeyResult(true, committed + it) }
        if (opensTable) {
            openSymbolTable()
            return KeyResult(true, committed.ifEmpty { null })
        }
        // Not a symbol: the backtick was meant literally; then handle the key as usual.
        var r = handle(key)
        if (!r.handled && key.length == 1) r = KeyResult(true, key)
        return KeyResult(r.handled, committed + BACKTICK + (r.commit ?: ""))
    }

    private fun lastParse(segs: List<Segment>): ZhuyinParse? {
        val last = segs.lastOrNull() ?: return null
        if (last.mode != Mode.ZHUYIN) return null
        return Bopomofo.parse(keys.subList(last.start, last.end))
    }

    private fun handleCharacter(c: String): KeyResult {
        if (cursor != null && keys.isNotEmpty() && (c == " " || Bopomofo.isZhuyinKey(c))) return insertKey(c)
        if (inserting.isNotEmpty()) {
            splice(inserting.toList())
            inserting.clear()
        }
        cursor = null   // anything else continues at the end
        if (englishMode && keys.isEmpty()) return KeyResult.PASS   // English mode: every key goes to the app as typed
        if (c == BACKTICK) {
            backtick = true
            return KeyResult.CONSUMED
        }
        if (c == " ") {
            if (keys.isEmpty()) return KeyResult.PASS
            val segs = segments(keys, finishing = true)
            if (segs.last().mode == Mode.LITERAL) {
                if (held == null && segs.size == 1 && forcedMode == null && isAmbiguousWord(keys)) {
                    held = keys.size
                    keys.add(" ")
                    return KeyResult.CONSUMED
                }
                return KeyResult(true, commit(segs) + " ")
            }
            val p = lastParse(segs)
            if (p?.pending != null) {
                keys.add(" ")
                return KeyResult.CONSUMED
            }
            return KeyResult(true, commit(segs))
        }

        val composable = Bopomofo.isZhuyinKey(c) || isAsciiLetter(c) || (c == "'" && keys.isNotEmpty())
        if (composable) {
            // ", . / ; -" are Zhuyin symbols but act as punctuation after an English word.
            if (keys.isNotEmpty() && c in Bopomofo.SYMBOLS && !c[0].isLetterOrDigit() && forcedMode != Mode.ZHUYIN) {
                val withKey = segments(keys + c)
                if (withKey.last().mode == Mode.LITERAL && !keys.all { k -> k[0].isDigit() }) {
                    return KeyResult(true, commit() + c)
                }
            }
            keys.add(c)
            return KeyResult.CONSUMED
        }

        val chinese = if (keys.isEmpty()) context == Mode.ZHUYIN else mode == Mode.ZHUYIN
        val committed = if (keys.isNotEmpty()) commit() else ""
        val punct = if (chinese) FULLWIDTH[c] ?: c else c
        if (committed.isEmpty() && punct == c) return KeyResult.PASS
        return KeyResult(true, committed + punct)
    }

    // --- candidates ---

    /** Candidates for the phrase ending at the cursor (default: the last syllable). */
    private fun openCandidates() {
        val (segIndex, local) = candidateStop() ?: return
        val segs = segments
        val seg = segs[segIndex]
        val syl = convertible(seg, segIndex < segs.size - 1).first
        candidates = converter.candidates(syl, local)
        candidateSegmentStart = seg.start
        candidateIndex = 0
        symbolTable = false
    }

    private fun openSymbolTable() {
        candidates = SYMBOL_TABLE.map { Piece(0, 0, it) }
        candidateIndex = 0
        symbolTable = true
    }

    /** Ctrl + ; ' , . / → ；、，。？ (commits any composition first). null: a shortcut for the app. */
    fun handleControl(key: String): KeyResult? {
        val symbol = CONTROL_SYMBOLS[key] ?: return null
        candidates = emptyList()
        backtick = false
        if (inserting.isNotEmpty()) {
            splice(inserting.toList())
            inserting.clear()
        }
        val committed = if (keys.isNotEmpty()) commit() else ""
        return KeyResult(true, committed + symbol)
    }

    /** Candidates on the current page and the highlighted one within it. */
    fun page(): Pair<List<String>, Int> {
        val start = pageStart
        return candidates.subList(start, minOf(candidates.size, start + pageSize)).map { it.text } to candidateIndex - start
    }

    /** Picks a candidate. Returns the text to commit when it comes from the symbol table. */
    fun selectCandidate(index: Int): String? {
        if (index !in candidates.indices) return null
        val c = candidates[index]
        if (symbolTable) {
            candidates = emptyList()
            symbolTable = false
            return c.text
        }
        val here = (fixed[candidateSegmentStart] ?: emptyMap<Span, String>())
            .filterKeys { !(it.start < c.end && c.start < it.end) }.toMutableMap()
        here[Span(c.start, c.end)] = c.text
        fixed[candidateSegmentStart] = here
        candidates = emptyList()
        return null
    }

    fun closeCandidates() {
        candidates = emptyList()
        symbolTable = false
    }

    private fun handleCandidateKey(key: String): KeyResult {
        var commit: String? = null
        when {
            key.length == 1 && key[0] in '1'..'9' -> commit = selectCandidate(pageStart + (key[0] - '1'))
            key == " " || key == ENTER -> commit = selectCandidate(candidateIndex)
            key == DOWN || key == RIGHT -> candidateIndex = minOf(candidates.size - 1, candidateIndex + 1)
            key == UP || key == LEFT -> candidateIndex = maxOf(0, candidateIndex - 1)
            key == ESCAPE || key == BACKSPACE -> closeCandidates()
        }
        return KeyResult(true, commit)
    }

    // --- commit ---

    private fun commit(segs: List<Segment> = segments): String {
        val text = segs.joinToString("") { render(it, true) }
        rememberPicks(segs)
        val ctx = if (now() - previousTime < contextWindow) recentText else ""
        recentText = (ctx + text).takeLast(20)
        forcedMode?.let { classifier.learned.record(keys.subList(0, forcedCount).joinToString(""), it) }
        previousMode = segs.lastOrNull()?.mode
        previousTime = now()
        reset()
        return text
    }

    /** Candidates the user picked are remembered and come first next time. */
    private fun rememberPicks(segs: List<Segment>) {
        for (seg in segs) {
            val picks = fixed[seg.start]
            if (seg.mode != Mode.ZHUYIN || picks.isNullOrEmpty()) continue
            val syl = convertible(seg, true).first
            for ((r, text) in picks) {
                if (r.end <= syl.size) classifier.history.record(syl.subList(r.start, r.end), text)
            }
        }
    }

    fun commitAll(): String = if (keys.isNotEmpty()) commit() else ""

    fun reset() {
        keys.clear()
        inserting.clear()
        held = null
        backtick = false
        cursor = null
        forcedMode = null
        fixed = mutableMapOf()
        candidates = emptyList()
        symbolTable = false
    }

    companion object {
        const val BACKSPACE = "<backspace>"
        const val ENTER = "<enter>"
        const val ESCAPE = "<escape>"
        const val TAB = "<tab>"
        const val UP = "<up>"
        const val DOWN = "<down>"
        const val LEFT = "<left>"
        const val RIGHT = "<right>"
        /** Shift pressed and released on its own. */
        const val SHIFT_TAP = "<shift-tap>"
        val SPECIAL_KEYS = setOf(BACKSPACE, ENTER, ESCAPE, TAB, UP, DOWN, LEFT, RIGHT, SHIFT_TAP)

        val FULLWIDTH = mapOf(
            "<" to "，", ">" to "。", "?" to "？", "!" to "！", ":" to "：", "\"" to "「", "(" to "（", ")" to "）",
            "{" to "『", "}" to "』", "[" to "「", "]" to "」", "~" to "～", "_" to "——", "\\" to "、",
        )

        /**
         * The first word of a composition that also reads as Zhuyin is not committed as English
         * on space; the next word decides ("up jo4" = 因為, "up the" = up the). Right after English
         * text only common one-syllable readings are held, so normal English typing is not delayed.
         */
        const val HOLD_MIN_SCORE = -3.5

        /** "`" then one of these keys always gives the full-width symbol. */
        const val BACKTICK = "`"
        val SYMBOLS = mapOf(
            "," to "，", "<" to "，", "." to "。", ">" to "。", "/" to "？", "?" to "？", ";" to "；", ":" to "：",
            "'" to "、", "\\" to "、", "\"" to "「", "[" to "「", "]" to "」", "{" to "『", "}" to "』",
            "(" to "（", ")" to "）", "!" to "！", "~" to "～", "-" to "——", "_" to "——", "=" to "＝",
        )

        /** Ctrl + key → full-width symbol, whatever the context. */
        val CONTROL_SYMBOLS = mapOf(";" to "；", "'" to "、", "," to "，", "." to "。", "/" to "？")

        /** "`" then space (or ↓): every full-width symbol, most used first. */
        val SYMBOL_TABLE = listOf(
            "，", "。", "、", "；", "：", "？", "！", "「", "」",
            "『", "』", "（", "）", "《", "》", "〈", "〉", "…",
            "——", "～", "・", "【", "】", "〔", "〕", "＂", "＇",
            "＋", "－", "×", "÷", "＝", "≠", "≦", "≧", "％",
            "＃", "＆", "＊", "＠", "／", "＼", "｜", "＿", "※",
            "○", "●", "△", "▲", "□", "■", "☆", "★", "◎",
            "→", "←", "↑", "↓", "℃", "°", "√", "∞", "　",
        )

        private fun isAsciiLetter(s: String) = s.length == 1 && (s[0] in 'a'..'z' || s[0] in 'A'..'Z')
    }
}
