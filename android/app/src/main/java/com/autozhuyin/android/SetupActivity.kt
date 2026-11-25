package com.autozhuyin.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/** Setup steps, status, a field to try typing in, and 清除學習紀錄 / licenses. */
class SetupActivity : Activity() {
    private lateinit var status: TextView

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(32))
        }
        fun heading(text: String) = column.addView(TextView(this).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(0, dp(20), 0, dp(6))
        })
        fun body(text: String) = column.addView(TextView(this).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setLineSpacing(0f, 1.2f)
        })
        fun button(text: String, action: () -> Unit) = column.addView(Button(this).apply {
            this.text = text
            setOnClickListener { action() }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        column.addView(TextView(this).apply {
            text = "自動注音"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 26f)
        })
        body("接上實體鍵盤（USB、藍牙、平板鍵盤）時，直接用大千注音鍵位打字，自動判斷是注音還是英文。沒有接鍵盤時會自動切回你原本的輸入法。")
        status = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setPadding(0, dp(12), 0, 0)
        }
        column.addView(status)

        heading("1. 啟用")
        body("在輸入法清單中開啟「自動注音（實體鍵盤）」。系統提醒輸入法可能收集輸入的文字：自動注音沒有網路權限，所有資料都留在這台裝置上。")
        button("開啟輸入法設定") { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }

        heading("2. 實體鍵盤配置設為英文（美國）")
        body("大千鍵位以美式鍵盤為準。設定 → 系統 → 鍵盤 → 實體鍵盤 → 選擇你的鍵盤 → 英文（美國）。Android 14 以上通常會自動套用。")
        button("開啟實體鍵盤設定") { startActivity(Intent(Settings.ACTION_HARD_KEYBOARD_SETTINGS)) }

        heading("3. 接上鍵盤後切換到自動注音")
        body("點螢幕下方或通知列的鍵盤圖示，或用實體鍵盤的切換快速鍵（依裝置而定，常見的是 Ctrl + 空白鍵）。拔掉鍵盤後會自動切回原本的輸入法；再次接上時要手動切回自動注音。")
        button("選擇輸入法") { (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker() }

        heading("試打")
        column.addView(EditText(this).apply {
            hint = "ji3 hello su3cl3 → 我hello你好"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 3
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        heading("選項")
        column.addView(Switch(this).apply {
            text = "要打聲調才出字"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            isChecked = Models.requireTones(this@SetupActivity)
            setOnCheckedChangeListener { _, on -> Models.setRequireTones(this@SetupActivity, on) }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        body("開啟後，沒打聲調的音節會維持注音符號（jiap7 → ㄨㄛ們），打了聲調才變成中文字；一聲用空白。" +
            "還沒打聲調時發現打錯，直接補打正確的注音再打聲調就會蓋掉（ㄒㄧㄥ 再打 ㄩˊ → ㄒㄩㄥˊ 雄）。關閉時可以省略聲調（jiap7 → 我們）。")
        column.addView(Switch(this).apply {
            text = "候選字顯示 emoji"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            isChecked = Models.showEmoji(this@SetupActivity)
            setOnCheckedChangeListener { _, on -> Models.setShowEmoji(this@SetupActivity, on) }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        body("「笑」「貓」這類候選字後面接著相關的 emoji（笑 → 🤣🥰😼），按 ↓ 選字時可以選。")

        heading("按鍵")
        body(
            "空白：一聲；音節完成時送出\n" +
                "Enter：送出目前組字\n" +
                "Tab：判斷錯了，最後一段中英翻轉（會記住）；剛按空白送出的字也可以緊接著按 Tab 改掉\n" +
                "單按 Shift：切換英文模式\n" +
                "← →：移動游標；↓：選字（數字鍵選、Esc 關閉）\n" +
                "剛打的標點會先留在組字區：Tab 切換全形／半形（< ↔ ，），↓ 選別的符號（「 → 『（【…）\n" +
                "Ctrl + ; ' , . /：；、，。？\n" +
                "` 再按標點：全形標點；` 再按空白：符號表"
        )

        heading("其他")
        button("編輯自訂詞") { startActivity(Intent(this, PhraseEditorActivity::class.java)) }
        button("清除學習紀錄") {
            AlertDialog.Builder(this)
                .setMessage("清除中英判斷的修正和選字紀錄？")
                .setPositiveButton("清除") { _, _ -> Models.clearLearned(this) }
                .setNegativeButton("取消", null)
                .show()
        }
        button("授權資訊") { showLicenses() }

        setContentView(ScrollView(this).apply { addView(column) })
        Models.load(this) { runOnUiThread { refresh() } }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) refresh()   // back from the input method picker
    }

    private fun refresh() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val enabled = imm.enabledInputMethodList.any { it.packageName == packageName }
        val current = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.startsWith("$packageName/") == true
        val c = resources.configuration
        val keyboard = c.keyboard == Configuration.KEYBOARD_QWERTY && c.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO
        status.text = listOf(
            (if (enabled) "✓ 已啟用" else "✗ 尚未啟用") + (if (current) "，目前使用中" else ""),
            if (keyboard) "✓ 偵測到實體鍵盤" else "－ 沒有偵測到實體鍵盤",
            when {
                Models.error != null -> "✗ 詞庫載入失敗：${Models.error}"
                Models.classifier != null -> "✓ 詞庫已載入"
                else -> "… 詞庫載入中"
            },
        ).joinToString("\n")
    }

    private fun showLicenses() {
        val text = try {
            assets.open("THIRD_PARTY_LICENSES.txt").reader().use { it.readText() }
        } catch (e: Exception) {
            e.toString()
        }
        val view = ScrollView(this).apply {
            addView(TextView(this@SetupActivity).apply {
                this.text = "自動注音以 GNU GPL v3.0 授權釋出。\n\n$text"
                setTextIsSelectable(true)
                setPadding(dp(20), dp(12), dp(20), dp(12))
            })
        }
        AlertDialog.Builder(this).setTitle("授權資訊").setView(view).setPositiveButton("關閉", null).show()
    }
}
