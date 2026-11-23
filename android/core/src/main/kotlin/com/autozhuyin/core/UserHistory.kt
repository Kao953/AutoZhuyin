package com.autozhuyin.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Remembers the candidates the user picked. Port of windows/autozhuyin/core/history.py.
 *
 * Keys are toneless readings ("ㄊㄧㄢ", "ㄐㄧㄣ-ㄊㄧㄢ"); a picked phrase is boosted only
 * where the lexicon has it for the reading being converted, so a toneless key is safe.
 * Stored as JSON: {reading: {phrase: [count, last use]}}, same as the desktop versions.
 */
class UserHistory(data: Map<String, Map<String, IntArray>> = emptyMap(), var onChange: (UserHistory) -> Unit = {}) {
    var maxEntries = 2000   // (reading, phrase) pairs kept; the least recently used go first
    val data = LinkedHashMap<String, LinkedHashMap<String, IntArray>>()
    private var clock = 0

    init {
        for ((reading, phrases) in data) {
            for ((phrase, v) in phrases) {
                if (v.size < 2) continue
                this.data.getOrPut(reading) { LinkedHashMap() }[phrase] = intArrayOf(v[0], v[1])
                clock = maxOf(clock, v[1])
            }
        }
    }

    fun record(syllables: List<Syllable>, phrase: String) {
        if (syllables.isEmpty() || phrase.isEmpty()) return
        clock += 1
        val entry = data.getOrPut(key(syllables)) { LinkedHashMap() }.getOrPut(phrase) { intArrayOf(0, 0) }
        entry[0] = minOf(MAX_COUNT, entry[0] + 1)
        entry[1] = clock
        evict()
        onChange(this)
    }

    private fun evict() {
        val pairs = data.flatMap { (r, ps) -> ps.map { (p, v) -> Triple(v[1], r, p) } }
        if (pairs.size <= maxEntries) return
        val sorted = pairs.sortedWith(compareBy<Triple<Int, String, String>> { it.first }.thenBy { it.second }.thenBy { it.third })
        for ((_, r, p) in sorted.take(pairs.size - maxEntries)) {
            data[r]?.remove(p)
            if (data[r].isNullOrEmpty()) data.remove(r)
        }
    }

    fun clear() {
        data.clear()
        onChange(this)
    }

    /** Entries with picked phrases moved to the top: just above the best entry, more so the more often they were picked. */
    fun adjust(syllables: List<Syllable>, entries: List<Entry>): List<Entry> {
        val picked = data[key(syllables)]
        if (picked.isNullOrEmpty() || entries.isEmpty()) return entries
        val top = entries[0].score
        return entries.map { e ->
            val p = picked[e.phrase]
            if (p != null) Entry(e.phrase, maxOf(e.score, top + 0.01 + 0.1 * p[0])) else e
        }.sortedByDescending { it.score }
    }

    fun toJson(): String = JsonObject(data.mapValues { (_, ps) ->
        JsonObject(ps.mapValues { (_, v) -> JsonArray(listOf(JsonPrimitive(v[0]), JsonPrimitive(v[1]))) })
    }).toString()

    companion object {
        const val MAX_COUNT = 10

        fun key(syllables: List<Syllable>) = syllables.joinToString("-") { it.toneless }

        /** Parses saved JSON; bad entries are skipped. */
        fun parse(text: String?): Map<String, Map<String, IntArray>> {
            val out = LinkedHashMap<String, Map<String, IntArray>>()
            val obj = try {
                Json.parseToJsonElement(text ?: return out).jsonObject
            } catch (e: Exception) {
                return out
            }
            for ((reading, phrases) in obj) {
                val m = LinkedHashMap<String, IntArray>()
                val po = phrases as? JsonObject ?: continue
                for ((phrase, v) in po) {
                    try {
                        val a = v.jsonArray
                        m[phrase] = intArrayOf(a[0].jsonPrimitive.int, a[1].jsonPrimitive.int)
                    } catch (e: Exception) {
                        continue
                    }
                }
                out[reading] = m
            }
            return out
        }
    }
}
