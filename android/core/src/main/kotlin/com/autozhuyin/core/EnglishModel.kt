package com.autozhuyin.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** Letter-bigram table: log2 probabilities by two-character key ("^a", "th", "e$"). */
class Bigram(val table: Map<String, Double>, val unseen: Double) {
    companion object {
        /** Reads data/english-bigram.json (windows/tools/build_data.py). */
        fun fromJson(text: String): Bigram {
            val obj = Json.parseToJsonElement(text).jsonObject
            val table = obj.getValue("table").jsonObject.mapValues { it.value.jsonPrimitive.double }
            return Bigram(table, obj.getValue("unseen").jsonPrimitive.double)
        }

        fun train(words: List<String>, common: Set<String>): Bigram {
            val pair = LinkedHashMap<String, Double>()
            val first = LinkedHashMap<Char, Double>()
            for (w in words) {
                if (w.isEmpty() || !w.all { it in 'a'..'z' || it in 'A'..'Z' }) continue
                val weight = if (w in common) 5.0 else 1.0
                val chars = "^$w$"
                for (i in 1 until chars.length) {
                    val k = chars.substring(i - 1, i + 1)
                    pair[k] = (pair[k] ?: 0.0) + weight
                    first[chars[i - 1]] = (first[chars[i - 1]] ?: 0.0) + weight
                }
            }
            val table = pair.mapValues { (k, c) -> log2((c + 1) / ((first[k[0]] ?: 0.0) + 27)) }
            val unseen = log2(1.0 / ((first.values.maxOrNull() ?: 1000.0) + 27))
            return Bigram(table, unseen)
        }

        private fun log2(x: Double) = ln(x) / ln(2.0)
    }
}

/**
 * English-likeness scoring. Port of windows/autozhuyin/core/english.py (Swift: EnglishModel.swift).
 * Android has no system word list, so the dictionary ships as data/english-dict.txt.
 */
class EnglishModel(commonWords: Collection<String>, dictionaryWords: Collection<String> = emptyList(), bigram: Bigram? = null) {
    val common: Set<String> = commonWords.filter { it.isNotEmpty() }.mapTo(HashSet()) { it.lowercase() }
    val dictionary: Set<String> = dictionaryWords.filter { it.length > 2 }.mapTo(HashSet()) { it.lowercase() }
    private val sortedCommon: List<String> = common.sorted()
    private val sortedWords: List<String> = (common + dictionary).sorted()
    private val bigram: Bigram = bigram ?: Bigram.train(sortedWords, common)

    fun isCommon(w: String) = w.lowercase() in common

    /** Feature map for the classifier (see Features.kt). */
    fun wordFeatures(word: String, complete: Boolean): LinkedHashMap<String, Double> {
        val w = word.lowercase()
        val n = w.length.toDouble()
        val f = LinkedHashMap<String, Double>()
        if (n <= 2) f["lit.short"] = 1.0
        if (w in common) {
            f["lit.common"] = 1.0
            f["lit.common_len"] = n
        } else if (w in dictionary) {
            f["lit.dict"] = 1.0
            f["lit.dict_len"] = n
        } else if (!complete && hasPrefix(w, sortedCommon)) {
            f["lit.prefix_common_len"] = n
        } else if (!complete && hasPrefix(w, sortedWords)) {
            f["lit.prefix_dict_len"] = n
        } else {
            val plaus = plausibility(w)
            f["lit.unknown_score"] = min(0.5 * n, max(-2 * n, n * (plaus + 4.2)))
        }
        return f
    }

    fun plausibility(w: String): Double {
        val chars = "^$w$"
        var total = 0.0
        for (i in 1 until chars.length) total += bigram.table[chars.substring(i - 1, i + 1)] ?: bigram.unseen
        return total / (chars.length - 1)
    }

    companion object {
        fun readWords(text: String): List<String> =
            text.lineSequence().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.toList()

        /** True if some word strictly longer than p starts with p. */
        internal fun hasPrefix(p: String, words: List<String>): Boolean {
            var lo = lowerBound(words, p)
            if (lo < words.size && words[lo] == p) lo += 1
            return lo < words.size && words[lo].startsWith(p)
        }

        private fun lowerBound(words: List<String>, p: String): Int {
            var lo = 0
            var hi = words.size
            while (lo < hi) {
                val mid = (lo + hi) ushr 1
                if (words[mid] < p) lo = mid + 1 else hi = mid
            }
            return lo
        }
    }
}
