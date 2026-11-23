package com.autozhuyin.core

/**
 * Segment features for the Zhuyin / literal classifier.
 *
 * Port of windows/autozhuyin/core/features.py (Swift: Features.swift). All three must
 * produce identical features: the tests check segmentations against
 * training/parity-fixtures.json. Maps keep insertion order, so dot products add up in
 * the same order as in Python and ties break the same way.
 */
object Features {
    val DEFAULT_WEIGHTS: Map<String, Double> = linkedMapOf(
        // Zhuyin
        "zh.bias" to 0.5,
        "zh.stray" to -5.0,
        "zh.reordered" to -0.5,
        "zh.toned_valid_lex" to 2.8,
        "zh.toned_valid_nolex" to 0.5,
        "zh.toned_invalid" to -5.0,
        "zh.pending_prefix" to 0.0,
        "zh.pending_invalid" to -5.0,
        "zh.untoned_mid_valid" to -2.5,
        "zh.untoned_mid_invalid" to -5.0,
        "zh.unconfirmed" to -2.0,
        "zh.lexscore" to 0.0,
        "zh.phrase" to 0.0,
        // Literal
        "lit.bias" to 0.0,
        "lit.upper" to 20.0,
        "lit.num_digits" to 0.8,
        "lit.num_others" to -1.0,
        "lit.common" to 3.0,
        "lit.common_len" to 1.0,
        "lit.dict" to 1.0,
        "lit.dict_len" to 0.6,
        "lit.prefix_common_len" to 0.4,
        "lit.prefix_dict_len" to 0.2,
        "lit.unknown_score" to 1.0,
        "lit.short" to 0.0,
        "lit.digits" to -1.5,
        "lit.others" to -1.5,
        // Segmentation
        "seg.switch" to -3.0,
        // Context: the first segment has the same mode as the previously committed text
        "ctx.zh" to 1.5,
        "ctx.lit" to 1.5,
    )

    fun dot(weights: Map<String, Double>, feats: Map<String, Double>): Double {
        var sum = 0.0
        for ((k, v) in feats) sum += (weights[k] ?: 0.0) * v
        return sum
    }

    private fun MutableMap<String, Double>.add(k: String, v: Double = 1.0) {
        this[k] = (this[k] ?: 0.0) + v
    }

    /** Features of `keys` read as Zhuyin, or null if impossible. */
    fun zhuyin(
        keys: List<String>, lexicon: Lexicon, isLast: Boolean = true, afterOther: Boolean = false,
        finishing: Boolean = false, previous: Mode? = null,
    ): Map<String, Double>? {
        val parse = Bopomofo.parse(keys)
        if (!isLast && parse.pending != null) return null   // a Zhuyin segment followed by another must end with a tone
        // Pressing space finishes an untoned last syllable as first tone; after a toned
        // syllable it just commits, so it must not count as an extra (stray) tone.
        val scored = if (finishing && isLast && parse.pending != null) Bopomofo.parse(keys + " ") else parse
        if (scored.foreignKeys > 0 || scored.syllables.isEmpty()) return null
        val f = linkedMapOf("zh.bias" to 1.0)
        if (scored.strayTones != 0) f.add("zh.stray", scored.strayTones.toDouble())
        val last = scored.syllables.size - 1
        val tonedRun = ArrayList<Syllable>()
        for ((i, ps) in scored.syllables.withIndex()) {
            if (ps.reordered) f.add("zh.reordered")
            val valid = Bopomofo.isValid(ps.syllable)
            if (ps.toned) {
                if (valid) {
                    val best = lexicon.bestScore(ps.syllable)
                    if (best != null) {
                        f.add("zh.toned_valid_lex")
                        f.add("zh.lexscore", best + 4.0)
                    } else {
                        f.add("zh.toned_valid_nolex")
                    }
                    tonedRun.add(ps.syllable)
                } else {
                    f.add("zh.toned_invalid")
                }
            } else if (i == last) {
                f.add(if (Bopomofo.isValidPrefix(ps.syllable)) "zh.pending_prefix" else "zh.pending_invalid")
            } else {
                f.add(if (valid) "zh.untoned_mid_valid" else "zh.untoned_mid_invalid")
            }
        }
        // Syllables covered by a multi-syllable lexicon phrase (real Chinese forms words).
        val covered = BooleanArray(tonedRun.size)
        for (i in tonedRun.indices) {
            for (n in 2..4) {
                if (i + n <= tonedRun.size && lexicon.entries(tonedRun.subList(i, i + n)).isNotEmpty()) {
                    for (k in i until i + n) covered[k] = true
                }
            }
        }
        if (covered.any { it }) f.add("zh.phrase", covered.count { it }.toDouble())
        if (isLast && afterOther && !finishing && parse.syllables.none { it.toned }) f.add("zh.unconfirmed")
        if (afterOther) f.add("seg.switch") else if (previous == Mode.ZHUYIN) f.add("ctx.zh")
        return f
    }

    /** Features of `keys` output as typed, or null if impossible. */
    fun literal(
        keys: List<String>, english: EnglishModel, isLast: Boolean = true, afterOther: Boolean = false,
        finishing: Boolean = false, previous: Mode? = null,
    ): Map<String, Double>? {
        if (keys.isEmpty() || " " in keys) return null
        val complete = !isLast || finishing
        val f = linkedMapOf("lit.bias" to 1.0)
        if (afterOther) f.add("seg.switch") else if (previous == Mode.LITERAL) f.add("ctx.lit")
        val text = keys.joinToString("")
        if (text.any { it.isUpperCase() }) f.add("lit.upper")
        val letters = text.filter { it.isLetter() }
        val digits = text.count { it.isDigit() }
        val others = text.length - letters.length - digits
        if (letters.isEmpty()) {
            if (digits != 0) f.add("lit.num_digits", digits.toDouble())
            if (others != 0) f.add("lit.num_others", others.toDouble())
            return f
        }
        for ((k, v) in english.wordFeatures(letters, complete || digits > 0)) f.add(k, v)
        if (digits != 0) f.add("lit.digits", digits.toDouble())
        val nonApostrophe = others - text.count { it == '\'' }
        if (nonApostrophe != 0) f.add("lit.others", nonApostrophe.toDouble())
        return f
    }
}
