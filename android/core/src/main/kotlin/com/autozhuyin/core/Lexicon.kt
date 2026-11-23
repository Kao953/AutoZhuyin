package com.autozhuyin.core

import java.io.Reader

/** A phrase and its log10 score. */
data class Entry(val phrase: String, val score: Double)

/** A converted piece: syllables [start, end) of a Zhuyin segment shown as `text`. */
data class Piece(val start: Int, val end: Int, val text: String)

/** Syllable range [start, end). */
data class Span(val start: Int, val end: Int)

private val TONE_MARK_CHARS = setOf('ˊ', 'ˇ', 'ˋ', '˙')

private fun stripTones(reading: String) = reading.filterNot { it in TONE_MARK_CHARS }

internal fun isBopomofo(s: String) = s.isNotEmpty() && (s[0].code in 0x3105..0x312F || s[0] == '˙')

/**
 * Maps readings ("ㄋㄧˇ-ㄏㄠˇ") to entries, best first.
 * Port of windows/autozhuyin/core/lexicon.py (Swift: Lexicon.swift).
 */
class Lexicon {
    val exact = LinkedHashMap<String, MutableList<Entry>>()
    /**
     * User phrases (setUserPhrases), kept apart so they can be replaced while running. They
     * override a built-in entry for the same phrase and reading.
     */
    @Volatile var user: Map<String, List<Entry>> = emptyMap()
        private set
    @Volatile private var tonelessIndex: Map<String, List<Entry>>? = null
    /** Phrase -> (reading, score), for readingOf. */
    @Volatile private var readings: Map<String, Pair<String, Double>>? = null
    var maxPhraseLength = 1
        private set

    fun load(reader: Reader) {
        reader.buffered().useLines { lines -> load(lines) }
    }

    fun load(lines: Sequence<String>) {
        for (raw in lines) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val cols = line.split(WHITESPACE)
            if (cols.size < 2) continue
            val (reading, phrase) = if (isBopomofo(cols[0])) cols[0] to cols[1] else cols[1] to cols[0]
            if (!isBopomofo(reading)) continue
            val score = if (cols.size >= 3) cols[2].toDoubleOrNull() ?: -6.0 else -6.0
            add(reading, phrase, score)
        }
        for (v in exact.values) if (v.size > 1) v.sortByDescending { it.score }
        tonelessIndex = null
        readings = null
    }

    /** Replaces the user phrases (user-phrases.txt, lexicon format). */
    fun setUserPhrases(text: String) {
        val parsed = Lexicon()
        parsed.load(text.lineSequence())
        user = parsed.exact
        maxPhraseLength = maxOf(maxPhraseLength, parsed.maxPhraseLength)
        tonelessIndex = null
        readings = null
    }

    private fun merged(key: String, builtIn: List<Entry>): List<Entry> {
        val mine = user[key]
        if (mine.isNullOrEmpty()) return builtIn
        val phrases = mine.mapTo(HashSet()) { it.phrase }
        return (mine + builtIn.filter { it.phrase !in phrases }).sortedByDescending { it.score }
    }

    /**
     * The most likely reading of a phrase: its own entry if the lexicon has one, otherwise the
     * most common reading of each character. null if a character has none.
     */
    fun readingOf(phrase: String): String? {
        val index = readings ?: HashMap<String, Pair<String, Double>>().also { index ->
            for (source in listOf(exact, user)) {
                for ((reading, entries) in source) {
                    for (e in entries) {
                        val old = index[e.phrase]
                        if (old == null || e.score > old.second) index[e.phrase] = reading to e.score
                    }
                }
            }
            readings = index
        }
        index[phrase]?.let { return it.first }
        val out = ArrayList<String>()
        var i = 0
        while (i < phrase.length) {
            val n = Character.charCount(phrase.codePointAt(i))
            val r = index[phrase.substring(i, i + n)]
            if (r == null || "-" in r.first) return null
            out.add(r.first)
            i += n
        }
        return out.joinToString("-").ifEmpty { null }
    }

    fun add(reading: String, phrase: String, score: Double) {
        val syllables = reading.split("-").map { if (it.startsWith("˙")) it.substring(1) + "˙" else it }
        val key = syllables.joinToString("-")
        maxPhraseLength = maxOf(maxPhraseLength, syllables.size)
        val entries = exact.getOrPut(key) { mutableListOf() }
        if (entries.none { it.phrase == phrase }) entries.add(Entry(phrase, score))
        tonelessIndex = null
        readings = null
    }

    /** Index ignoring tones: toneless reading -> entries (best score per phrase), best first. */
    val toneless: Map<String, List<Entry>>
        get() = tonelessIndex ?: synchronized(this) {
            tonelessIndex ?: buildToneless().also { tonelessIndex = it }
        }

    private fun buildToneless(): Map<String, List<Entry>> {
        val best = HashMap<String, LinkedHashMap<String, Double>>()
        for ((reading, entries) in exact.entries + user.entries) {
            val bucket = best.getOrPut(stripTones(reading)) { LinkedHashMap() }
            for (e in entries) {
                if (e.score > (bucket[e.phrase] ?: Double.NEGATIVE_INFINITY)) bucket[e.phrase] = e.score
            }
        }
        val out = HashMap<String, List<Entry>>(best.size * 2)
        for ((k, v) in best) out[k] = v.map { Entry(it.key, it.value) }.sortedByDescending { it.score }
        return out
    }

    fun entries(syllables: List<Syllable>): List<Entry> =
        if (syllables.all { it.tone != null }) {
            val key = syllables.joinToString("-") { it.reading }
            merged(key, exact[key] ?: emptyList())
        } else {
            toneless[syllables.joinToString("-") { it.toneless }] ?: emptyList()
        }

    fun bestScore(syllable: Syllable): Double? = entries(listOf(syllable)).firstOrNull()?.score

    companion object {
        private val WHITESPACE = Regex("\\s+")

        fun from(reader: Reader) = Lexicon().apply { load(reader) }
    }
}

/** Syllables → Chinese text (Viterbi over lexicon phrases). Port of lexicon.py's Converter. */
class Converter(val lexicon: Lexicon, val history: UserHistory? = null) {

    private fun entries(syllables: List<Syllable>): List<Entry> {
        val e = lexicon.entries(syllables)
        return history?.adjust(syllables, e) ?: e
    }

    private fun options(syllables: List<Syllable>, i: Int, j: Int, fixed: Map<Span, String>): List<Entry> {
        fixed[Span(i, j)]?.let { return listOf(Entry(it, 0.0)) }
        if (fixed.keys.any { it.start < j && i < it.end }) return emptyList()
        val sl = syllables.subList(i, j)
        val penalty = if (sl.any { it.tone == null }) TONELESS_PENALTY else 0.0
        val out = entries(sl).map { Entry(it.phrase, it.score + penalty) }
        if (out.isEmpty() && j - i == 1) return listOf(Entry(sl[0].reading, UNKNOWN_SCORE))
        return out
    }

    /** The best path. `fixed` maps syllable ranges to text the user picked. */
    fun convert(syllables: List<Syllable>, fixed: Map<Span, String> = emptyMap()): List<Piece> {
        val n = syllables.size
        if (n == 0) return emptyList()
        val maxLen = maxOf(1, lexicon.maxPhraseLength)
        val bestScore = DoubleArray(n + 1) { Double.NEGATIVE_INFINITY }
        val bestPiece = arrayOfNulls<Piece>(n + 1)
        bestScore[0] = 0.0
        for (j in 1..n) {
            for (length in 1..minOf(maxLen, j)) {
                val i = j - length
                if (bestScore[i] == Double.NEGATIVE_INFINITY) continue
                for (o in options(syllables, i, j, fixed)) {
                    val total = bestScore[i] + o.score
                    if (total > bestScore[j]) {
                        bestScore[j] = total
                        bestPiece[j] = Piece(i, j, o.phrase)
                    }
                }
            }
        }
        val segs = ArrayList<Piece>()
        var j = n
        while (j > 0) {
            val seg = bestPiece[j] ?: break
            segs.add(seg)
            j = seg.start
        }
        segs.reverse()
        return segs
    }

    /** Phrases ending at syllable `end`, longest first. */
    fun candidates(syllables: List<Syllable>, end: Int): List<Piece> {
        if (end <= 0 || end > syllables.size) return emptyList()
        val out = ArrayList<Piece>()
        val seen = HashSet<String>()
        for (length in minOf(lexicon.maxPhraseLength, end) downTo 1) {
            val i = end - length
            for (e in entries(syllables.subList(i, end))) {
                if (seen.add(e.phrase)) out.add(Piece(i, end, e.phrase))
            }
        }
        return out
    }

    companion object {
        const val UNKNOWN_SCORE = -30.0
        const val TONELESS_PENALTY = -1.5
    }
}
