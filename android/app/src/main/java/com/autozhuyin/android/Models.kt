package com.autozhuyin.android

import android.content.Context
import android.util.Log
import com.autozhuyin.core.Bigram
import com.autozhuyin.core.Classifier
import com.autozhuyin.core.EnglishModel
import com.autozhuyin.core.LearnedPreferences
import com.autozhuyin.core.Lexicon
import com.autozhuyin.core.UserHistory
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * The lexicon, English model and the user's learned data, loaded once per process in the
 * background (a few seconds on a phone). Personal data lives in the app's private files:
 *   learned.json       Tab corrections        (same format as the desktop versions)
 *   user-history.json  picked candidates
 *   user-phrases.txt   custom phrases, lexicon.txt format (optional; 編輯自訂詞 edits it)
 */
object Models {
    private const val TAG = "AutoZhuyin"

    @Volatile var classifier: Classifier? = null
        private set
    @Volatile var error: String? = null
        private set

    private val io = Executors.newSingleThreadExecutor()
    private val waiting = ArrayList<(Classifier) -> Unit>()
    private var started = false
    private lateinit var dir: File
    /** user-phrases.txt's date when it was last read (0: missing). */
    @Volatile private var phrasesStamp = -1L

    /** Calls onReady (on a background thread) once the models are loaded. */
    fun load(context: Context, onReady: (Classifier) -> Unit) {
        synchronized(this) {
            classifier?.let { return onReady(it) }
            waiting += onReady
            if (started) return
            started = true
        }
        val app = context.applicationContext
        dir = app.filesDir
        io.execute {
            val c = try {
                build(app)
            } catch (e: Exception) {
                Log.e(TAG, "loading failed", e)
                error = e.toString()
                null
            }
            val callbacks = synchronized(this) {
                classifier = c
                waiting.toList().also { waiting.clear() }
            }
            if (c != null) {
                callbacks.forEach { it(c) }
                c.lexicon.toneless   // build the toneless index now rather than on the first untoned key
            }
        }
    }

    private fun build(context: Context): Classifier {
        val start = System.nanoTime()
        val assets = context.assets
        val lexicon = assets.open("lexicon.txt").reader().use { Lexicon.from(it) }
        phrasesStamp = phrasesFile().lastModified()
        lexicon.setUserPhrases(readUserPhrases())
        val english = EnglishModel(
            EnglishModel.readWords(assets.open("english-common.txt").reader().use { it.readText() }),
            EnglishModel.readWords(assets.open("english-dict.txt").reader().use { it.readText() }),
            Bigram.fromJson(assets.open("english-bigram.json").reader().use { it.readText() }),
        )
        val weights = Classifier.parseWeights(assets.open("classifier-weights.json").reader().use { it.readText() })
        val learned = LearnedPreferences(readLearned()) { save("learned.json", JSONObject(it.toMap()).toString()) }
        val history = UserHistory(UserHistory.parse(readText("user-history.json"))) { save("user-history.json", it.toJson()) }
        Log.i(TAG, "models loaded in %.1fs".format((System.nanoTime() - start) / 1e9))
        return Classifier(lexicon, english, learned, weights, history)
    }

    private fun phrasesFile() = File(dir, "user-phrases.txt")

    /** The user phrases file's text ("" if there is none). */
    fun readUserPhrases(context: Context): String {
        dir = context.applicationContext.filesDir
        return readUserPhrases()
    }

    private fun readUserPhrases(): String = readText("user-phrases.txt")?.removePrefix("\uFEFF") ?: ""

    /** Rereads user-phrases.txt if it changed since it was read (a hand edit). */
    fun reloadUserPhrases() {
        val c = classifier ?: return
        io.execute {
            val stamp = phrasesFile().lastModified()
            if (stamp == phrasesStamp) return@execute
            phrasesStamp = stamp
            c.lexicon.setUserPhrases(readUserPhrases())
        }
    }

    /** Saves the phrase editor's text; it takes effect at once. */
    fun saveUserPhrases(context: Context, text: String) {
        dir = context.applicationContext.filesDir
        classifier?.lexicon?.setUserPhrases(text)
        io.execute {
            write("user-phrases.txt", text)
            phrasesStamp = phrasesFile().lastModified()
        }
    }

    private fun readText(name: String): String? = File(dir, name).takeIf { it.exists() }?.readText()

    private fun readLearned(): Map<String, Int> {
        val out = LinkedHashMap<String, Int>()
        try {
            val o = JSONObject(readText("learned.json") ?: return out)
            for (k in o.keys()) out[k] = o.getInt(k)
        } catch (e: Exception) {
            Log.w(TAG, "learned.json unreadable", e)
        }
        return out
    }

    /** Writes in the background; the text is captured now, so later changes don't race. */
    private fun save(name: String, text: String) {
        io.execute { write(name, text) }
    }

    private fun write(name: String, text: String) {
        try {
            val tmp = File(dir, "$name.tmp")
            tmp.writeText(text)
            tmp.renameTo(File(dir, name))
        } catch (e: Exception) {
            Log.w(TAG, "saving $name failed", e)
        }
    }

    /** 要打聲調才出字: untoned syllables stay as Bopomofo. */
    fun requireTones(context: Context): Boolean = prefs(context).getBoolean(REQUIRE_TONES, false)

    fun setRequireTones(context: Context, on: Boolean) = prefs(context).edit().putBoolean(REQUIRE_TONES, on).apply()

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private const val REQUIRE_TONES = "require_tones"

    /** 清除學習紀錄: Tab corrections and picked candidates. */
    fun clearLearned(context: Context) {
        val c = classifier
        if (c != null) {
            c.learned.clear()
            c.history.clear()
        } else {
            val d = context.applicationContext.filesDir
            io.execute { File(d, "learned.json").delete(); File(d, "user-history.json").delete() }
        }
    }
}
