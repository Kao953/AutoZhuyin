package com.autozhuyin.core

/**
 * The user-phrases.txt file. Port of windows/autozhuyin/core/user_phrases.py (Swift:
 * UserPhrases.swift): entries in lexicon format ("ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -1"), other
 * lines (comments, blank lines) kept as they are.
 */
class UserPhrases(text: String = "") {
    /** One entry. score null: the line has none (the lexicon default applies). */
    data class Item(val phrase: String, val reading: String, val score: Double? = DEFAULT_SCORE)

    /** Each line: an Item, or the line's text. */
    private val lines: MutableList<Any> = text.split("\n").mapTo(ArrayList()) { parseEntry(it) ?: it }

    init {
        if (lines.lastOrNull() == "") lines.removeAt(lines.size - 1)   // the final newline
    }

    val text: String
        get() {
            val out = lines.map { line ->
                if (line is Item) "${line.reading} ${line.phrase}" + (line.score?.let { " " + format(it) } ?: "")
                else line as String
            }
            return out.joinToString("\n") + if (out.isEmpty()) "" else "\n"
        }

    val entries: List<Item> get() = lines.filterIsInstance<Item>()

    fun append(entry: Item) {
        lines.add(entry)
    }

    private fun lineIndex(index: Int): Int? {
        var n = -1
        for ((i, line) in lines.withIndex()) {
            if (line is Item && ++n == index) return i
        }
        return null
    }

    fun replace(index: Int, entry: Item) {
        lineIndex(index)?.let { lines[it] = entry }
    }

    fun remove(index: Int) {
        lineIndex(index)?.let { lines.removeAt(it) }
    }

    companion object {
        /**
         * Score for phrases added in the editor: high enough to beat the built-in phrases with
         * the same reading (log10 probability; common words are around -3).
         */
        const val DEFAULT_SCORE = -1.0

        /** Bopomofo symbol or tone mark -> its Dachen key. */
        private val DACHEN_KEY: Map<Char, String> = HashMap<Char, String>().apply {
            for ((key, symbol) in Bopomofo.SYMBOLS) put(symbol[0], key)
            for ((key, tone) in Bopomofo.TONES) if (tone != 1) put(Bopomofo.TONE_MARKS.getValue(tone)[0], key)
        }

        private val WHITESPACE = Regex("\\s+")

        /** One lexicon line: reading and phrase in either order, then an optional score. */
        fun parseEntry(line: String): Item? {
            val fields = line.trim().split(WHITESPACE).filter { it.isNotEmpty() }
            if (fields.size < 2 || fields[0].startsWith("#")) return null
            val (reading, phrase) = if (isBopomofo(fields[0])) fields[0] to fields[1] else fields[1] to fields[0]
            if (!isBopomofo(reading)) return null
            val score = if (fields.size >= 3) fields[2].toDoubleOrNull() ?: return null else null
            return Item(phrase, reading, score)
        }

        private fun format(score: Double): String =
            if (score == Math.floor(score) && !score.isInfinite()) score.toLong().toString() else score.toString()

        /**
         * The lexicon reading for what was typed: Bopomofo ("ㄗˋ ㄉㄨㄥˋ", "ㄗˋㄉㄨㄥˋ",
         * "ㄗˋ-ㄉㄨㄥˋ") or Dachen keys ("y42j/4"). A space or "-" ends a first-tone syllable.
         * null if it doesn't read as valid syllables.
         */
        fun readingFromTyped(typed: String): String? {
            val keys = typed.trim().map { c ->
                when {
                    c in "- 　" -> " "
                    c in DACHEN_KEY -> DACHEN_KEY.getValue(c)
                    else -> c.lowercase()
                }
            }
            val p = Bopomofo.parse(keys)
            if (p.foreignKeys != 0 || p.syllables.isEmpty() || !p.syllables.all { Bopomofo.isValid(it.syllable) }) return null
            return p.syllables.joinToString("-") { it.syllable.reading }
        }

        /** Why the entry can't be saved, or null if it is fine. */
        fun problem(phrase: String, reading: String): String? {
            if (phrase.isEmpty()) return "請輸入詞"
            if (phrase.any { it.isWhitespace() }) return "詞裡不能有空白"
            if (reading.isEmpty()) return "請輸入注音"
            val n = reading.split("-").size
            val chars = phrase.codePointCount(0, phrase.length)
            if (n != chars) return "注音有 $n 個音節，詞有 $chars 個字"
            return null
        }

        /**
         * Line numbers (1-based) of lines that are neither entries, comments nor blank, or
         * whose reading doesn't match the phrase.
         */
        fun badLines(text: String): List<Int> {
            val out = ArrayList<Int>()
            for ((i, line) in text.split("\n").withIndex()) {
                val stripped = line.trim()
                if (stripped.isEmpty() || stripped.startsWith("#")) continue
                val e = parseEntry(stripped)
                if (e == null || problem(e.phrase, e.reading) != null) out.add(i + 1)
            }
            return out
        }
    }
}
