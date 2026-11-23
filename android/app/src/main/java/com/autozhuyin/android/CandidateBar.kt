package com.autozhuyin.android

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * One row of candidates above the bottom of the screen ("1 你  2 妳 …  1/3"), shown without
 * an on-screen keyboard. Tap a candidate to pick it; the keyboard works as on the desktop
 * (digits, arrows, space/Enter, Esc).
 */
@SuppressLint("ViewConstructor")
class CandidateBar(context: Context, private val onPick: (Int) -> Unit) : HorizontalScrollView(context) {
    private val row = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val dark = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
    private val textColor = if (dark) Color.rgb(0xEE, 0xEE, 0xEE) else Color.rgb(0x22, 0x22, 0x22)
    private val dimColor = if (dark) Color.rgb(0x99, 0x99, 0x99) else Color.rgb(0x77, 0x77, 0x77)
    private val highlight = Color.rgb(0x1E, 0x64, 0xDC)

    init {
        setBackgroundColor(if (dark) Color.rgb(0x26, 0x26, 0x28) else Color.rgb(0xF2, 0xF2, 0xF4))
        isHorizontalScrollBarEnabled = false
        val pad = dp(6)
        row.setPadding(pad, pad, pad, pad)
        addView(row)
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    /** texts: the current page; selected: highlighted index within it; pageStart/total: for "page/pages". */
    fun show(texts: List<String>, selected: Int, pageStart: Int, total: Int, pageSize: Int) {
        row.removeAllViews()
        for ((i, text) in texts.withIndex()) {
            val isSelected = i == selected
            val label = TextView(context).apply {
                this.text = "${i + 1} $text"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                setTextColor(if (isSelected) Color.WHITE else textColor)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                if (isSelected) {
                    background = GradientDrawable().apply {
                        setColor(highlight)
                        cornerRadius = dp(6).toFloat()
                    }
                }
                setOnClickListener { onPick(pageStart + i) }
            }
            row.addView(label)
        }
        if (total > pageSize) {
            val pages = (total + pageSize - 1) / pageSize
            row.addView(TextView(context).apply {
                text = "${pageStart / pageSize + 1}/$pages"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTextColor(dimColor)
                setPadding(dp(12), 0, dp(8), 0)
            })
        }
        post { scrollTo(0, 0) }
    }
}
