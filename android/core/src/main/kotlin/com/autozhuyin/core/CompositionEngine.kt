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
    /** Tab flips the last segment: keys from forcedStart on are forced into forcedMode. */
    private var forcedMode: Mode? = null
    private var forcedCount = 0
    private var forcedStart = 0
    /** The segments before the flipped one, as they were when it was flipped (they stay). */
    private var forcedPrefix: List<Segment> = emptyList()
    /**
     * Tab with the cursor in the middle flips the word before it: where that word ends (the
     * keys after it are segmented as usual). null: the flip runs to the end.
     */
    private var forcedEnd: Int? = null
    /** English mode, toggled by a Shift tap when nothing is being typed: keys go straight to the app. */
    var englishMode = false
        private set
    /** "`" typed; the next key may be a forced symbol. */
    private var backtick = false
    /**
     * A Shift-punctuation after Chinese or with nothing composed, not sent yet: full-width or
     * not is only a guess, so Tab (or a Shift tap) switches "<" ↔ "，" first and ↓ offers the
     * other symbols the key could mean ("[" → 「『（【…). Any other key sends it.
     */
    var punct: String? = null
        private set
    private var punctFullwidth = false
    /** What punctFullwidth started as. */
    private var punctGuess = false
    /** Picked with ↓, shown instead. */
    private var punctChoice: String? = null
    /** The last key was a "." sent as English punctuation: more dots follow it ("hello..."). */
    private var afterEnglishDot = false
    /** Zhuyin segment start -> {syllable range: picked text}. */
    private var fixed = mutableMapOf<Int, MutableMap<Span, String>>()
    var candidates: List<Piece> = emptyList()
        private set
    /** Candidates are the "`" + space symbol table. */
    var symbolTable = false
        private set
    /** Candidates are the held punctuation's choices. */
    var punctTable = false
        private set
    var candidateIndex = 0
    private var candidateSegmentStart = 0
    // Composition cursor: a key index into keys (null = at the end). ← → move it between
    // syllables; ↓ opens candidates for the phrase before it; typing there inserts a
    // syllable (kept in `inserting` until its tone key, then spliced in).
    private var cursor: Int? = null
    private val inserting = mutableListOf<String>()
    /**
     * Index of a held space (see HOLD_MIN_SCORE), or null, and where the held word starts
     * (0 = the first word; after Chinese only the strict rule holds: "5k4ek7up m,4" = 這個音樂).
     */
    private var held: Int? = null
    private var heldStart = 0
    /** Last characters committed: context for "AI 選字" (not ported yet). */
    var recentText = ""
        private set

    /**
     * The last commit by space, until the next key: Tab right after it retypes the same keys
     * in the other mode (an after-the-fact correction, learned like a Tab flip). Not after
     * Enter: that confirms the text, and Tab next is completion or indenting.
     */
    private class LastCommit(val keys: List<String>, val text: String, val mode: Mode, val recentText: String)
    private var lastCommit: LastCommit? = null
    private var previousMode: Mode? = null
    private var previousTime = Double.NEGATIVE_INFINITY
    private var cacheKey: Any? = null
    private var cacheValue: List<Segment> = emptyList()

    // --- derived state ---

    val context: Mode? get() = if (now() - previousTime < contextWindow) previousMode else null

    private data class CacheKey(val keys: List<String>, val finishing: Boolean, val ctx: Mode?, val held: Int?, val heldStart: Int)

    private fun segments(keys: List<String>, finishing: Boolean = false): List<Segment> {
        if (keys.isEmpty()) return emptyList()
        forcedMode?.let { forced ->
            val end = forcedEnd
            if (end == null || end >= keys.size) return forcedPrefix + Segment(forcedStart, keys.size, forced)
            val tail = classifier.segment(keys.subList(end, keys.size), finishing, forced)
                .map { Segment(it.start + end, it.end + end, it.mode) }
            return forcedPrefix + Segment(forcedStart, end, forced) + tail
        }
        val ctx = context
        val h = held?.takeIf { it < keys.size && keys[it] == " " }
        val key = CacheKey(keys.toList(), finishing, ctx, h, heldStart)
        if (key != cacheKey) {
            cacheKey = key
            cacheValue = if (h == null) classifier.segment(keys, finishing, ctx) else heldSegments(keys, h, heldStart, finishing)
        }
        return cacheValue
    }

    /** The held word is Chinese if the words typed after it start with Chinese. */
    private fun heldSegments(keys: List<String>, held: Int, start: Int, finishing: Boolean): List<Segment> {
        val base = held + 1
        val prefix = if (start > 0) classifier.segment(keys.subList(0, start), true, context).toMutableList()
                     else mutableListOf()
        val rest = classifier.segment(keys.subList(base, keys.size), finishing, null)
            .map { Segment(it.start + base, it.end + base, it.mode) }
        if (rest.isNotEmpty() && rest[0].mode == Mode.ZHUYIN &&
            heldReadsAsChinese(keys, held, start, rest[0].end, finishing)) {
            // One Chinese run with the Chinese before it, so the phrase converts as a whole.
            var from = start
            if (prefix.isNotEmpty() && prefix.last().mode == Mode.ZHUYIN) from = prefix.removeAt(prefix.size - 1).start
            return prefix + Segment(from, rest[0].end, Mode.ZHUYIN) + rest.drop(1)
        }
        return prefix + Segment(start, base, Mode.LITERAL) + rest
    }

    /** Chinese all the way to `end` vs. the held English word followed by Chinese. */
    private fun heldReadsAsChinese(keys: List<String>, held: Int, start: Int, end: Int, finishing: Boolean): Boolean {
        val c = classifier
        val w = c.weights
        val ctx = if (start > 0) Mode.ZHUYIN else context   // after Chinese: Chinese goes on
        val isLast = end == keys.size
        val zhWhole = c.segmentFeatures(keys.subList(start, end), isLast, false, finishing, ctx).first ?: return false
        val word = c.segmentFeatures(keys.subList(start, held), false, start > 0, true, if (start > 0) null else ctx).second
        val zhRest = c.segmentFeatures(keys.subList(held + 1, end), isLast, true, finishing, null).first
        if (word == null || zhRest == null) return true
        return Features.dot(w, zhWhole) >= Features.dot(w, word) + Features.dot(w, zhRest)
    }

    /**
     * Whether keys + space also read as a common Chinese syllable (see HOLD_MIN_SCORE).
     * Any Dachen keys count, not only letters: "0" is ㄢ (安), "5j;" is ㄓㄨㄤ (裝).
     */
    private fun isAmbiguousWord(keys: List<String>, strict: Boolean = false): Boolean {
        if (!keys.all { Bopomofo.isZhuyinKey(it) }) return false
        val p = parse(keys + " ")
        if (p.pending != null || p.syllables.isEmpty() || p.strayTones != 0 || p.foreignKeys != 0) return false
        val best = ArrayList<Double>()
        for (ps in p.syllables) {
            val entries = classifier.lexicon.entries(listOf(ps.syllable))
            if (entries.isEmpty()) return false
            best.add(entries[0].score)
        }
        if (!strict && context != Mode.LITERAL) return true   // first word: hold anything that reads as Zhuyin
        return best.size == 1 && best[0] >= HOLD_MIN_SCORE
    }

    /** With 要打聲調才出字 on, symbols typed over an untoned syllable correct it (see Bopomofo.parse). */
    private fun parse(keys: List<String>) = Bopomofo.parse(keys, strict = converter.requireTones)

    val segments: List<Segment> get() = segments(keys)

    val mode: Mode get() = segments.lastOrNull()?.mode ?: Mode.ZHUYIN

    val isComposing: Boolean get() = keys.isNotEmpty() || candidates.isNotEmpty() || backtick || punct != null ||
        inserting.isNotEmpty()

    val showingCandidates: Boolean get() = candidates.isNotEmpty()

    val pageStart: Int get() = (candidateIndex / pageSize) * pageSize

    /** (syllables converted to Chinese, pending Bopomofo) for a Zhuyin segment. */
    private fun convertible(seg: Segment, final: Boolean): Pair<List<Syllable>, String> {
        val p = parse(keys.subList(seg.start, seg.end))
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
        parse(keys.subList(seg.start, seg.end)).syllables.map { seg.start + it.end }

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
    val cursorOffset: Int get() = baseCursorOffset() + insertingText().length + punctText().length

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
        unforceBefore(pos)
        forcedEnd?.let {
            if (forcedMode != null && pos < it) {
                forcedEnd = it + newKeys.size
                forcedCount += newKeys.size
            }
        }
        keys.addAll(pos, newKeys)
        held?.let {
            if (it >= pos) {
                held = it + newKeys.size
                if (heldStart >= pos) heldStart += newKeys.size
            }
        }
        val c = pos + newKeys.size
        cursor = if (c >= keys.size) null else c
    }

    /** Backspace in the middle: removes the syllable (or literal key) before the cursor. */
    /**
     * Backspace at the end: where the last syllable starts when it is a whole character
     * (closed by its tone), so it goes at once; otherwise just the last key.
     */
    private fun wholeCharacterStart(): Int {
        val seg = segments.lastOrNull()
        if (seg != null && seg.mode == Mode.ZHUYIN && seg.end == keys.size) {
            val last = parse(keys.subList(seg.start, seg.end)).syllables.lastOrNull()
            if (last != null && last.toned && seg.start + last.end == keys.size) return seg.start + last.start
        }
        return keys.size - 1
    }

    private fun deleteBeforeCursor() {
        val pos = cursor ?: return
        var start = pos - 1
        for (seg in segments) {
            if (seg.mode == Mode.ZHUYIN && seg.start < pos && pos <= seg.end) {
                for (ps in parse(keys.subList(seg.start, seg.end)).syllables) {
                    if (seg.start + ps.end == pos) start = seg.start + ps.start
                }
            }
        }
        trimFixed(start)
        unforceBefore(start)
        forcedEnd?.let {
            if (forcedMode != null && start < it) {
                val cut = minOf(pos, it) - start
                forcedEnd = it - cut
                forcedCount = maxOf(forcedStart, forcedCount - cut)
                if (it - cut <= forcedStart) {   // the flipped word is gone
                    forcedMode = null
                    forcedPrefix = emptyList()
                    forcedEnd = null
                }
            }
        }
        keys.subList(start, pos).clear()
        held?.let {
            if (it in start until pos) held = null else if (it >= pos) held = it - (pos - start)
            if (held != null && heldStart >= pos) heldStart -= pos - start
            else if (held != null && heldStart > start) held = null   // the held word was cut
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
            if (punct != null) pieces = pieces + MarkedPiece(punctText(), if (punctIsHalfwidth()) Mode.LITERAL else Mode.ZHUYIN)
            return pieces
        }

    private fun segmentPieces(): List<MarkedPiece> {
        val segs = segments
        return segs.mapIndexed { i, s -> MarkedPiece(render(s, i < segs.size - 1), s.mode) }
    }

    val markedText: String get() = markedPieces.joinToString("") { it.text }

    // --- key handling ---

    /**
     * Forces the last word into the other mode (a correction that is learned); what is before
     * it stays as it is ("ji3so" Tab: 我 stays, so → 內; 我要 Tab: 我ul4). With the cursor in
     * the middle, the word before the cursor instead.
     */
    private fun flip() {
        cursor?.let { if (it < keys.size) { flipAt(it); return } }
        val segs = segments
        val last = segs.lastOrNull() ?: return
        var prefix = segs.dropLast(1)
        var start = last.start
        if (last.mode == Mode.ZHUYIN) {
            val cut = flipStart(last)
            if (cut > start) {
                prefix = prefix + Segment(start, cut, Mode.ZHUYIN)
                start = cut
            }
        }
        forcedPrefix = prefix
        forcedStart = start
        forcedMode = last.mode.other
        forcedCount = keys.size   // that word is learned, not what is typed after it
        forcedEnd = null
    }

    /**
     * Tab with the cursor at key index pos: flips the syllable (in Chinese) or the English word
     * that ends at the cursor; the rest stays as it is.
     */
    private fun flipAt(pos: Int) {
        val segs = segments
        val i = segs.indexOfFirst { it.start < pos && pos <= it.end }
        if (i < 0) return
        val seg = segs[i]
        var prefix = segs.subList(0, i).toList()
        var start = seg.start
        var end = seg.end
        if (seg.mode == Mode.ZHUYIN) {
            parse(keys.subList(seg.start, seg.end)).syllables.firstOrNull { seg.start + it.end >= pos }?.let {
                start = seg.start + it.start
                end = seg.start + it.end
                if (start > seg.start) prefix = prefix + Segment(seg.start, start, Mode.ZHUYIN)
            }
        }
        forcedPrefix = prefix
        forcedStart = start
        forcedEnd = if (end < keys.size) end else null
        forcedMode = seg.mode.other
        forcedCount = end
    }

    /**
     * Where Tab's flip starts in a Chinese segment: the untoned keys at its end (a word still
     * being typed, like "test" read as ㄔㄍㄋㄔ), or else its last syllable.
     */
    private fun flipStart(seg: Segment): Int {
        val syls = parse(keys.subList(seg.start, seg.end)).syllables
        val lastSyl = syls.lastOrNull() ?: return seg.start
        if (lastSyl.toned) return seg.start + lastSyl.start
        return seg.start + (syls.lastOrNull { it.toned }?.end ?: 0)
    }

    /** An edit at key index pos: a flip after it no longer lines up, so drop it. */
    private fun unforceBefore(pos: Int) {
        if (forcedMode != null && pos < forcedStart) {
            forcedMode = null
            forcedPrefix = emptyList()
            forcedEnd = null
        }
    }

    /** Whether handle(key) would consume the key, without changing state. */
    fun wants(key: String): Boolean {
        if (candidates.isNotEmpty() || key == SHIFT_TAP || backtick || punct != null || inserting.isNotEmpty()) return true
        if (englishMode && keys.isEmpty()) return false   // English mode: everything goes to the app as typed
        if (key in SPECIAL_KEYS) return keys.isNotEmpty()
        if (key == BACKTICK) return true
        if (keys.isNotEmpty()) return true
        if (key == " ") return false
        if (Bopomofo.isZhuyinKey(key) || isAsciiLetter(key)) return true
        return key in FULLWIDTH
    }

    fun handle(key: String): KeyResult {
        lastCommit = null
        if (key == "." && afterEnglishDot && keys.isEmpty()) return KeyResult(true, ".")
        afterEnglishDot = false
        if (candidates.isNotEmpty()) return handleCandidateKey(key)
        if (backtick) return afterBacktick(key)
        if (punct != null) return afterPunct(key)
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
                keys.subList(wholeCharacterStart(), keys.size).clear()
                held?.let { if (keys.size <= it) held = null }
                fixed = fixed.filterKeys { it < keys.size }.toMutableMap()
                if (keys.size <= forcedStart) {
                    forcedMode = null   // the flipped word is gone
                    forcedPrefix = emptyList()
                }
                forcedEnd?.let { if (keys.size <= it) forcedEnd = null }
                if (keys.isEmpty()) fixed = mutableMapOf()
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
                if (inserting.isNotEmpty()) {
                    splice(inserting.toList())
                    inserting.clear()
                }
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

    private fun punctText(): String {
        val p = punct ?: return ""
        punctChoice?.let { return it }
        return if (punctFullwidth) FULLWIDTH[p] ?: p else p
    }

    private fun punctIsHalfwidth() = punct != null && punctText() == punct

    private fun afterPunct(key: String): KeyResult {
        if (key == TAB || key == SHIFT_TAP) {
            // To the other width (after a pick, too).
            punctFullwidth = punctIsHalfwidth()
            punctChoice = null
            return KeyResult.CONSUMED
        }
        if (key == DOWN) {
            openPunctTable()
            return KeyResult.CONSUMED
        }
        if (key == ESCAPE || key == BACKSPACE) {
            punct = null
            return KeyResult.CONSUMED
        }
        val halfwidth = punctIsHalfwidth()
        val text = commitHeld()
        // Space sends it like a word: half-width gets the space too.
        if (key == " ") return KeyResult(true, text + if (halfwidth) " " else "")
        if (key == ENTER) return KeyResult(true, text)
        var r = handle(key)
        if (!r.handled && key.length == 1) r = KeyResult(true, key)
        return KeyResult(r.handled, text + (r.commit ?: ""))
    }

    /**
     * Sends the composition, then the punctuation held after it. A switch of width says which
     * language is being typed, so the next punctuation is guessed the same way.
     */
    private fun commitHeld(): String {
        val p = punctText()
        val switched = p.isNotEmpty() && !punctIsHalfwidth() != punctGuess
        punct = null
        val text = if (keys.isNotEmpty()) commit() else ""
        if (switched) {
            previousMode = if (punctGuess) Mode.LITERAL else Mode.ZHUYIN
            previousTime = now()
        }
        return text + p
    }

    private fun openPunctTable() {
        val choices = punctChoices(punct ?: return)
        candidates = choices.map { Piece(0, 0, it) }
        candidateIndex = choices.indexOf(punctText()).coerceAtLeast(0)
        symbolTable = false
        punctTable = true
    }

    private fun lastParse(segs: List<Segment>): ZhuyinParse? {
        val last = segs.lastOrNull() ?: return null
        if (last.mode != Mode.ZHUYIN) return null
        return parse(keys.subList(last.start, last.end))
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
                    heldStart = 0
                    keys.add(" ")
                    return KeyResult.CONSUMED
                }
                val word = segs.last()
                if (held == null && segs.size >= 2 && segs[segs.size - 2].mode == Mode.ZHUYIN && forcedMode == null &&
                    isAmbiguousWord(keys.subList(word.start, word.end).toList(), strict = true)) {
                    held = keys.size
                    heldStart = word.start
                    keys.add(" ")
                    return KeyResult.CONSUMED
                }
                return KeyResult(true, commitFlippable(segs))
            }
            val p = lastParse(segs)
            if (p?.pending != null) {
                keys.add(" ")
                return KeyResult.CONSUMED
            }
            return KeyResult(true, commitFlippable(segs))
        }

        // "...": ㄡㄡㄡ is never meant. An ellipsis (…) in Chinese, three dots in English.
        if (c == "." && forcedMode == null && keys.size >= 2 && keys.takeLast(2).all { it == "." }) {
            keys.removeAt(keys.size - 1)
            keys.removeAt(keys.size - 1)
            val chinese = if (keys.isEmpty()) context != Mode.LITERAL else segments.last().mode == Mode.ZHUYIN
            val text = if (keys.isEmpty()) "" else commit()
            reset()
            previousMode = if (chinese) Mode.ZHUYIN else Mode.LITERAL
            previousTime = now()
            afterEnglishDot = !chinese
            return KeyResult(true, text + if (chinese) "…" else "...")
        }

        val composable = Bopomofo.isZhuyinKey(c) || isAsciiLetter(c) || (c == "'" && keys.isNotEmpty())
        if (composable) {
            // ", . / ; -" are Zhuyin symbols but act as punctuation after an English word.
            // A second "." waits for a third (an ellipsis).
            if (keys.isNotEmpty() && c in Bopomofo.SYMBOLS && !c[0].isLetterOrDigit() && forcedMode != Mode.ZHUYIN &&
                !(c == "." && keys.last() == ".")) {
                val withKey = segments(keys + c)
                if (withKey.last().mode == Mode.LITERAL && !keys.all { k -> k[0].isDigit() }) {
                    afterEnglishDot = c == "."
                    return KeyResult(true, commit() + c)
                }
            }
            keys.add(c)
            return KeyResult.CONSUMED
        }

        val chinese = if (keys.isEmpty()) context == Mode.ZHUYIN else mode == Mode.ZHUYIN
        if (c in FULLWIDTH && (chinese || keys.isEmpty())) {
            // Hold it after the Chinese (or alone) so Tab can switch it and ↓ pick another.
            punct = c
            punctFullwidth = chinese
            punctGuess = chinese
            punctChoice = null
            return KeyResult.CONSUMED
        }
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
        punctTable = false
    }

    private fun openSymbolTable() {
        candidates = SYMBOL_TABLE.map { Piece(0, 0, it) }
        candidateIndex = 0
        symbolTable = true
        punctTable = false
    }

    /** Ctrl + ; ' , . / → ；、，。？ (commits any composition first). null: a shortcut for the app. */
    fun handleControl(key: String): KeyResult? {
        val symbol = CONTROL_SYMBOLS[key] ?: return null
        lastCommit = null
        candidates = emptyList()
        backtick = false
        if (inserting.isNotEmpty()) {
            splice(inserting.toList())
            inserting.clear()
        }
        return KeyResult(true, commitHeld() + symbol)
    }

    /** Candidates on the current page and the highlighted one within it. */
    fun page(): Pair<List<String>, Int> {
        val start = pageStart
        return candidates.subList(start, minOf(candidates.size, start + pageSize)).map { it.text } to candidateIndex - start
    }

    /** Picks a candidate. Returns the text to commit when it comes from the symbol table. */
    fun selectCandidate(index: Int): String? {
        if (index !in candidates.indices) return null
        lastCommit = null
        val c = candidates[index]
        if (punctTable) {
            punctChoice = c.text
            candidates = emptyList()
            punctTable = false
            return null
        }
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
        punctTable = false
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
        forcedMode?.let {
            val end = forcedCount.coerceIn(forcedStart, keys.size)   // Backspace may have shortened it
            classifier.learned.record(keys.subList(forcedStart, end).joinToString(""), it)
        }
        previousMode = segs.lastOrNull()?.mode
        previousTime = now()
        reset()
        return text
    }

    /** Commits on space and remembers it for an after-the-fact Tab flip. English gets the space too. */
    private fun commitFlippable(segs: List<Segment> = segments): String {
        val typed = keys.toList()
        val context = recentText
        val mode = segs.lastOrNull()?.mode ?: Mode.ZHUYIN
        val text = commit(segs) + if (mode == Mode.LITERAL) " " else ""
        // Only Dachen keys can be reread as Zhuyin ("Hello" or "C++" cannot).
        val canFlip = mode == Mode.ZHUYIN || typed.all { it == " " || Bopomofo.isZhuyinKey(it) }
        lastCommit = if (canFlip) LastCommit(typed, text, mode, context) else null
        return text
    }

    /**
     * The text Tab would replace: the last commit, if nothing has been typed since. The shell
     * checks that the app's text before the caret still ends with it, then calls
     * flipLastCommit(); otherwise Tab goes through handle() as usual.
     */
    val flippableText: String? get() = lastCommit?.text

    /**
     * Retypes the last commit in the other mode and learns the correction. Returns the text to
     * put in place of flippableText. Tab again flips it back.
     */
    fun flipLastCommit(): String? {
        val last = lastCommit ?: return null
        if (last.keys.isEmpty()) return null
        reset()
        keys.addAll(last.keys)
        recentText = last.recentText
        if (last.mode == Mode.ZHUYIN) {
            while (keys.isNotEmpty() && keys.last() == " ") keys.removeAt(keys.size - 1)   // first-tone spaces aren't English
        }
        forcedMode = last.mode.other
        forcedCount = keys.size
        forcedStart = 0
        forcedPrefix = emptyList()
        forcedEnd = null
        return commitFlippable()
    }

    /** A key the engine didn't see (the shell passed it on): no flip after it. */
    fun forgetLastCommit() {
        lastCommit = null
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

    fun commitAll(): String {
        lastCommit = null
        return commitHeld()
    }

    fun reset() {
        keys.clear()
        inserting.clear()
        held = null
        backtick = false
        punct = null
        cursor = null
        forcedMode = null
        forcedStart = 0
        forcedPrefix = emptyList()
        forcedEnd = null
        fixed = mutableMapOf()
        candidates = emptyList()
        symbolTable = false
        punctTable = false
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

        /** ↓ on a held punctuation: the other symbols that key could mean. */
        private val OPENING = listOf("「", "『", "（", "【", "〔", "《", "〈", "“", "‘", "［", "｛")
        private val CLOSING = listOf("」", "』", "）", "】", "〕", "》", "〉", "”", "’", "］", "｝")
        val PUNCT_VARIANTS = mapOf(
            "<" to listOf("、", "；", "：", "《", "〈", "＜"), ">" to listOf("．", "…", "⋯", "・", "》", "〉", "＞"),
            "?" to listOf("！"), "!" to listOf("？"), ":" to listOf("；"), "~" to listOf("〜"),
            "_" to listOf("—", "－", "＿"), "\\" to listOf("＼", "｜", "／"),
            "\"" to OPENING, "[" to OPENING, "{" to OPENING, "(" to OPENING,
            "]" to CLOSING, "}" to CLOSING, ")" to CLOSING,
        )

        /** Everything ↓ offers for a held punctuation key, the full-width default first. */
        fun punctChoices(key: String): List<String> {
            val full = FULLWIDTH[key] ?: key
            return listOf(full) + (PUNCT_VARIANTS[key] ?: emptyList()).filter { it != full } + key
        }

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
