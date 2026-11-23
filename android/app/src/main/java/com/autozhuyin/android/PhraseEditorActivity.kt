package com.autozhuyin.android

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import com.autozhuyin.core.UserPhrases

/**
 * 編輯自訂詞: same behavior as the desktop editors (Sources/AutoZhuyin/PhraseEditor.swift,
 * linux/phrase_editor.py). Every change is saved to user-phrases.txt and takes effect at once.
 */
class PhraseEditorActivity : Activity() {
    private lateinit var phrases: UserPhrases
    private lateinit var phraseField: EditText
    private lateinit var readingField: EditText
    private lateinit var message: TextView
    private lateinit var adapter: ArrayAdapter<String>
    private var hintColor = 0
    /** The reading field holds a suggestion from the lexicon, replaced as the phrase changes. */
    private var readingIsSuggested = false

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "自訂詞"
        phrases = UserPhrases(Models.readUserPhrases(this))

        phraseField = EditText(this).apply {
            hint = "詞，例如：自動注音"
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        readingField = EditText(this).apply {
            hint = "注音：ㄗˋ ㄉㄨㄥˋ… 或大千鍵位 y42j/4…"
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, _, _ -> add(); true }
        }
        phraseField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) = suggestReading()
        })
        readingField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                readingIsSuggested = false
            }
        })
        message = TextView(this).apply {
            text = HINT
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(0, dp(6), 0, dp(6))
        }
        hintColor = message.currentTextColor
        adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, ArrayList<String>())
        val list = ListView(this).apply {
            adapter = this@PhraseEditorActivity.adapter
            setOnItemClickListener { _, _, position, _ -> edit(position) }
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(16))
            addView(phraseField, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(readingField, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(Button(this@PhraseEditorActivity).apply {
                text = "加入"
                setOnClickListener { add() }
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(message)
            addView(list, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        }
        setContentView(column)
        reloadList()
        // The lexicon gives the suggested readings; the editor works without it meanwhile.
        Models.load(this) { runOnUiThread { suggestReading() } }
    }

    private fun suggestReading() {
        if (readingField.text.isNotEmpty() && !readingIsSuggested) return
        val lexicon = Models.classifier?.lexicon ?: return
        val reading = lexicon.readingOf(phraseField.text.toString().trim())
        readingField.setText(reading?.let(::spaced) ?: "")
        readingIsSuggested = true   // set after setText: the watcher clears it
    }

    private fun showHint(text: String = HINT) {
        message.text = text
        message.setTextColor(hintColor)
    }

    private fun showProblem(text: String) {
        message.text = text
        message.setTextColor(Color.rgb(0xD0, 0x30, 0x30))
    }

    /** The entry typed in, or null after showing what's wrong. */
    private fun entryFrom(phrase: String, typed: String, score: Double?, show: (String) -> Unit): UserPhrases.Item? {
        val p = phrase.trim()
        val reading = UserPhrases.readingFromTyped(typed)
        if (reading == null && typed.isNotBlank()) {
            show("看不懂這個注音：$typed")
            return null
        }
        UserPhrases.problem(p, reading ?: "")?.let {
            show(it)
            return null
        }
        return UserPhrases.Item(p, reading!!, score)
    }

    private fun add() {
        val new = entryFrom(phraseField.text.toString(), readingField.text.toString(), UserPhrases.DEFAULT_SCORE, ::showProblem) ?: return
        if (phrases.entries.any { it.phrase == new.phrase && it.reading == new.reading }) {
            showProblem("已經有「${new.phrase}」了")
            return
        }
        phrases.append(new)
        save()
        phraseField.setText("")
        readingField.setText("")
        readingIsSuggested = false
        showHint("已加入「${new.phrase}」")
        phraseField.requestFocus()
    }

    /** Tapping a phrase: change it or delete it. */
    private fun edit(index: Int) {
        val old = phrases.entries.getOrNull(index) ?: return
        val phrase = EditText(this).apply {
            setText(old.phrase)
            inputType = InputType.TYPE_CLASS_TEXT
        }
        val reading = EditText(this).apply {
            setText(spaced(old.reading))
            inputType = InputType.TYPE_CLASS_TEXT
        }
        val problem = TextView(this).apply { setTextColor(Color.rgb(0xD0, 0x30, 0x30)) }
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
            addView(phrase)
            addView(reading)
            addView(problem)
        }
        val dialog = AlertDialog.Builder(this)
            .setView(form)
            .setPositiveButton("儲存", null)   // set below, so a problem keeps the dialog open
            .setNeutralButton("刪除") { _, _ ->
                phrases.remove(index)
                save()
                showHint("已刪除「${old.phrase}」")
            }
            .setNegativeButton("取消", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val new = entryFrom(phrase.text.toString(), reading.text.toString(), old.score) { problem.text = it }
                    ?: return@setOnClickListener
                if (new != old) {
                    phrases.replace(index, new)
                    save()
                }
                showHint()
                dialog.dismiss()
            }
        }
        dialog.show()
    }

    private fun reloadList() {
        adapter.clear()
        adapter.addAll(phrases.entries.map { "${it.phrase}　${spaced(it.reading)}" })
    }

    private fun save() {
        reloadList()
        Models.saveUserPhrases(this, phrases.text)
    }

    companion object {
        private const val HINT = "打好詞會自動填入常用讀音，可以再修改。選字時自訂詞會排在最前面。點一下清單裡的詞可以修改或刪除。"

        /** "ㄗˋ-ㄉㄨㄥˋ" → "ㄗˋ ㄉㄨㄥˋ", easier to read and edit. */
        private fun spaced(reading: String) = reading.replace("-", " ")
    }
}
