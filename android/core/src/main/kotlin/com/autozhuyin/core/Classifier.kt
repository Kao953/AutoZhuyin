package com.autozhuyin.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

enum class Mode(val id: String) {
    ZHUYIN("zhuyin"), LITERAL("literal");

    val other: Mode get() = if (this == ZHUYIN) LITERAL else ZHUYIN
}

/** Keys [start, end) shown in one mode. */
data class Segment(val start: Int, val end: Int, val mode: Mode)

/** Per key-sequence corrections. Positive weight = prefers Zhuyin. */
class LearnedPreferences(weights: Map<String, Int> = emptyMap(), var onChange: (Map<String, Int>) -> Unit = {}) {
    val weights = LinkedHashMap(weights)

    fun record(keys: String, mode: Mode) {
        val delta = if (mode == Mode.ZHUYIN) 1 else -1
        val old = weights[keys] ?: 0
        // A correction against what was learned replaces it, so one Tab is enough to undo it.
        weights[keys] = if (old * delta < 0) delta else (old + delta).coerceIn(-3, 3)
        onChange(weights)
    }

    fun clear() {
        weights.clear()
        onChange(weights)
    }

    fun bias(keys: String): Double = (weights[keys] ?: 0) * 4.0
}

/** Zhuyin-vs-literal classifier. Port of windows/autozhuyin/core/classifier.py (Swift: Classifier.swift). */
class Classifier(
    val lexicon: Lexicon,
    val english: EnglishModel,
    val learned: LearnedPreferences = LearnedPreferences(),
    weights: Map<String, Double> = emptyMap(),
    val history: UserHistory = UserHistory(),   // picked candidates (shared by all engines)
) {
    val weights: Map<String, Double> = LinkedHashMap(Features.DEFAULT_WEIGHTS).apply { putAll(weights) }

    /** (zhuyin features or null, literal features or null) for one segment. */
    fun segmentFeatures(
        seg: List<String>, isLast: Boolean, afterOther: Boolean, finishing: Boolean, previous: Mode? = null,
    ): Pair<Map<String, Double>?, Map<String, Double>?> =
        Features.zhuyin(seg, lexicon, isLast, afterOther, finishing, previous) to
            Features.literal(seg, english, isLast, afterOther, finishing, previous)

    private fun scores(
        seg: List<String>, isLast: Boolean, afterOther: Boolean, finishing: Boolean, previous: Mode?,
        whole: Boolean, weights: Map<String, Double>,
    ): DoubleArray {
        val (fz, fl) = segmentFeatures(seg, isLast, afterOther, finishing, previous)
        var zh = if (fz != null) Features.dot(weights, fz) else NEG_INF
        var lit = if (fl != null) Features.dot(weights, fl) else NEG_INF
        if (whole) {
            val b = learned.bias(seg.joinToString(""))
            if (b > 0) zh += b else lit -= b
        }
        return doubleArrayOf(zh, lit)
    }

    /** Whole buffer as one segment. */
    fun mode(keys: List<String>, finishing: Boolean = false, previous: Mode? = null): Mode {
        val s = scores(keys, true, false, finishing, previous, true, weights)
        return if (s[0] >= s[1]) Mode.ZHUYIN else Mode.LITERAL
    }

    /**
     * Splits keys into alternating segments, e.g. "ji3hello" -> [(0, 3, zhuyin), (3, 8, literal)].
     * Dynamic programming over split points; each segment is scored by features x weights.
     */
    fun segment(keys: List<String>, finishing: Boolean = false, previous: Mode? = null): List<Segment> {
        val n = keys.size
        if (n == 0) return emptyList()
        val modes = arrayOf(Mode.ZHUYIN, Mode.LITERAL)
        val best = Array(n + 1) { doubleArrayOf(NEG_INF, NEG_INF) }
        val back = Array(n + 1) { intArrayOf(-1, -1) }
        for (i in 1..n) {
            for (j in 0 until i) {
                val s = scores(keys.subList(j, i), i == n, j > 0, finishing,
                    if (j == 0) previous else null, j == 0 && i == n, weights)
                for (m in 0..1) {
                    if (s[m] == NEG_INF) continue
                    val total = if (j == 0) {
                        s[m]
                    } else {
                        if (best[j][1 - m] == NEG_INF) continue
                        best[j][1 - m] + s[m]
                    }
                    if (total > best[i][m]) {
                        best[i][m] = total
                        back[i][m] = j
                    }
                }
            }
        }
        if (best[n][0] == NEG_INF && best[n][1] == NEG_INF) return listOf(Segment(0, n, mode(keys, finishing, previous)))
        var m = if (best[n][0] >= best[n][1]) 0 else 1
        val out = ArrayList<Segment>()
        var i = n
        while (i > 0) {
            val j = back[i][m]
            out.add(Segment(j, i, modes[m]))
            i = j
            m = 1 - m
        }
        out.reverse()
        return out
    }

    companion object {
        const val NEG_INF = Double.NEGATIVE_INFINITY

        /** Reads a weights file ({"weights": {...}}, Resources/classifier-weights.json); {} if unreadable. */
        fun parseWeights(text: String?): Map<String, Double> {
            if (text == null) return emptyMap()
            return try {
                Json.parseToJsonElement(text).jsonObject["weights"]?.jsonObject
                    ?.mapValues { it.value.jsonPrimitive.double } ?: emptyMap()
            } catch (e: Exception) {
                emptyMap()
            }
        }
    }
}
