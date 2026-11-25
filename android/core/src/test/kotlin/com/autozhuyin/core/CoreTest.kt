package com.autozhuyin.core

import com.autozhuyin.core.CompositionEngine.Companion.BACKSPACE
import com.autozhuyin.core.CompositionEngine.Companion.DOWN
import com.autozhuyin.core.CompositionEngine.Companion.ENTER
import com.autozhuyin.core.CompositionEngine.Companion.ESCAPE
import com.autozhuyin.core.CompositionEngine.Companion.LEFT
import com.autozhuyin.core.CompositionEngine.Companion.RIGHT
import com.autozhuyin.core.CompositionEngine.Companion.SHIFT_TAP
import com.autozhuyin.core.CompositionEngine.Companion.TAB
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Mirror of windows/tests/test_core.py (and the Swift tests). Needs the shared data:
 *   python3 windows/tools/build_data.py
 */
object Data {
    val dir = File(System.getProperty("autozhuyin.data") ?: "../../windows/autozhuyin/data")
    private fun file(name: String) = File(dir, name).also {
        require(it.exists()) { "$it missing: run python3 windows/tools/build_data.py" }
    }

    val loadSeconds: Double
    val lex: Lexicon
    val eng: EnglishModel
    val weights: Map<String, Double>

    init {
        val start = System.nanoTime()
        lex = file("lexicon.txt").reader().use { Lexicon.from(it) }
        eng = EnglishModel(
            EnglishModel.readWords(file("english-common.txt").readText()),
            EnglishModel.readWords(file("english-dict.txt").readText()),
            Bigram.fromJson(file("english-bigram.json").readText()),
        )
        weights = Classifier.parseWeights(file("classifier-weights.json").readText())
        loadSeconds = (System.nanoTime() - start) / 1e9
    }
}

private val LEX get() = Data.lex
private val ENG get() = Data.eng
private val WEIGHTS get() = Data.weights

private fun keysOf(s: String) = s.map { it.toString() }

private fun readings(keys: String) = Bopomofo.parse(keysOf(keys)).syllables.map { it.syllable.reading }

private fun convert(keys: String): String {
    val syl = Bopomofo.parse(keysOf(keys)).syllables.map { it.syllable }
    return Converter(LEX).convert(syl).joinToString("") { it.text }
}

private fun makeEngine() = CompositionEngine(Classifier(LEX, ENG, weights = WEIGHTS))

private val SPECIAL = mapOf(
    '\n' to ENTER, '\t' to TAB, '⇧' to SHIFT_TAP, '←' to LEFT, '→' to RIGHT, '↓' to DOWN,
    '\b' to BACKSPACE, '\u001b' to ESCAPE,
)

private fun typeKeys(s: String, e: CompositionEngine): String {
    val out = StringBuilder()
    for (c in s) {
        val r = e.handle(SPECIAL[c] ?: c.toString())
        if (r.commit != null) out.append(r.commit) else if (!r.handled) out.append(c)
    }
    return out.toString()
}

private fun CompositionEngine.candidateTexts() = candidates.map { it.text }

class ParserTests {
    @Test fun niHao() = assertEquals(listOf("ㄋㄧˇ", "ㄏㄠˇ"), readings("su3cl3"))

    @Test fun spaceIsFirstTone() = assertEquals(listOf("ㄊㄧㄢ"), readings("wu0 "))

    @Test fun pending() {
        val p = Bopomofo.parse(keysOf("su3c"))
        assertEquals(1, p.completed.size)
        assertEquals("ㄏ", p.pending!!.syllable.reading)
    }

    @Test fun outOfOrder() {
        for (keys in listOf("uvl3", "vlu3", "ulv3")) {
            val p = Bopomofo.parse(keysOf(keys))
            assertEquals(listOf("ㄒㄧㄠˇ"), p.syllables.map { it.syllable.reading }, keys)
            assertTrue(p.syllables[0].reordered)
        }
        assertFalse(Bopomofo.parse(keysOf("vul3")).syllables[0].reordered)
        assertEquals(2, Bopomofo.parse(keysOf("me")).syllables.size)
    }
}

/** An initial typed again before the tone replaces the one before: ㄌㄨㄥ ㄏ ˊ = ㄏㄨㄥˊ. */
class TypedOverTests {
    @Test fun typedOver() {
        assertEquals(listOf("ㄏㄨㄥ"), readings("xj/c "))
        assertEquals(listOf("ㄋㄧˇ", "ㄏㄨㄥˊ"), readings("su3xj/c6"))
        assertTrue(Bopomofo.parse(keysOf("xj/c ")).syllables[0].reordered)
        // Only when the symbol alone is no syllable: these stay as they were.
        assertEquals(listOf("ㄌㄨㄥ", "ㄏㄨˇ"), readings("xj/cj3"))
        assertEquals(listOf("ㄓㄜ", "ㄕˋ"), readings("5kg4"))     // 這是, first tone omitted
        assertEquals(listOf("ㄌㄨㄥ", "ㄏ"), readings("xj/ c "))   // the first one had its tone
        assertEquals(listOf("ㄌㄨㄥ", "ㄒ"), readings("xj/v "))     // ㄒㄨㄥ is no syllable either
    }

    /** The Bopomofo itself comes last among the candidates. */
    @Test fun bopomofoCandidates() {
        val e = makeEngine()
        typeKeys(";6↓", e)
        val texts = e.candidateTexts()
        assertEquals(listOf("ㄤ", "ㄤˊ"), texts.takeLast(2))
        e.selectCandidate(texts.size - 1)
        assertEquals("ㄤˊ", typeKeys("\n", e))
        val first = makeEngine()
        typeKeys("ji3/ ↓", first)
        assertEquals(1, first.candidateTexts().count { it == "ㄥ" })   // first tone: no mark, once
    }
}

/** 要打聲調才出字: every syllable has its tone, so anything typed over an untoned one corrects it. */
class StrictTypedOverTests {
    private fun strict(keys: String) = Bopomofo.parse(keysOf(keys), strict = true).syllables.map { it.syllable.reading }

    @Test fun medialsAndFinalsReplace() {
        assertEquals(listOf("ㄒㄩㄥˊ"), strict("vu/m6"))             // ㄒㄧㄥ, ㄩ over ㄧ
        assertEquals(listOf("ㄒㄧㄥ", "ㄩˊ"), readings("vu/m6"))      // not strict: 一 五 於 can be syllables
        assertEquals(listOf("ㄏㄨㄤ"), strict("cj/; "))              // ㄏㄨㄥ, ㄤ over ㄥ
        assertEquals(listOf("ㄏㄨㄥˇ"), strict("xj/cj/3"))           // the whole syllable typed again
        assertEquals(listOf("ㄤˊ"), strict("/;6"))
    }

    @Test fun tonedSyllablesStay() {
        assertEquals(listOf("ㄨㄢˋ", "ㄧ"), strict("j04u "))          // 萬一 with its tones
        assertEquals(listOf("ㄌㄨㄥ", "ㄒ"), strict("xj/v "))          // ㄒㄨㄥ is no syllable: kept apart
    }

    @Test fun engine() {
        fun type(keys: String) = CompositionEngine(Classifier(LEX, ENG, weights = WEIGHTS))
            .apply { converter.requireTones = true }.let { typeKeys(keys, it) }
        assertEquals("雄", type("vu/m6\n"))
        assertEquals("你雄", type("su3vu/m6\n"))
        assertEquals("萬一", type("j04u \n"))
        assertEquals(2, typeKeys("vu/m6\n", makeEngine()).length)   // not strict: two characters, as before
    }
}

class ConverterTests {
    @Test fun phrase() = assertEquals("你好", convert("su3cl3"))

    @Test fun sentence() = assertEquals("今天天氣很好", convert("rup wu0 wu0 fu4cp3cl3"))

    @Test fun toneOmission() = assertEquals("我們", convert("jiap7"))

    @Test fun requireTones() {
        val c = Converter(LEX).apply { requireTones = true }
        fun conv(keys: String) = c.convert(Bopomofo.parse(keysOf(keys)).syllables.map { it.syllable }).joinToString("") { it.text }
        assertEquals("ㄨㄛ們", conv("jiap7"))
        assertEquals("我們", conv("ji3ap7"))
        val untoned = Bopomofo.parse(keysOf("ji")).syllables.map { it.syllable }
        assertEquals(listOf("ㄨㄛ"), c.candidates(untoned, 1).map { it.text })   // only the Bopomofo
    }

    @Test fun loadTime() {
        Data.lex.toneless
        System.gc()
        val rt = Runtime.getRuntime()
        println("lexicon + english load: %.2fs, heap in use: %d MB".format(Data.loadSeconds, (rt.totalMemory() - rt.freeMemory()) shr 20))
        assertTrue(Data.loadSeconds < 10)
    }
}

class ClassifierTests {
    private val c = Classifier(LEX, ENG, weights = WEIGHTS)

    @Test fun zhuyin() {
        for (s in listOf("su3cl3", "ji3", "cl3", "ru ", "u ", "fu ", "183", "2k7", "5j/ ")) {
            assertEquals(Mode.ZHUYIN, c.mode(keysOf(s)), s)
        }
        for (s in listOf("ru", "ji", "fu")) assertEquals(Mode.ZHUYIN, c.mode(keysOf(s), finishing = true), s)
    }

    @Test fun english() {
        for (s in listOf("hello", "the", "is", "ok", "github", "Swift", "2024", "so", "go", "me",
            "no", "a", "an", "up", "i", "meeting", "email", "push")) {
            assertEquals(Mode.LITERAL, c.mode(keysOf(s), finishing = true), s)
        }
    }

    @Test fun learning() {
        val learned = LearnedPreferences()
        val c = Classifier(LEX, ENG, learned, WEIGHTS)
        assertEquals(Mode.LITERAL, c.mode(keysOf("so"), finishing = true))
        learned.record("so", Mode.ZHUYIN)
        assertEquals(Mode.ZHUYIN, c.mode(keysOf("so"), finishing = true))
    }
}

/** Segmentations must match the Python core (training/make_parity.py). */
class ParityTests {
    @Test fun matchesPython() {
        val path = File(System.getProperty("autozhuyin.parity") ?: "../../training/parity-fixtures.json")
        val fixtures = Json.parseToJsonElement(path.readText()).jsonArray
        val c = Classifier(LEX, ENG, weights = WEIGHTS)
        val failures = ArrayList<String>()
        for (f in fixtures) {
            val o = f.jsonObject
            val keys = o.getValue("keys").jsonPrimitive.content
            val finishing = o.getValue("finishing").jsonPrimitive.boolean
            val prev = o.getValue("previous").let { if (it is JsonNull) null else it.jsonPrimitive.content }
            val want = o.getValue("segments").jsonArray.map {
                val a = it.jsonArray
                Triple(a[0].jsonPrimitive.int, a[1].jsonPrimitive.int, a[2].jsonPrimitive.content)
            }
            val got = c.segment(keysOf(keys), finishing, Mode.entries.firstOrNull { it.id == prev })
                .map { Triple(it.start, it.end, it.mode.id) }
            if (got != want) failures += "'$keys' finishing=$finishing previous=$prev: want $want, got $got"
        }
        assertTrue(failures.isEmpty(), "${failures.size}/${fixtures.size} differ:\n" + failures.take(20).joinToString("\n"))
    }
}

class EngineTests {
    @Test fun mixedSentence() = assertEquals("我hello world 你好", typeKeys("ji3 hello world su3cl3 ", makeEngine()))

    @Test fun markedText() {
        val e = makeEngine()
        typeKeys("su3c", e)
        assertEquals("你ㄏ", e.markedText)
        typeKeys("l3", e)
        assertEquals("你好", e.markedText)
    }

    @Test fun enterCommitsEnglish() = assertEquals("github", typeKeys("github\n", makeEngine()))

    /** Tab flips only the last segment; what is before it stays, and only that word is learned. */
    @Test fun tabFlipsTheLastSegment() {
        val e = makeEngine()
        typeKeys("ji3so\t", e)
        assertEquals(listOf(0 to 3, 3 to 5), e.segments.map { it.start to it.end })
        assertTrue(e.markedText.startsWith("我"))
        assertEquals("我內", typeKeys("\n", e))
        assertEquals(mapOf("so" to 1), e.classifier.learned.weights.toMap())
        assertEquals("我so", typeKeys("ji3so\t\t\n", makeEngine()))   // Tab again flips it back
        // In Chinese, the last character: 我要 Tab is 我ul4; Tab again gives 我要 back.
        assertEquals("我ul4", typeKeys("ji3ul4\t\n", makeEngine()))
        assertEquals("我要", typeKeys("ji3ul4\t\t\n", makeEngine()))
        assertEquals("你cl3", typeKeys("su3cl3\t\n", makeEngine()))
        // Backspace after a flip, then commit: used to throw (subList past the end).
        assertEquals(1, typeKeys("so\t\b\n", makeEngine()).length)
    }

    /** Tab right after a commit retypes it in the other mode and learns the correction. */
    @Test fun flipLastCommit() {
        val e = makeEngine()
        assertEquals("so ", typeKeys("so ", e))
        assertEquals("so ", e.flippableText)
        val zh = e.flipLastCommit()!!
        assertFalse("s" in zh)
        assertEquals(1, e.classifier.learned.weights["so"])
        assertEquals(zh, e.flippableText)        // Tab again flips it back
        assertEquals("so ", e.flipLastCommit())
        assertEquals("你好", typeKeys("su3cl3 ", e))
        assertEquals("su3cl3 ", e.flipLastCommit())
        assertEquals(1, typeKeys("ji  ", e).length)
        assertEquals("ji ", e.flipLastCommit())
        // Not after Enter: Tab next is completion ("cd shell" ⏎ Tab in a terminal).
        assertEquals("shell", typeKeys("shell\n", e))
        assertNull(e.flippableText)
    }

    @Test fun flipLastCommitLimits() {
        val e = makeEngine()
        typeKeys("hello a", e)
        assertNull(e.flippableText)
        e.commitAll()
        typeKeys("Hello ", e)
        assertNull(e.flippableText)              // capitals aren't Dachen keys
        typeKeys("so ", e)
        e.handle(LEFT)
        assertNull(e.flippableText)
        assertEquals(KeyResult.PASS, e.handle(TAB))
        typeKeys("so ", e)
        e.handleControl(".")
        assertNull(e.flippableText)
    }

    @Test fun tabLearns() {
        val e = makeEngine()
        typeKeys("so", e)
        assertEquals(Mode.LITERAL, e.mode)
        e.handle(TAB)
        assertEquals(Mode.ZHUYIN, e.mode)
        typeKeys("\n", e)
        assertEquals(1, e.classifier.learned.weights["so"])
    }

    @Test fun punctuation() {
        assertEquals("hello, ", typeKeys("hello, ", makeEngine()))
        assertEquals("你好？", typeKeys("su3cl3?\n", makeEngine()))
    }

    @Test fun threeDotsAreAnEllipsis() {
        assertEquals("我…", typeKeys("ji3...", makeEngine()))
        assertEquals("你好……", typeKeys("su3cl3......", makeEngine()))
        assertEquals("hello...", typeKeys("hello...", makeEngine()))
    }

    @Test fun candidates() {
        val e = makeEngine()
        typeKeys("su3", e)
        e.handle(DOWN)
        assertTrue(e.showingCandidates)
        e.selectCandidate(e.candidateTexts().indexOf("妳"))
        assertEquals("妳", typeKeys("\n", e))
    }

    @Test fun digitInitials() {
        val e = makeEngine()
        typeKeys("2;3", e)
        assertEquals(1, e.markedText.length)
        assertEquals("東", typeKeys("2j/ \n", makeEngine()))
        assertEquals("2.5", typeKeys("2.5\n", makeEngine()))
    }

    @Test fun toneThenSpaceStaysChinese() = assertEquals(1, typeKeys("u4 ", makeEngine()).length)

    @Test fun outOfOrderConverts() = assertEquals("小", typeKeys("uvl3\n", makeEngine()))

    @Test fun typedOverConverts() = assertEquals("轟", typeKeys("xj/c \n", makeEngine()))   // ㄌㄨㄥ fixed by typing ㄏ over it
}

class MixedSegmentTests {
    private fun run(s: String): Pair<String, String> {
        val e = makeEngine()
        return typeKeys(s, e) to e.markedText
    }

    @Test fun chineseThenEnglish() {
        assertEquals("我hello ", run("ji3hello ").first)
        assertEquals("你好github", run("su3cl3github\n").first)
        assertEquals("我hel", run("ji3hel").second)
    }

    @Test fun englishThenChinese() {
        assertEquals("hello你好", run("hellosu3cl3 ").first)
        assertEquals("ok你好", run("oksu3cl3\n").first)
    }

    @Test fun threeSegments() = assertEquals("我email你好", run("ji3emailsu3cl3\n").first)

    @Test fun singleLanguageUnchanged() {
        assertEquals("今天天氣很好", run("rup wu0 wu0 fu4cp3cl3\n").first)
        assertEquals("helloworld", run("helloworld\n").first)
        assertEquals("meeting ", run("meeting ").first)
        assertEquals(1, run("183\n").first.length)
    }

    @Test fun speed() {
        val e = makeEngine()
        val keys = "ji3emailsu3cl3rup wu0 wu0 fu4"
        repeat(3) { typeKeys(keys, makeEngine()) }   // JIT warm-up
        val start = System.nanoTime()
        for (c in keys) {
            e.handle(c.toString())
            e.markedText
        }
        val perKey = (System.nanoTime() - start) / 1e9 / keys.length
        println("per key: %.1f ms".format(perKey * 1000))
        assertTrue(perKey < 0.05)
    }
}

class ShiftTapTests {
    @Test fun togglesEnglishMode() {
        val e = makeEngine()
        assertEquals("ru su ", typeKeys("⇧ru su ", e))
        assertTrue(e.englishMode)
        assertEquals("", e.markedText)
        assertEquals(KeyResult.PASS, e.handle(ENTER))
        assertTrue(e.englishMode)
        assertEquals("你好", typeKeys("⇧su3cl3\n", e))
        assertFalse(e.englishMode)
    }

    @Test fun tapTwiceCancels() = assertEquals("你好", typeKeys("⇧⇧su3cl3\n", makeEngine()))

    @Test fun midWordFlipsAndLearns() {
        val e = makeEngine()
        typeKeys("so", e)
        e.handle(SHIFT_TAP)
        assertEquals(Mode.ZHUYIN, e.mode)
        assertFalse(e.englishMode)
        typeKeys("\n", e)
        assertEquals(1, e.classifier.learned.weights["so"])
    }

    @Test fun englishModeNotLearned() {
        val e = makeEngine()
        typeKeys("⇧hello ", e)
        assertTrue(e.classifier.learned.weights.isEmpty())
    }

    @Test fun backspaceGoesToApp() {
        val e = makeEngine()
        e.handle(SHIFT_TAP)
        assertEquals(KeyResult.PASS, e.handle(BACKSPACE))
        assertTrue(e.englishMode)
    }

    @Test fun detector() {
        val d = ShiftTapDetector()
        d.shiftDown(0)
        assertTrue(d.shiftUp(100))
        d.shiftDown(1000)
        d.keyPressed()
        assertFalse(d.shiftUp(1100))
        d.shiftDown(2000)
        assertFalse(d.shiftUp(3000))
    }
}

class CursorTests {
    @Test fun movesAndClamps() {
        val e = makeEngine()
        typeKeys("rup wu0 wu0 fu4", e)
        assertEquals(4, e.cursorOffset)
        typeKeys("←", e)
        assertEquals(3, e.cursorOffset)
        typeKeys("←←←←", e)
        assertEquals(1, e.cursorOffset)   // stops after the first character
        typeKeys("→→→→", e)
        assertEquals(4, e.cursorOffset)
    }

    @Test fun chooseCandidateInTheMiddle() {
        val e = makeEngine()
        typeKeys("rup wu0 wu0 fu4←←↓", e)
        assertTrue(e.showingCandidates)
        assertTrue(e.candidates.all { it.end == 2 })
        e.selectCandidate(e.candidateTexts().indexOf("添"))
        assertEquals("今添天氣", typeKeys("\n", e))
    }

    @Test fun englishReturnsCursorToEnd() {
        val e = makeEngine()
        typeKeys("rup wu0 ←", e)
        assertEquals(1, e.cursorOffset)
        typeKeys("?", e)
        assertEquals("今天？", e.markedText)
        assertEquals(3, e.cursorOffset)
    }
}

class InsertInMiddleTests {
    @Test fun insertSyllable() {
        val e = makeEngine()
        typeKeys("rup fu4←wu", e)
        assertEquals("今ㄊㄧ氣", e.markedText)
        assertEquals(3, e.cursorOffset)
        typeKeys("0 ", e)
        assertEquals("今天氣", e.markedText)
        assertEquals(2, e.cursorOffset)
        assertEquals("今天氣", typeKeys("\n", e))
    }

    /** Tab with the cursor in the middle flips the word before the cursor, not the last one. */
    @Test fun tabFlipsTheWordAtTheCursor() {
        val e = makeEngine()
        assertEquals("", typeKeys("ji3ul4cl3←\t", e))
        assertEquals("我ul4好", e.markedText)
        assertEquals("", typeKeys("\t", e))             // again: back
        assertEquals("我要好", e.markedText)
        assertEquals("", typeKeys("\t→ji3", e))         // typing at the end after a flip in the middle
        assertEquals("我ul4好我", e.markedText)
        assertEquals("我ul4好我", typeKeys("\n", e))
        assertEquals("ji3要好", typeKeys("ji3ul4cl3←←\t\n", makeEngine()))
    }

    /** 上下左右 offer their arrows right after them. */
    @Test fun arrowCandidates() {
        for ((keys, char, arrow) in listOf(Triple("g;4", "上", "↑"), Triple("vu84", "下", "↓"), Triple("yji3", "左", "←"), Triple("u.4", "右", "→"))) {
            val e = makeEngine()
            typeKeys(keys + "↓", e)
            val texts = e.candidates.map { it.text }
            val i = texts.indexOf(char)
            assertEquals(arrow, texts[i + 1], keys)
            e.selectCandidate(i + 1)
            assertEquals(arrow, typeKeys("\n", e))
        }
    }

    @Test fun cursorStopsAfterFirstCharacter() {
        val e = makeEngine()
        typeKeys("su3cl3←←←", e)
        assertEquals(1, e.cursorOffset)
        typeKeys("ji3\n", e)
        assertEquals("", e.markedText)
    }

    @Test fun noStopBeforeFirstChinese() {
        val e = makeEngine()
        typeKeys("hello ji3←←", e)
        typeKeys("↓", e)
        assertTrue(e.showingCandidates)
    }

    @Test fun backspaceDeletesCharacterBeforeCursor() {
        val e = makeEngine()
        typeKeys("rup wu0 wu0 fu4←←\b", e)
        assertEquals("今天氣", e.markedText)
        assertEquals(1, e.cursorOffset)
    }

    @Test fun backspaceAtEndDeletesWholeCharacter() {
        val e = makeEngine()
        typeKeys("rup wu0 \b", e)
        assertEquals("今", e.markedText)             // 天 goes at once, not just its tone
        typeKeys("wu\b", e)
        assertEquals("今ㄊ", e.markedText)           // Bopomofo still being typed: one key
        typeKeys("\b\b", e)
        assertEquals("", e.markedText)
    }

    @Test fun backspaceInsideInsertedSyllable() {
        val e = makeEngine()
        typeKeys("rup fu4←wu\b", e)
        assertEquals("今ㄊ氣", e.markedText)
    }

    @Test fun keepsPickedPhraseBeforeCursor() {
        val e = makeEngine()
        typeKeys("rup wu0 ↓", e)
        e.selectCandidate(e.candidateTexts().indexOf("添"))
        typeKeys("fu4←wu0 ", e)
        assertEquals("今添天", e.markedText.substring(0, 3))
    }

    @Test fun candidatesForChineseBeforeEnglish() {
        val e = makeEngine()
        typeKeys("su3cl3hello↓", e)
        assertTrue(e.showingCandidates)
    }
}

class FirstToneAfterEnglishTests {
    @Test fun firstToneAfterEnglish() {
        for (keys in listOf("ru", "t", "gj", "vup", "tj", "el")) {
            val out = typeKeys("hello $keys \n", makeEngine())
            assertEquals("hello ", out.substring(0, 6), keys)
            assertEquals(7, out.length, keys)
            assertTrue(out[6].code > 127, keys)
        }
    }
}

class HeldWordTests {
    @Test fun nextWordDecides() {
        val cases = mapOf("up jo4 " to "因為", "up the " to "up the ", "pick up the " to "pick up the ",
            "up\n" to "up", "i love " to "i love ")
        for ((keys, want) in cases) assertEquals(want, typeKeys(keys, makeEngine()), keys)
    }


    /** After Chinese only common one-syllable words are held ("up" = 因/音); "push" isn't. */
    @Test fun nextWordDecidesAfterChinese() {
        val cases = mapOf("5k4ek7up m,4 " to "這個音樂", "5k4ek7up jo4 " to "這個因為", "5k4ek7up the " to "這個up the ",
            "5k4ek7up\n" to "這個up", "ji3ul4push " to "我要push ")
        for ((keys, want) in cases) assertEquals(want, typeKeys(keys, makeEngine()), keys)
        val e = makeEngine()
        assertEquals("", typeKeys("5k4ek7up ", e))
        assertEquals("這個up ", e.markedText)
    }
    @Test fun heldWordStaysComposing() {
        val e = makeEngine()
        assertEquals("", typeKeys("up ", e))
        assertEquals("up ", e.markedText)
        e.handle(BACKSPACE)
        assertEquals("up", e.markedText)
        assertEquals("up the ", typeKeys(" the ", e))
    }

    private fun engine(learned: LearnedPreferences) = CompositionEngine(Classifier(LEX, ENG, learned, WEIGHTS))

    @Test fun heldWordWithDigitKeys() {
        val learned = LearnedPreferences(mapOf("0" to -2))
        assertEquals("安裝", typeKeys("0 5j; \n", engine(learned)))
        assertEquals("0 ", typeKeys("0 \n", engine(learned)))
    }

    @Test fun tabOverridesLearned() {
        val learned = LearnedPreferences(mapOf("0" to -2))
        assertEquals("安裝", typeKeys("0\t 5j; \n", engine(learned)))
        assertEquals(1, learned.weights["0"])
        assertFalse("0 5j; " in learned.weights)
        assertEquals("hello 安裝", typeKeys("hello 0 5j; \n", engine(learned)))
    }
}

class BacktickSymbolTests {
    @Test fun backslashIsDunhao() {
        assertEquals("我、", typeKeys("ji3\\\n", makeEngine()))
        assertEquals("hello\\", typeKeys("hello\\", makeEngine()))
    }

    @Test fun controlSymbols() {
        val e = makeEngine()
        typeKeys("ji3", e)
        assertEquals(KeyResult(true, "我；"), e.handleControl(";"))
        assertEquals(KeyResult(true, "、"), e.handleControl("'"))
        assertNull(e.handleControl("c"))
    }

    @Test fun symbolTable() {
        val e = makeEngine()
        assertEquals("我", typeKeys("ji3` ", e))
        assertTrue(e.symbolTable)
        assertEquals("；", typeKeys("4", e))
        assertEquals("。", typeKeys("`↓↓\n", e))
        typeKeys("` \u001b", e)
        assertFalse(e.showingCandidates)
        assertEquals("你", typeKeys("su3 ", e))
    }

    @Test fun forcedSymbols() {
        val cases = mapOf("`<" to "，", "`." to "。", "`?" to "？", "`;" to "；", "`[" to "「",
            "hello`," to "hello，", "su3cl3`." to "你好。", "```\n" to "```")
        for ((keys, want) in cases) assertEquals(want, typeKeys(keys, makeEngine()), keys)
    }

    @Test fun plainBacktick() {
        val e = makeEngine()
        assertEquals("", typeKeys("`", e))
        assertEquals("`", e.markedText)
        assertEquals("`ls` ", typeKeys("ls` ", e))
    }

    @Test fun escapeCancels() {
        val e = makeEngine()
        typeKeys("su3`", e)
        e.handle(BACKSPACE)
        assertEquals("你", e.markedText)
    }
}

class FirstWordHoldTests {
    @Test fun nextWordDecides() {
        val cases = mapOf("el ji3 " to "高我", "no su3cl3 " to "no 你好", "ok ji3 " to "ok 我",
            "i love you " to "i love you ", "up the " to "up the ")
        for ((keys, want) in cases) assertEquals(want, typeKeys(keys, makeEngine()), keys)
    }

    @Test fun notHeldAfterEnglish() {
        val e = makeEngine()
        assertEquals("hello world ", typeKeys("hello world ", e))
        assertEquals("so ", typeKeys("so ", e))
    }
}

class UserHistoryTests {
    private val saved = ArrayList<String>()
    private val c = Classifier(LEX, ENG, weights = WEIGHTS, history = UserHistory(onChange = { saved += it.toJson() }))

    private fun pick(keys: String, phrase: String): String {
        val e = CompositionEngine(c)
        typeKeys("$keys↓", e)
        e.selectCandidate(e.candidateTexts().indexOf(phrase))
        return typeKeys("\n", e)
    }

    @Test fun pickedCandidateComesFirst() {
        assertEquals("天", typeKeys("wu0 \n", CompositionEngine(c)))
        assertEquals("添", pick("wu0 ", "添"))
        assertEquals("添", typeKeys("wu0 \n", CompositionEngine(c)))
        val e = CompositionEngine(c)
        typeKeys("wu0 ↓", e)
        assertEquals("添", e.candidates[0].text)
        assertEquals("""{"ㄊㄧㄢ":{"添":[1,1]}}""", saved.last())
    }

    @Test fun phrasesStillWin() {
        pick("wu0 ", "添")
        assertEquals("今天", typeKeys("rup wu0 \n", CompositionEngine(c)))
    }

    @Test fun mostPickedWins() {
        pick("wu0 ", "添")
        pick("wu0 ", "添")
        pick("wu0 ", "天")
        assertEquals("添", typeKeys("wu0 \n", CompositionEngine(c)))
    }

    @Test fun roundTripAndClear() {
        pick("wu0 ", "添")
        val h = UserHistory(UserHistory.parse(saved.last()))
        assertEquals(listOf(1, 1), h.data["ㄊㄧㄢ"]!!["添"]!!.toList())
        h.record(listOf(Bopomofo.parse(keysOf("wu0 ")).syllables[0].syllable), "天")
        assertEquals(listOf(1, 2), h.data["ㄊㄧㄢ"]!!["天"]!!.toList())
        h.clear()
        assertTrue(h.data.isEmpty())
    }

    @Test fun evictsLeastRecent() {
        val h = UserHistory()
        h.maxEntries = 2
        val syl = listOf(Bopomofo.parse(keysOf("wu0 ")).syllables[0].syllable)
        for (p in listOf("天", "添", "田")) h.record(syl, p)
        assertEquals(setOf("添", "田"), h.data["ㄊㄧㄢ"]!!.keys)
    }
}

/** A Shift-punctuation typed with nothing composed waits for the next key; Tab switches it. */
class HeldPunctuationTests {
    @Test fun tabSwitches() {
        val e = makeEngine()
        assertEquals("", typeKeys("<", e))
        assertEquals("<", e.markedText)
        assertEquals(1, e.cursorOffset)
        typeKeys("\t", e)
        assertEquals("，", e.markedText)
        typeKeys("⇧", e)
        assertEquals("<", e.markedText)
        assertFalse(e.englishMode)
        assertEquals("，", typeKeys("\tsu3", e))
        assertEquals("你", e.markedText)
    }

    @Test fun guessFromContext() {
        assertEquals("我，", typeKeys("ji3 <\n", makeEngine()))
        assertEquals("我!", typeKeys("ji3 !\t\n", makeEngine()))
        assertEquals("我，", typeKeys("ji3<\n", makeEngine()))
        assertEquals("hello!", typeKeys("hello!", makeEngine()))   // after English: sent at once
        assertEquals("hello\\", typeKeys("hello\\", makeEngine()))
    }

    @Test fun spaceSendsIt() {
        assertEquals("! ", typeKeys("! ", makeEngine()))
        assertEquals("我！", typeKeys("ji3 ! ", makeEngine()))
    }

    /** The switch says which language is being typed: the next punctuation follows it. */
    @Test fun switchIsRemembered() = assertEquals("，。", typeKeys("<\t>\n", makeEngine()))

    @Test fun backspaceCancels() {
        val e = makeEngine()
        assertEquals("", typeKeys("(\b", e))
        assertEquals("", e.markedText)
    }

    @Test fun wants() {
        val e = makeEngine()
        assertTrue(e.wants("<"))
        typeKeys("<", e)
        assertTrue(e.wants(ENTER))
        assertTrue(e.wants(TAB))
        assertTrue(e.isComposing)
    }

    /** After Chinese it waits too, after the composition; the next key sends both. */
    @Test fun heldAfterChinese() {
        val e = makeEngine()
        assertEquals("", typeKeys("ji3[", e))
        assertEquals("我「", e.markedText)
        assertEquals("我「", typeKeys("su3", e))
        assertEquals("你", e.markedText)
        assertEquals("我<", typeKeys("ji3<\t\n", makeEngine()))
        assertEquals("我", typeKeys("ji3(\b\n", makeEngine()))
    }

    /** Enter sends the punctuation like a composition, without a new line. */
    @Test fun enterSendsItOnly() {
        val e = makeEngine()
        typeKeys("!", e)
        assertEquals(KeyResult(true, "!"), e.handle(ENTER))
    }

    @Test fun downPicksAnother() {
        val e = makeEngine()
        typeKeys("ji3[↓", e)
        assertTrue(e.punctTable)
        val (texts, index) = e.page()
        assertEquals(listOf("「", "『", "（", "【"), texts.take(4))
        assertEquals("「", texts[index])
        typeKeys("2", e)
        assertFalse(e.showingCandidates)
        assertEquals("我『", e.markedText)   // picked, not sent yet
        assertEquals("我『", typeKeys("\n", e))
    }

    @Test fun choices() {
        assertEquals("『", CompositionEngine.punctChoices("{").first())
        assertEquals("{", CompositionEngine.punctChoices("{").last())
        assertEquals(CompositionEngine.punctChoices("(").size, CompositionEngine.punctChoices("(").toSet().size)
        assertEquals(listOf("）", "」"), CompositionEngine.punctChoices(")").take(2))
        assertTrue("、" in CompositionEngine.punctChoices("<"))
    }

    @Test fun tabAfterAPick() {
        val e = makeEngine()
        typeKeys("ji3 (↓", e)
        e.selectCandidate(e.candidates.indexOfFirst { it.text == "【" })
        assertEquals("【", e.markedText)
        typeKeys("\t", e)
        assertEquals("(", e.markedText)
        typeKeys("\t", e)
        assertEquals("（", e.markedText)
    }

    @Test fun commitAll() {
        val e = makeEngine()
        typeKeys("ji3 ?", e)
        assertEquals("？", e.commitAll())
        typeKeys("?", e)
        assertEquals(KeyResult(true, "？，"), e.handleControl(","))
    }
}

/** User phrases: the file model, typed readings and the lexicon overlay (mirror of test_user_phrases.py). */
class UserPhrasesTests {
    @Test fun roundTripKeepsComments() {
        val u = UserPhrases("# 我的詞\nㄗˋ-ㄉㄨㄥˋ 自動 -1\n\n注音 ㄓㄨˋ-ㄧㄣ\n")
        assertEquals(listOf("自動", "注音"), u.entries.map { it.phrase })
        assertNull(u.entries[1].score)
        assertEquals("# 我的詞\nㄗˋ-ㄉㄨㄥˋ 自動 -1\n\nㄓㄨˋ-ㄧㄣ 注音\n", u.text)
        u.remove(0)
        u.append(UserPhrases.Item("妳好", "ㄋㄧˇ-ㄏㄠˇ"))
        assertEquals("# 我的詞\n\nㄓㄨˋ-ㄧㄣ 注音\nㄋㄧˇ-ㄏㄠˇ 妳好 -1\n", u.text)
        u.replace(0, UserPhrases.Item("註音", "ㄓㄨˋ-ㄧㄣ", -2.5))
        assertEquals(UserPhrases.Item("註音", "ㄓㄨˋ-ㄧㄣ", -2.5), u.entries[0])
        assertEquals("", UserPhrases("").text)
    }

    @Test fun typedReadings() {
        assertEquals("ㄗˋ-ㄉㄨㄥˋ", UserPhrases.readingFromTyped("y42j/4"))
        assertEquals("ㄗˋ-ㄉㄨㄥˋ", UserPhrases.readingFromTyped("ㄗˋㄉㄨㄥˋ"))
        assertEquals("ㄓㄨˋ-ㄧㄣ", UserPhrases.readingFromTyped("ㄓㄨˋ ㄧㄣ"))
        assertEquals("ㄐㄧ-ㄚ", UserPhrases.readingFromTyped("ㄐㄧ-ㄚ"))
        assertEquals("ㄉㄜ˙", UserPhrases.readingFromTyped("ㄉㄜ˙"))
        assertNull(UserPhrases.readingFromTyped("hello!"))
        assertNull(UserPhrases.readingFromTyped(""))
        assertEquals("注音有 2 個音節，詞有 4 個字", UserPhrases.problem("自動注音", "ㄗˋ-ㄉㄨㄥˋ"))
        assertNull(UserPhrases.problem("自動", "ㄗˋ-ㄉㄨㄥˋ"))
        assertEquals(listOf(3, 4), UserPhrases.badLines("# ok\nㄗˋ-ㄉㄨㄥˋ 自動\n亂寫\nㄗˋ 自動\n"))
    }

    @Test fun lexiconUserPhrasesOverrideAndReload() {
        val lex = Lexicon()
        lex.load(sequenceOf("ㄋㄧˇ 你 -2", "ㄋㄧˇ 妳 -3", "ㄏㄠˇ 好 -2", "ㄋㄧˇ-ㄏㄠˇ 你好 -3"))
        val ni = Bopomofo.parse(keysOf("su3")).syllables.map { it.syllable }
        assertEquals("你", lex.entries(ni)[0].phrase)
        lex.setUserPhrases("ㄋㄧˇ 妳 -1\n")
        assertEquals(listOf("妳", "你"), lex.entries(ni).map { it.phrase })
        assertEquals("ㄋㄧˇ-ㄏㄠˇ", lex.readingOf("妳好"))
        assertEquals("ㄋㄧˇ-ㄏㄠˇ", lex.readingOf("你好"))
        assertNull(lex.readingOf("貓"))
        lex.setUserPhrases("")
        assertEquals(listOf("你", "妳"), lex.entries(ni).map { it.phrase })
        val untoned = Bopomofo.parse(keysOf("su")).syllables.map { it.syllable }
        assertEquals("你", lex.entries(untoned)[0].phrase)
    }
}
