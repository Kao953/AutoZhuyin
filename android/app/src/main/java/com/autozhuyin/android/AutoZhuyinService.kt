package com.autozhuyin.android

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.hardware.input.InputManager
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.UnderlineSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.autozhuyin.core.CompositionEngine
import com.autozhuyin.core.Mode
import com.autozhuyin.core.ShiftTapDetector

/**
 * 自動注音 for physical keyboards (USB / Bluetooth / tablet keyboard covers).
 *
 * All the logic is in :core (port of the desktop versions); this class only translates
 * key events, draws the composition and candidate bar, and steps aside when there is no
 * physical keyboard: it switches back to the previous input method (the user's usual
 * on-screen keyboard). Android cannot switch back automatically when a keyboard is
 * connected later; the user picks 自動注音 again from the keyboard switcher.
 */
class AutoZhuyinService : InputMethodService(), InputManager.InputDeviceListener {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var inputManager: InputManager
    private var engine: CompositionEngine? = null
    private val shiftTap = ShiftTapDetector()
    /** Key codes whose key-down we consumed: their key-up is swallowed too. */
    private val consumed = HashSet<Int>()
    private var candidateBar: CandidateBar? = null
    /** Start of the composing region in the editor, from onUpdateSelection (-1: unknown). */
    private var composingStart = -1
    /** Password, number and raw-key (TYPE_NULL) fields: keys go to the app untouched. */
    private var passthrough = false
    private var inputActive = false

    override fun onCreate() {
        super.onCreate()
        inputManager = getSystemService(Context.INPUT_SERVICE) as InputManager
        inputManager.registerInputDeviceListener(this, main)
        Models.load(this) { classifier -> main.post { engine = CompositionEngine(classifier) } }
    }

    override fun onDestroy() {
        inputManager.unregisterInputDeviceListener(this)
        super.onDestroy()
    }

    // --- physical keyboard detection ---

    private fun hasPhysicalKeyboard(): Boolean {
        val c = resources.configuration
        if (c.keyboard == Configuration.KEYBOARD_QWERTY && c.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO) {
            return true
        }
        return inputManager.inputDeviceIds.any { id ->
            val d = inputManager.getInputDevice(id) ?: return@any false
            !d.isVirtual && d.supportsSource(InputDevice.SOURCE_KEYBOARD) &&
                d.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC &&
                (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || d.isExternal)
        }
    }

    override fun onInputDeviceAdded(deviceId: Int) {}

    override fun onInputDeviceChanged(deviceId: Int) {}

    override fun onInputDeviceRemoved(deviceId: Int) {
        // Keyboard unplugged while typing: hand over to the on-screen keyboard right away.
        if (inputActive && !hasPhysicalKeyboard()) switchAway()
    }

    /** Our own "keyboard" is only a notice, shown when no physical keyboard is attached. */
    override fun onEvaluateInputViewShown(): Boolean = !hasPhysicalKeyboard()

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onCreateInputView(): View = noKeyboardView()

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (!hasPhysicalKeyboard()) switchAway()
    }

    /** Back to the previous input method; if there is none, the notice view stays up. */
    @Suppress("DEPRECATION")
    private fun switchAway() {
        finishComposition()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            switchToPreviousInputMethod()
        } else {
            val token = window?.window?.attributes?.token
            if (token != null) (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).switchToLastInputMethod(token)
        }
        // Not switched (no previous input method): the notice view stays up with a picker button.
    }

    private fun noKeyboardView(): View {
        fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            val dark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
            setBackgroundColor(if (dark) Color.rgb(0x26, 0x26, 0x28) else Color.rgb(0xF2, 0xF2, 0xF4))
            addView(TextView(context).apply {
                text = "自動注音只支援實體鍵盤。\n沒有接鍵盤時，請改用其他輸入法。"
                gravity = Gravity.CENTER
                setTextColor(if (dark) Color.WHITE else Color.BLACK)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            })
            addView(Button(context).apply {
                text = "選擇其他輸入法"
                setOnClickListener {
                    (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
                }
            })
        }
    }

    // --- input lifecycle ---

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        inputActive = true
        val type = attribute?.inputType ?: InputType.TYPE_NULL
        val cls = type and InputType.TYPE_MASK_CLASS
        val variation = type and InputType.TYPE_MASK_VARIATION
        passthrough = cls != InputType.TYPE_CLASS_TEXT ||
            (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)
        if (!restarting) {
            engine?.reset()
            composingStart = -1
        }
    }

    override fun onFinishInput() {
        finishComposition()
        inputActive = false
        super.onFinishInput()
    }

    /** Commits what is being composed (focus moves away, keyboard unplugged…). */
    private fun finishComposition() {
        val e = engine ?: return
        if (e.isComposing) {
            val text = e.commitAll()
            currentInputConnection?.let { ic -> if (text.isNotEmpty()) ic.commitText(text, 1) else ic.finishComposingText() }
        }
        e.reset()
        consumed.clear()
        updateCandidates()
    }

    override fun onUpdateSelection(
        oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        composingStart = candidatesStart
    }

    // --- keys ---

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyDown(keyCode, event)) {
            consumed += keyCode
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (isShift(keyCode)) {
            val e = engine
            if (shiftTap.shiftUp(event.eventTime) && e != null && !passthrough) {
                e.handle(CompositionEngine.SHIFT_TAP)
                update(null)
                if (!e.isComposing) showMode(e.englishMode)
            }
            return super.onKeyUp(keyCode, event)
        }
        if (consumed.remove(keyCode)) return true
        return super.onKeyUp(keyCode, event)
    }

    private fun isShift(keyCode: Int) = keyCode == KeyEvent.KEYCODE_SHIFT_LEFT || keyCode == KeyEvent.KEYCODE_SHIFT_RIGHT

    /** True if the key was used. */
    private fun keyDown(keyCode: Int, event: KeyEvent): Boolean {
        val e = engine ?: return false   // still loading: type as usual
        if (passthrough || currentInputConnection == null || event.isSystem) return false

        // Shift pressed and released alone: English mode (or flip the current word).
        if (isShift(keyCode)) {
            if (event.repeatCount == 0) {
                if (event.isCtrlPressed || event.isAltPressed || event.isMetaPressed) shiftTap.keyPressed()
                else shiftTap.shiftDown(event.eventTime)
            }
            return false
        }
        shiftTap.keyPressed()

        // Ctrl + ; ' , . / → full-width ；、，。？
        val shortcut = event.isCtrlPressed || event.isAltPressed || event.isMetaPressed
        if (event.isCtrlPressed && !event.isAltPressed && !event.isMetaPressed) {
            val ch = event.getUnicodeChar(event.metaState and KeyEvent.META_CTRL_MASK.inv())
            if (ch > 0) {
                e.handleControl(String(Character.toChars(ch)))?.let {
                    update(it.commit)
                    return true
                }
            }
        }
        // Other shortcuts (Ctrl+C, Alt+Tab…) go to the app; commit any composition first.
        if (shortcut) {
            if (e.isComposing) update(e.commitAll())
            return false
        }

        val key = keyFor(keyCode, event) ?: return e.isComposing   // swallow Delete, Home… while composing
        if (!e.wants(key)) return false
        val result = e.handle(key)
        update(result.commit)
        return result.handled
    }

    private fun keyFor(keyCode: Int, event: KeyEvent): String? {
        when (keyCode) {
            KeyEvent.KEYCODE_DEL -> return CompositionEngine.BACKSPACE
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> return CompositionEngine.ENTER
            KeyEvent.KEYCODE_ESCAPE -> return CompositionEngine.ESCAPE
            KeyEvent.KEYCODE_TAB -> return CompositionEngine.TAB
            KeyEvent.KEYCODE_DPAD_UP -> return CompositionEngine.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> return CompositionEngine.DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> return CompositionEngine.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> return CompositionEngine.RIGHT
            KeyEvent.KEYCODE_SPACE -> return " "
        }
        val ch = event.getUnicodeChar(event.metaState)
        if (ch <= 0 || (ch and KeyCharacterMap.COMBINING_ACCENT) != 0 || Character.isISOControl(ch)) return null
        var s = String(Character.toChars(ch))
        // Caps Lock without Shift: keep Zhuyin working by using lowercase.
        if (event.isCapsLockOn && !event.isShiftPressed) s = s.lowercase()
        return s
    }

    // --- drawing ---

    /** Commits `commit`, then shows the composition (underlined, English in blue) and candidates. */
    private fun update(commit: String?) {
        val e = engine ?: return
        val ic = currentInputConnection ?: return
        ic.beginBatchEdit()
        if (!commit.isNullOrEmpty()) ic.commitText(commit, 1)   // replaces the composing text
        val pieces = e.markedPieces
        val text = pieces.joinToString("") { it.text }
        if (text.isEmpty()) {
            if (commit.isNullOrEmpty()) ic.setComposingText("", 1)
            ic.finishComposingText()
        } else {
            val span = SpannableString(text)
            span.setSpan(UnderlineSpan(), 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE or Spanned.SPAN_COMPOSING)
            var pos = 0
            for (p in pieces) {
                if (p.mode == Mode.LITERAL && p.text.isNotEmpty()) {
                    span.setSpan(ForegroundColorSpan(LITERAL_COLOR), pos, pos + p.text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                pos += p.text.length
            }
            ic.setComposingText(span, 1)
            val cursor = e.cursorOffset
            if (cursor in 0 until text.length && composingStart >= 0) {
                ic.setSelection(composingStart + cursor, composingStart + cursor)
            }
        }
        ic.endBatchEdit()
        updateCandidates()
    }

    override fun onCreateCandidatesView(): View =
        CandidateBar(this) { index ->
            val e = engine ?: return@CandidateBar
            update(e.selectCandidate(index))
        }.also {
            candidateBar = it
            main.post { updateCandidates() }
        }

    private fun updateCandidates() {
        val e = engine
        if (e == null || !e.showingCandidates) {
            setCandidatesViewShown(false)
            return
        }
        setCandidatesViewShown(true)
        val (texts, selected) = e.page()
        candidateBar?.show(texts, selected, e.pageStart, e.candidates.size, e.pageSize)
    }

    private fun showMode(english: Boolean) {
        Toast.makeText(this, if (english) "A" else "中", Toast.LENGTH_SHORT).show()
    }

    companion object {
        private val LITERAL_COLOR = Color.rgb(0x1E, 0x64, 0xDC)   // blue hint for English, as on the Mac
    }
}
