package com.autozhuyin.core

/**
 * Dachen (大千) Zhuyin layout, syllable table and keystroke parser.
 *
 * Kotlin port of windows/autozhuyin/core/bopomofo.py
 * (Swift: Sources/AutoZhuyinCore/{Bopomofo,SyllableTable,ZhuyinParser}.swift).
 * Keys are one-character strings, as in the Python core.
 */
object Bopomofo {
    const val INITIAL = 0
    const val MEDIAL = 1
    const val FINAL = 2

    val SYMBOLS: Map<String, String> = mapOf(
        "1" to "ㄅ", "q" to "ㄆ", "a" to "ㄇ", "z" to "ㄈ",
        "2" to "ㄉ", "w" to "ㄊ", "s" to "ㄋ", "x" to "ㄌ",
        "e" to "ㄍ", "d" to "ㄎ", "c" to "ㄏ",
        "r" to "ㄐ", "f" to "ㄑ", "v" to "ㄒ",
        "5" to "ㄓ", "t" to "ㄔ", "g" to "ㄕ", "b" to "ㄖ",
        "y" to "ㄗ", "h" to "ㄘ", "n" to "ㄙ",
        "u" to "ㄧ", "j" to "ㄨ", "m" to "ㄩ",
        "8" to "ㄚ", "i" to "ㄛ", "k" to "ㄜ", "," to "ㄝ",
        "9" to "ㄞ", "o" to "ㄟ", "l" to "ㄠ", "." to "ㄡ",
        "0" to "ㄢ", "p" to "ㄣ", ";" to "ㄤ", "/" to "ㄥ", "-" to "ㄦ",
    )

    /** Tone number by key; first tone is the space bar. */
    val TONES: Map<String, Int> = mapOf(" " to 1, "6" to 2, "3" to 3, "4" to 4, "7" to 5)
    val TONE_MARKS: Map<Int, String> = mapOf(1 to "", 2 to "ˊ", 3 to "ˇ", 4 to "ˋ", 5 to "˙")

    private val INITIALS = "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ".map { it.toString() }.toSet()
    private val MEDIALS = "ㄧㄨㄩ".map { it.toString() }.toSet()

    fun isZhuyinKey(c: String): Boolean = c in SYMBOLS || c in TONES

    fun slotOf(symbol: String): Int = when (symbol) {
        in INITIALS -> INITIAL
        in MEDIALS -> MEDIAL
        else -> FINAL
    }

    // --- valid syllables ---

    private val RAW = """
ㄚ ㄛ ㄜ ㄝ ㄞ ㄟ ㄠ ㄡ ㄢ ㄣ ㄤ ㄥ ㄦ
ㄧ ㄧㄚ ㄧㄛ ㄧㄝ ㄧㄞ ㄧㄠ ㄧㄡ ㄧㄢ ㄧㄣ ㄧㄤ ㄧㄥ
ㄨ ㄨㄚ ㄨㄛ ㄨㄞ ㄨㄟ ㄨㄢ ㄨㄣ ㄨㄤ ㄨㄥ
ㄩ ㄩㄝ ㄩㄢ ㄩㄣ ㄩㄥ
ㄅㄚ ㄅㄛ ㄅㄞ ㄅㄟ ㄅㄠ ㄅㄢ ㄅㄣ ㄅㄤ ㄅㄥ ㄅㄧ ㄅㄧㄝ ㄅㄧㄠ ㄅㄧㄢ ㄅㄧㄣ ㄅㄧㄥ ㄅㄨ
ㄆㄚ ㄆㄛ ㄆㄞ ㄆㄟ ㄆㄠ ㄆㄡ ㄆㄢ ㄆㄣ ㄆㄤ ㄆㄥ ㄆㄧ ㄆㄧㄝ ㄆㄧㄠ ㄆㄧㄢ ㄆㄧㄣ ㄆㄧㄥ ㄆㄨ
ㄇㄚ ㄇㄛ ㄇㄜ ㄇㄞ ㄇㄟ ㄇㄠ ㄇㄡ ㄇㄢ ㄇㄣ ㄇㄤ ㄇㄥ ㄇㄧ ㄇㄧㄝ ㄇㄧㄠ ㄇㄧㄡ ㄇㄧㄢ ㄇㄧㄣ ㄇㄧㄥ ㄇㄨ
ㄈㄚ ㄈㄛ ㄈㄟ ㄈㄡ ㄈㄢ ㄈㄣ ㄈㄤ ㄈㄥ ㄈㄨ
ㄉㄚ ㄉㄜ ㄉㄞ ㄉㄟ ㄉㄠ ㄉㄡ ㄉㄢ ㄉㄣ ㄉㄤ ㄉㄥ ㄉㄧ ㄉㄧㄚ ㄉㄧㄝ ㄉㄧㄠ ㄉㄧㄡ ㄉㄧㄢ ㄉㄧㄥ ㄉㄨ ㄉㄨㄛ ㄉㄨㄟ ㄉㄨㄢ ㄉㄨㄣ ㄉㄨㄥ
ㄊㄚ ㄊㄜ ㄊㄞ ㄊㄠ ㄊㄡ ㄊㄢ ㄊㄤ ㄊㄥ ㄊㄧ ㄊㄧㄝ ㄊㄧㄠ ㄊㄧㄢ ㄊㄧㄥ ㄊㄨ ㄊㄨㄛ ㄊㄨㄟ ㄊㄨㄢ ㄊㄨㄣ ㄊㄨㄥ
ㄋㄚ ㄋㄜ ㄋㄞ ㄋㄟ ㄋㄠ ㄋㄡ ㄋㄢ ㄋㄣ ㄋㄤ ㄋㄥ ㄋㄧ ㄋㄧㄝ ㄋㄧㄠ ㄋㄧㄡ ㄋㄧㄢ ㄋㄧㄣ ㄋㄧㄤ ㄋㄧㄥ ㄋㄨ ㄋㄨㄛ ㄋㄨㄢ ㄋㄨㄥ ㄋㄩ ㄋㄩㄝ
ㄌㄚ ㄌㄛ ㄌㄜ ㄌㄞ ㄌㄟ ㄌㄠ ㄌㄡ ㄌㄢ ㄌㄤ ㄌㄥ ㄌㄧ ㄌㄧㄚ ㄌㄧㄝ ㄌㄧㄠ ㄌㄧㄡ ㄌㄧㄢ ㄌㄧㄣ ㄌㄧㄤ ㄌㄧㄥ ㄌㄨ ㄌㄨㄛ ㄌㄨㄢ ㄌㄨㄣ ㄌㄨㄥ ㄌㄩ ㄌㄩㄝ ㄌㄩㄢ
ㄍㄚ ㄍㄜ ㄍㄞ ㄍㄟ ㄍㄠ ㄍㄡ ㄍㄢ ㄍㄣ ㄍㄤ ㄍㄥ ㄍㄨ ㄍㄨㄚ ㄍㄨㄛ ㄍㄨㄞ ㄍㄨㄟ ㄍㄨㄢ ㄍㄨㄣ ㄍㄨㄤ ㄍㄨㄥ
ㄎㄚ ㄎㄜ ㄎㄞ ㄎㄟ ㄎㄠ ㄎㄡ ㄎㄢ ㄎㄣ ㄎㄤ ㄎㄥ ㄎㄨ ㄎㄨㄚ ㄎㄨㄛ ㄎㄨㄞ ㄎㄨㄟ ㄎㄨㄢ ㄎㄨㄣ ㄎㄨㄤ ㄎㄨㄥ
ㄏㄚ ㄏㄜ ㄏㄞ ㄏㄟ ㄏㄠ ㄏㄡ ㄏㄢ ㄏㄣ ㄏㄤ ㄏㄥ ㄏㄨ ㄏㄨㄚ ㄏㄨㄛ ㄏㄨㄞ ㄏㄨㄟ ㄏㄨㄢ ㄏㄨㄣ ㄏㄨㄤ ㄏㄨㄥ
ㄐㄧ ㄐㄧㄚ ㄐㄧㄝ ㄐㄧㄠ ㄐㄧㄡ ㄐㄧㄢ ㄐㄧㄣ ㄐㄧㄤ ㄐㄧㄥ ㄐㄩ ㄐㄩㄝ ㄐㄩㄢ ㄐㄩㄣ ㄐㄩㄥ
ㄑㄧ ㄑㄧㄚ ㄑㄧㄝ ㄑㄧㄠ ㄑㄧㄡ ㄑㄧㄢ ㄑㄧㄣ ㄑㄧㄤ ㄑㄧㄥ ㄑㄩ ㄑㄩㄝ ㄑㄩㄢ ㄑㄩㄣ ㄑㄩㄥ
ㄒㄧ ㄒㄧㄚ ㄒㄧㄝ ㄒㄧㄠ ㄒㄧㄡ ㄒㄧㄢ ㄒㄧㄣ ㄒㄧㄤ ㄒㄧㄥ ㄒㄩ ㄒㄩㄝ ㄒㄩㄢ ㄒㄩㄣ ㄒㄩㄥ
ㄓ ㄓㄚ ㄓㄜ ㄓㄞ ㄓㄟ ㄓㄠ ㄓㄡ ㄓㄢ ㄓㄣ ㄓㄤ ㄓㄥ ㄓㄨ ㄓㄨㄚ ㄓㄨㄛ ㄓㄨㄞ ㄓㄨㄟ ㄓㄨㄢ ㄓㄨㄣ ㄓㄨㄤ ㄓㄨㄥ
ㄔ ㄔㄚ ㄔㄜ ㄔㄞ ㄔㄠ ㄔㄡ ㄔㄢ ㄔㄣ ㄔㄤ ㄔㄥ ㄔㄨ ㄔㄨㄚ ㄔㄨㄛ ㄔㄨㄞ ㄔㄨㄟ ㄔㄨㄢ ㄔㄨㄣ ㄔㄨㄤ ㄔㄨㄥ
ㄕ ㄕㄚ ㄕㄜ ㄕㄞ ㄕㄟ ㄕㄠ ㄕㄡ ㄕㄢ ㄕㄣ ㄕㄤ ㄕㄥ ㄕㄨ ㄕㄨㄚ ㄕㄨㄛ ㄕㄨㄞ ㄕㄨㄟ ㄕㄨㄢ ㄕㄨㄣ ㄕㄨㄤ
ㄖ ㄖㄜ ㄖㄠ ㄖㄡ ㄖㄢ ㄖㄣ ㄖㄤ ㄖㄥ ㄖㄨ ㄖㄨㄛ ㄖㄨㄟ ㄖㄨㄢ ㄖㄨㄣ ㄖㄨㄥ
ㄗ ㄗㄚ ㄗㄜ ㄗㄞ ㄗㄟ ㄗㄠ ㄗㄡ ㄗㄢ ㄗㄣ ㄗㄤ ㄗㄥ ㄗㄨ ㄗㄨㄛ ㄗㄨㄟ ㄗㄨㄢ ㄗㄨㄣ ㄗㄨㄥ
ㄘ ㄘㄚ ㄘㄜ ㄘㄞ ㄘㄠ ㄘㄡ ㄘㄢ ㄘㄣ ㄘㄤ ㄘㄥ ㄘㄨ ㄘㄨㄛ ㄘㄨㄟ ㄘㄨㄢ ㄘㄨㄣ ㄘㄨㄥ
ㄙ ㄙㄚ ㄙㄜ ㄙㄞ ㄙㄠ ㄙㄡ ㄙㄢ ㄙㄣ ㄙㄤ ㄙㄥ ㄙㄨ ㄙㄨㄛ ㄙㄨㄟ ㄙㄨㄢ ㄙㄨㄣ ㄙㄨㄥ
"""

    val VALID: Set<String> = RAW.split(Regex("\\s+")).filter { it.isNotEmpty() }.toSet()
    private val VALID_PREFIXES: Set<String> =
        VALID.flatMapTo(HashSet()) { syl -> (1..syl.length).map { syl.substring(0, it) } }

    /** Slot patterns ("ㄒ_ㄠ") that some valid syllable fits; used for out-of-order typing. */
    private val COMPATIBLE: Set<String> = HashSet<String>().also { out ->
        for (syl in VALID) {
            val slots = arrayOfNulls<String>(3)
            for (ch in syl) slots[slotOf(ch.toString())] = ch.toString()
            for (mask in 0 until 8) {
                out.add((0 until 3).joinToString("") { i ->
                    if (mask and (1 shl i) != 0) (slots[i] ?: "_") else "_"
                })
            }
        }
    }

    fun isValid(syl: Syllable): Boolean = syl.toneless in VALID

    fun isValidPrefix(syl: Syllable): Boolean = syl.isEmpty || syl.toneless in VALID_PREFIXES

    fun isCompatible(syl: Syllable): Boolean = syl.slots.joinToString("") { it ?: "_" } in COMPATIBLE

    // --- parser ---

    /** Splits keystrokes into syllables (Dachen rules, out-of-order symbols merged). */
    fun parse(keys: List<String>): ZhuyinParse {
        val result = ZhuyinParse()
        var current = Syllable()
        var start = 0
        var reordered = false

        fun close(end: Int) {
            if (!current.isEmpty) result.syllables.add(ParsedSyllable(current, start, end, reordered))
            current = Syllable()
            start = end
            reordered = false
        }

        for ((i, key) in keys.withIndex()) {
            val tone = TONES[key]
            val symbol = SYMBOLS[key]
            if (tone != null) {
                if (current.isEmpty) {
                    result.strayTones += 1
                    start = i + 1
                } else {
                    val prev = result.syllables.lastOrNull()
                    if (prev != null && prev.end == start && !prev.toned && !isValid(current)) {
                        // Typed over the untoned syllable before it to fix a typo: ㄌㄨㄥ then ㄏ
                        // and a tone is ㄏㄨㄥ, not ㄌㄨㄥ + ㄏ (which is no syllable).
                        val merged = prev.syllable.copy()
                        for (s in 0 until 3) current.slots[s]?.let { merged.slots[s] = it }
                        if (isValid(merged)) {
                            result.syllables.removeAt(result.syllables.size - 1)
                            current = merged
                            start = prev.start
                            reordered = true
                        }
                    }
                    current.tone = tone
                    close(i + 1)
                }
            } else if (symbol != null) {
                val slot = slotOf(symbol)
                val laterFilled = (slot + 1 until 3).any { current.slots[it] != null }
                if (current.slots[slot] != null) {
                    close(i)
                } else if (laterFilled) {
                    val merged = current.copy()
                    merged.slots[slot] = symbol
                    if (isCompatible(merged)) reordered = true else close(i)
                }
                if (current.isEmpty) start = i
                current.slots[slot] = symbol
            } else {
                close(i)
                result.foreignKeys += 1
                start = i + 1
            }
        }
        close(keys.size)
        return result
    }
}

class Syllable(slots: Array<String?>? = null, var tone: Int? = null) {
    val slots: Array<String?> = slots?.copyOf() ?: arrayOfNulls(3)

    fun copy() = Syllable(slots, tone)

    val isEmpty: Boolean get() = slots.all { it == null }

    val toneless: String get() = slots.filterNotNull().joinToString("")

    val reading: String get() = toneless + (tone?.let { Bopomofo.TONE_MARKS[it] } ?: "")

    override fun equals(other: Any?) =
        other is Syllable && slots.contentEquals(other.slots) && tone == other.tone

    override fun hashCode() = slots.contentHashCode() * 31 + (tone ?: 0)

    override fun toString() = "Syllable($reading)"
}

class ParsedSyllable(val syllable: Syllable, val start: Int, val end: Int, val reordered: Boolean = false) {
    val toned: Boolean get() = syllable.tone != null
}

class ZhuyinParse {
    val syllables = mutableListOf<ParsedSyllable>()
    var strayTones = 0
    var foreignKeys = 0

    val pending: ParsedSyllable?
        get() = syllables.lastOrNull()?.takeIf { !it.toned }

    val completed: List<ParsedSyllable>
        get() = if (pending == null) syllables else syllables.subList(0, syllables.size - 1)
}
